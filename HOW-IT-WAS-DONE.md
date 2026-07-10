# How the R69 got Armbian — a bring-up journey

The R69 is a $35 RK3518 Android TV box: locked bootloader, no docs, no community port. Here's how it
became a real Armbian machine — told in the order it actually happened, so the next person (or the next
Claude) can walk the same path.

> ### TL;DR — the speedrun 🙂
> Cracked the case open. Found a 4-pad serial header by the SD slot, pushed in **three jumper wires**
> (no soldering, no VCC), plugged it into a Mac, and pointed **Claude** at the console. From there it
> basically drove itself: get a root shell → enable ADB → dump the whole eMMC and every scrap of recon →
> swap in a bootloader that actually recognizes an RK3518 → hand the board's device tree to the AI to
> rewrite. The moment SSH came up, the loop got fast — Claude brought the peripherals up **one at a time
> over the network**, with a human acting only as hands: reflash the SD, power-cycle, press a remote
> button. Standing rule: **relentlessly fix every issue, no "good enough."** A great many reboots later:
> a complete little Linux box where **essentially every peripheral works** — video, audio, Wi-Fi,
> Bluetooth, USB 2/3, the LEDs, the 22-button remote and its power key — all baked into one reproducible
> script. (The remote's nice enough to moonlight as a [cncjs](https://github.com/cncjs/cncjs) CNC pendant.)

The one idea everything hangs off:

> **Keep the box's factory bootloader, take everything generic from the Radxa ROCK 2F, and override only
> three things — U-Boot, the kernel config/modules, and the device tree. The device tree is the only
> board-specific part, and that's the part you hand to an AI.**

The rest is the **play-by-play** — every step, trap, and dead end, in the order we hit them.

---

## The box

| | |
|---|---|
| SoC | **RK3518A** — reports `SoC: 35181001`, `ro.board.platform=rk3528`. RK3518 is a variant *inside* the RK3528 family — that single fact drives every choice below. |
| RAM / eMMC | 2 GB / 16 GB (`mmcblk2`, 30777344 sectors) |
| Wi-Fi/BT | **AIC8800D80**, SDIO `C8A1:0082` (`aicwf_sdio` / `aic8800_fdrv`) |
| Debug UART | `0xff9f0000` @ **1500000** baud |
| Bootloader | factory **DDR huan.he v1.11**, **BL31 v1.20**, BL32 v1.06 |
| Stock | Android 12, `ro.product.name=R69-1`, SELinux permissive |

**Opening the case:** it pops apart easily with a **plastic opening triangle/pick** (the kind in any
phone-repair kit) — no clips to break. When closing it back up, **orient the backplate correctly so its
thermal pad lands squarely on the Rockchip SoC** — get this wrong and the SoC loses its heatsink path and
will thermal-throttle.

---

## 1. Getting in

The obvious doors were all locked:

- **Developer options** wouldn't unlock — tapping the build number 7× did nothing (this
  box strips it), so no ADB the normal way.
- **No reset button** in the AV jack, and the box has **only USB-A ports** — so the
  maskrom route needs a **USB-A male-to-male** cable into a real host port. (A plain
  A-to-C cable into a USB-C Mac won't enumerate: the C end signals "host", the box is
  also a host → role collision. Converting the box's A port to C doesn't help either.)

The door that *did* open was the **debug UART** — the 3 wires above, on the 4-pad header by the SD
slot: pinout **GND · TX · RX · 3V3** (square pad = GND; wire GND/TX/RX and cross adapter TX↔RX). **Do not
connect VCC/3V3** (the box is self-powered; tying rails can backfeed). Adapter must do 1.5 Mbaud:
**CH340/FT232 do; a CP2102 tops out near 1 Mbaud** and prints garbage. Read it with `tio`
or pyserial miniterm (`screen` often can't set 1500000):

```bash
brew install tio
tio -b 1500000 -L --log-file boot.log /dev/cu.usbserial-XXXX   # use cu.*, not tty.*  (-l is list!)
```

Power-cycle and the boot log scrolls. On this box the serial console is a **root shell**
(`su 0 <cmd>` syntax, not `su -c`). From there, bootstrap ADB over the network so you can
reuse normal tooling and pull files quickly:

```sh
setprop service.adb.tcp.port 5555; stop adbd; start adbd     # from the serial root shell
# then from your PC:  adb connect <box-ip>:5555
```

> **Pull binaries over ADB, not serial.** A `base64` of the device tree over the serial
> line at 1.5 Mbaud (no flow control) *drops bytes* and decodes to garbage. `adb exec-out
> 'su 0 cat /sys/firmware/fdt' > board.dtb` is byte-exact.

Not on the network yet? Join Wi-Fi from the Android root shell
(`cmd wifi connect-network "SSID" wpa2 "PASS"`) or plug Ethernet. (The password lands in
your serial log — scrub it after if you care.)

Keep a **wired link** for the bring-up itself: the onboard Ethernet — or a **USB-Ethernet dongle** —
holds SSH steady across the many reboots and is up before Wi-Fi is configured, far less flaky than
leaning on Wi-Fi while you're still bringing the radio up.

## 2. Back up first — the factory bootloader is irreplaceable

> **The public Rockchip DDR blobs are a lottery.** On many boards they fail DDR training
> or boot *marginally* and silently corrupt RAM. The only config known stable on your
> exact DRAM die is the **factory one, baked into the eMMC at sector 64.**

So before touching anything, dump the whole eMMC and carve out the factory loader:

```sh
adb exec-out 'su 0 dd if=/dev/block/mmcblk2 bs=1M 2>/dev/null' > emmc-full.img
dd if=emmc-full.img of=factory_idbloader.bin bs=512 skip=64 count=4096
strings factory_idbloader.bin | grep -iE 'huan|fwver'   # must show "DDR ... fwver:"
```

`2>/dev/null` on the box matters — some toybox `dd` builds print stats *into* the captured
stream, tacking a text trailer onto the image. Verify the final size matches
`/sys/block/mmcblk2/size × 512` exactly; adb-over-Wi-Fi can drop mid-stream (Ethernet is
steadier for 16 GB). These two files (`backup/emmc-full.img`,
`firmware/factory_idbloader.bin`) are your only undo button.

## 3. Recon — dump what the device tree needs

The whole port is derived from a handful of dumps off the running stock system
(`stock/`). The important ones:

| File | What | Why |
|---|---|---|
| `board.dts` | the **live Android** device tree (`/sys/firmware/fdt`, decompiled) | the authoritative source of *this board's* pins |
| `gpio.txt`, `pinmux.txt` | claimed GPIOs + pin→function map | finds SDIO data-line conflicts |
| `dmesg.txt` | boot log | clocks, regulators, PHY, Wi-Fi probe |
| `sdio.txt`, `firmware-list.txt` | Wi-Fi chip vendor:device id + firmware it wants | drives the Wi-Fi node |
| `cmdline.txt`, `iomem.txt` | console UART address, RAM | earlycon, memory node |

Collect them over the serial→ADB bootstrap — this box uses `su 0`, and `adb exec-out`
keeps the binary DTB byte-exact:

```sh
mkdir -p stock && cd stock
# the live Android device tree — binary-safe pull, then decompile for the AI
adb exec-out 'su 0 cat /sys/firmware/fdt' > board.dtb
dtc -I dtb -O dts board.dtb > board.dts

adb exec-out 'su 0 cat /sys/kernel/debug/gpio'                  > gpio.txt
adb exec-out 'su 0 cat /sys/kernel/debug/pinctrl/*/pinmux-pins' > pinmux.txt
adb exec-out 'su 0 sh -c "for d in /sys/bus/sdio/devices/*; do cat \$d/uevent; done"' > sdio.txt
adb exec-out 'su 0 ls -R /vendor/etc/firmware /vendor/firmware 2>/dev/null'           > firmware-list.txt
adb exec-out 'su 0 dmesg'                 > dmesg.txt
adb exec-out 'su 0 getprop'               > getprop.txt
adb exec-out 'su 0 lsmod'                 > lsmod.txt
adb exec-out 'su 0 cat /proc/cmdline'     > cmdline.txt
adb exec-out 'su 0 cat /proc/iomem'       > iomem.txt
adb exec-out 'su 0 cat /proc/meminfo'     > meminfo.txt
adb exec-out 'su 0 cat /proc/partitions'  > partitions.txt
adb exec-out 'su 0 cat /proc/cpuinfo'     > cpuinfo.txt
```

These are **runtime** dumps — they only exist on a *booted* stock system. Once you've
flashed Armbian you can't regenerate them without restoring stock, which is why
`stock/` is kept in the repo as the evidence trail.

## 4. The boot chain — and the "Unknown SoC" detour

> The stock image's U-Boot got far enough to greet us with `Unknown SoC` and quit — it literally didn't
> recognize the chip it was running on. Newer firmware knew the way.

The working chain is three pieces written to a stock Armbian rk35xx image:

```
sector 64       factory idbloader   (tuned DDR + Rockchip SPL)   <- from your backup
sector 16384    u-boot.itb          (BL31 v1.20)
partition 1     Armbian rootfs (/boot inside)
```

The detour: the stock Armbian ROCK 2F image's own U-Boot carries a **BL31 too old for
RK3518** — it boots far enough to print **`Unknown SoC`** and stops. RK3518 support landed
in **BL31 v1.20**; older (v1.17) predates it. Swapping in a v1.20 `u-boot.itb` (from the
[juliovendramini](https://github.com/juliovendramini/rk3518_armbian) prebuilts, or built
with `generic-rk3528_defconfig` + `CONFIG_SYS_MMC_MAX_BLK_COUNT=2048`) fixed it.

> **Assembly must swap BOTH** the idbloader@64 **and** u-boot.itb@16384 — and always
> *after* writing the OS image, or the image's broken loader wins. We initially swapped
> only the idbloader, which cost us the whole `Unknown SoC` detour.

## 5. The device tree — the one lesson that matters most

The natural plan is: ask the AI to write a clean device tree from the Radxa ROCK 2F
mainline source + the box's pins, compile it with `dtc`, done. **It compiles, the
`compatible` strings even match — and it hangs dead at `Starting kernel`.**

> **A mainline-compiled DTB is incompatible with the Armbian *vendor* (BSP 6.1) kernel.**
> The vendor kernel needs a *vendor*-structured DTB. The reliable method is to **edit the
> vendor DTB**, not compile a fresh mainline one:
>
> 1. extract `rk3528-rock-2f.dtb` from the stock Armbian image, **decompile** it
>    (`dtc -I dtb -O dts`),
> 2. apply your board's changes to *that* (string-edit the `.dts`, recompile with `dtc`;
>    flip `status` with `fdtput`),
> 3. you now have `firmware/board.dts` — self-contained, plain-`dtc`-compilable.

In commands — decompile the vendor base, edit, recompile, install:

```sh
# vendor base DTB: in the stock Armbian image (or a booted Armbian) at
#   /boot/dtb/rockchip/rk3528-rock-2f.dtb
dtc -I dtb -O dts  rk3528-rock-2f.dtb         > board.dts   # decompile
#   ...edit board.dts (the changes below)...
dtc -@ -I dts -O dtb -o board.dtb  board.dts     # recompile (-@ keeps __symbols__)

# iterate on the running box — Ethernet keeps SSH across the reboot:
scp board.dtb r69:/boot/dtb-*/rockchip/    # into the kernel's dtb-<ver> dir
ssh r69 reboot
```

(`build-image.sh` ships the finished `firmware/board.dtb`; the above is the loop you
use while *deriving* it.)

The AI is still what reads the 4000-line Android DT and tells you *which* nodes and pins
to change — it just feeds edits into the vendor DTB instead of authoring a new tree. The
changes it worked out for the R69:

- **Console** — address-based earlycon for `0xff9f0000` (survives `ttySx` renumbering).
- **PCIe** — `status = "disabled"`. RK3518 has no usable PCIe; the driver throws an
  external abort at boot (`fdtput /pcie@fe4f0000 status disabled`).
- **Ethernet** — enable `gmac0` (it's `disabled` in the rock-2f DTB).
- **Wi-Fi SDIO** — enable `sdio1@ffc20000` (4-bit, non-removable, `cap-sdio-irq`,
  `sd-uhs-sdr104`) + an `mmc-pwrseq` + Rockchip `wlan-platdata`, wired to the R69's
  **real** GPIOs read from the Android DT: REG_ON **gpio3.10**, host-wake **gpio3.11**,
  32 kHz **gpio3.19**. (The reference box used sdio0/gpio1 — this is where boards differ.)
- **USB 3.0** — switch `dwc3` to host mode, add the USB3 combo-phy, drop the
  `maximum-speed = "high-speed"` cap.

> **The headline trap — audit every active GPIO against the SDIO/eMMC data lines.** On the
> reference box a Radxa status **LED sat on a pin that is an SDIO data line** on the TV
> box; it silently broke 4-bit Wi-Fi writes (firmware download timed out with `-110`).
> Always cross-check `gpio-leds`/regulators/`reset-gpios` against the SDIO data/clk/cmd
> pins. This is the single most valuable thing the AI does in the DT step.

## 6. Wi-Fi — the AIC8800 SDIO saga

Enabling SDIO in the DTB was necessary but not sufficient. The userspace side took three
more fixes:

1. **Remove `aic8800-usb-dkms`** (`apt-get remove`, not just blacklist). It ships three
   USB `.ko` that export the **same symbol** as the in-tree SDIO driver — a duplicate-
   symbol clash. A static blacklist isn't enough; the package must go.
2. **Firmware filename mismatch** — the driver opens un-suffixed names
   (`fw_patch_table.bin`); the package ships `*_8800d80_u02.bin`. Symlink un-suffixed →
   suffixed in `/lib/firmware/aic8800/SDIO/aic8800D80/`.
3. **Auto-load** `aic8800_fdrv` at boot.

Result: `wlan0` up, Bluetooth firmware patch loads with it. (A warm `reboot` re-runs the SDIO
`mmc-pwrseq` REG_ON toggle, so the radio re-inits cleanly; the `poweroff`/no-PMIC power story is §9.)

## 7. Bluetooth — a two-day red herring that was a serial console all along

> Two days spent proving the Bluetooth chip was dead. It wasn't. A login prompt was quietly typing
> `r69 login:` *into the chip* and eating its replies — and the fix was a single line. The journey's
> lowest point and its sharpest lesson. 🤦

The AIC8800's Bluetooth rides UART2 (`/dev/ttyS2`) at 1.5 Mbaud; `aicbsp` loads its BT patch
over SDIO at boot. So `hciattach … any flow` *should* just work — but `hci0` came up
**dead**: `RX bytes:0`, `BD 00:00:00:00:00:00`, every HCI command timing out. We chased it deep:
removed the UART's `dmas`, dropped the SDIO clock 150→100 MHz, compared MCR/MSR/baud registers
raw-vs-line-discipline (byte-identical), proved with internal UART loopback that the kernel's TX
physically reached the wire, even built a userspace H4↔`/dev/vhci` bridge to sidestep the kernel
line discipline entirely. The bridge got *further* (read the chip's real address, 41 HCI events)
but still flaked — and crucially, a **raw** read/write to `/dev/ttyS2` answered HCI Reset
perfectly every time. The chip was fine. Something else was on the wire.

It was a **login console.** Armbian's `armbianEnv.txt` `console=both` makes `boot.cmd` append
`console=ttyS2,1500000` to the kernel command line — and on this board ttyS2 is the *Bluetooth*
UART, not the debug one (the real debug console is `ff9f0000`/`ttyFIQ0`). systemd dutifully spawns
a **`serial-getty@ttyS2`** that opens the port, prints a login banner *into the BT chip*, and
eats the chip's HCI replies. Worse, it **respawns** after every `fuser -k`, so it corrupted tests
mid-run and looked like a "chip that degrades." (A second self-own: `pkill -f r69-bt-bridge`
matched our own SSH command line and kept killing our session — including before `systemctl
reboot` could run, which is why "reboots weren't working.")

The fix is one line of intent — **free ttyS2** — and then everything is stock BlueZ:

```sh
systemctl mask --now serial-getty@ttyS2.service      # stop the console stealing the UART
hciattach -s 1500000 /dev/ttyS2 any 1500000 flow nosleep
```

`bluetoothctl scan on` immediately found a real nearby BLE device. The
`r69-bt` service does exactly this on every boot (plus an rfkill unblock), and `AutoEnable=true`
in `/etc/bluetooth/main.conf` powers `hci0` on. No custom bridge, no vendor `hciattach`,
no firmware download — the AIC8800 BT is a plain HCI H4 controller. The lesson: when a UART
peripheral "never answers," first check that nothing else owns the tty (`fuser /dev/ttyS2`).

**The real fix is upstream of all that: point the serial console at the right UART.** The getty
only landed on the BT UART because `armbianEnv`'s `console=both` makes `boot.cmd` hardcode
`console=ttyS2,1500000` — inherited from the rock-2f base, whose debug UART *is* ffa00000. On the
R69 the debug UART is **ff9f0000** (where the serial header actually is). ff9f0000 = uart0, but the
vendor DTB leaves uart0 `disabled` and hands its pins to a `rockchip,fiq-debugger` (which exposes
it as `ttyFIQ0`, and here even fails its FIQ/NMI setup). So we **enable uart0 as a normal `ttyS0`**
(status okay + its `uart0m0_xfer` pins) and **disable the fiq-debugger**, then set
`console=display` + `console=ttyS0,1500000` in `armbianEnv`. Now the kernel console is on the
correct UART: ttyS2 is never a console, no getty spawns on it (so the `r69-bt` mask is just
belt-and-suspenders), and `verbosity=7` in `armbianEnv` streams full kernel boot logs to serial
(it's left at the quiet default of 1; raise it when debugging). One UART number can't be renamed —
the 8250 driver owns the `ttySN` namespace from the DT `serialN` aliases — but with the console on
`ttyS0` the hierarchy is unambiguous: `ttyS0` = console, `ttyS2` = the data UART Bluetooth uses.

## 8. Everything else

> After the boot chain, the device tree, and the Bluetooth saga, the rest was a victory lap — flip the
> right DTB node, check it over SSH, move on.

Brought up by enabling the right vendor-DTB nodes and verifying on the running box over
SSH: **HDMI** video + audio, **analog AV**
audio, **GPU** (Mali-450 via the open `lima` driver), **USB 2.0** (HID enumerates),
**IR** receiver (`rc0`), **eMMC + SD**, **USB 3.0**, **CPU thermal**. RAM is **~1.5 GB, not 2 GB** —
the stock "2 GB" is Android misreporting it, not a bug (see below). The **front LED**, the
**IR remote + power button**, and the `rock-2f`→R69 **identity rename** are all done now; the
`fd650` front-panel display is **N/A** (the R69 has none). The remote/power/LED story is §9.

---

## 9. The remote, the power button, and the standby LED

The bundled remote drives the box over **infrared** — a Rockchip PWM-capture receiver on `pwm3`
(`ffa90030`) decodes all 22 keys. The **voice** and **mouse-mode** buttons press as plain keys, but their
special functions aren't set up, and whether they ride BLE or key-emulation is unconfirmed.

### IR: a shared-IRQ fix shipped as an out-of-tree module

The in-kernel `remotectl-pwm` never bound. It requested the PWM-block IRQ (28, GIC85)
**without `IRQF_SHARED`**, but the `rockchip-pwm` voltage regulators (pwm1/pwm2, always-on)
already held that same IRQ *with* it:

```
genirq: Flags mismatch irq 28. 00004004 (rk_pwm_irq) vs. 00004084 (rockchip-pwm)
remotectl-pwm ffa90030.pwm: cannot claim IRQ 28 ... -16
```

The built-in uses `platform_driver_probe()`, which **self-unregisters on a failed probe**, so
`pwm3` is left unbound — meaning a patched **out-of-tree** copy can claim it with no kernel rebuild.

**Source provenance** — we don't vendor the driver wholesale; we **author a patch on a pinned
upstream commit**. The pristine source is the BSP the running kernel is built from:

- repo / branch: **`armbian/linux-rockchip`**, branch **`rk-6.1-rkr5.1`**
- pinned commit: **`31cd4f11b5ec31fc361256a04237416f278b62b2`** (the branch moves; the commit doesn't)
- files: `drivers/input/remotectl/rockchip_pwm_remotectl.c` (patched) + `.h` (pristine)

**The patch** (`firmware/ir/r69.patch`, three changes — `diff`-verified to be *only* these, no
upstream drift):

1. **Share the IRQ** — `IRQF_NO_SUSPEND` → `IRQF_NO_SUSPEND | IRQF_SHARED` on the `rk_pwm_irq`
   request (its `dev_id` is already `ddata`, non-NULL, which `IRQF_SHARED` requires).
2. **Drop a non-exported symbol** so it links OOT — `irq_to_desc()` (not exported to modules) →
   exported `irq_get_irq_data()` + `irqd_to_hwirq()` (`struct irq_desc *desc` → `struct irq_data
   *irqd`, three call sites).
3. **Rename the driver** — `.name "remotectl-pwm"` → `"remotectl-pwm-r69"`, so it doesn't collide
   with the built-in's reserved name (DT matching is by `compatible`, so the rename is cosmetic).

> Why swap `irq_to_desc` instead of stubbing it: that path feeds `rk_pwm_sip_wakeup_init()`, which
> arms the IR IRQ + power-key scancode with ATF as a **wake source** — that's what lets the remote
> power the box back on. Stubbing it would have killed wake-on-IR.

**Packaging** — built + loaded on **first boot**, survives kernel updates (DKMS). `firmware/ir/`
holds only `r69.patch` + `Makefile` + `dkms.conf` — *not* a copy of the driver. At **image-build**
time (`build-image.sh`, on the network-connected build host) it fetches the pinned commit, applies
`r69.patch`, and stages the result as the image's DKMS source at
`/usr/src/rockchip-pwm-remotectl-r69-1.0/`. On the **box**, the single `r69-firstboot` service runs
**`rockchip-pwm-remotectl-r69-setup`** once (`dkms add/build/install` + `modules-load.d`) — offline,
since the image ships kernel headers. **Not opt-in**: the remote — and the power button, the only way
to wake from `poweroff` — must work out of the box; the setup script is also runnable by hand. DKMS
package: `rockchip-pwm-remotectl-r69/1.0`; the built module is `rockchip_pwm_remotectl_r69`.

**Surviving combined image+headers kernel upgrades.** When a kernel `apt upgrade` bumps both
`linux-image` and `linux-headers`, dpkg configures the *image* first — firing its `dkms` postinst
hook before the *headers* postinst has compiled the kernel's host build tools (`scripts/basic/fixdep`,
`scripts/mod/modpost`). The headers *source* is already unpacked but the *tools* aren't built yet, so
every out-of-tree `make` dies with `scripts/basic/fixdep: not found` (exit 127), failing all DKMS
modules and leaving the kernel package half-configured. The fix is a tiny postinst.d hook,
`firmware/r69-kernel-prepare`, staged to `/etc/kernel/postinst.d/00-r69-kernel-prepare` — the `00-`
prefix makes `run-parts` execute it **before** `dkms`. It replicates the headers postinst's own steps
(`make ARCH=arm64 olddefconfig scripts` + `M=scripts/mod` — *not* `modules_prepare`, which pulls in
`archprepare` and fails on Armbian's stripped headers) to compile those tools first, so DKMS builds on
the first pass. No-op once the tools exist.

### The power key — a configurable button: power-off *or* real suspend-to-RAM

`KEY_POWER` → logind. We set **`remote_support_psci = <1>`** on `pwm3` so ATF arms the IR as a wake
source — the remote then wakes the box from either of two modes, selected by `HandlePowerKey`:

**`poweroff` (default).** No PMIC, so `poweroff` can't cut power — `rockchip,virtual-poweroff` parks
the SoC still-powered. The remote powers it back **on**, but as a full **cold boot** (BootROM →
u-boot → kernel, ~10–15 s, RAM not preserved). A clean-shutdown soft button. Reliable, low-power off.

**`suspend` — genuine suspend-to-RAM**, and it *does* work here (this took real digging). The chain:

- Armbian ships with the suspend verb **disabled** (`AllowSuspend=no`) — re-enabled by
  `zz-r69-suspend.conf` (`AllowSuspend=yes`, `SuspendState=mem`). Use **deep `mem`, not `s2idle`**:
  s2idle is a kernel-only idle that never engages ATF, so the IR (armed in ATF) can't wake it; `mem`
  goes through PSCI `SYSTEM_SUSPEND`, which the **RK3528 BL31 v1.21 supports** (its changelog adds
  suspend + GPIO/USB/HDMI wake).
- The BL31 serial trace was the key: the SoC enters deep sleep (DDR self-refresh) and the resume cause
  is printed (`CPU0 interrupt wakeup`, `IRQ_PED: <gic>`). That's how we saw what was waking it.
- **Two red herrings cleared:** (1) the **AIC8800 WiFi** appeared to wedge resume — but with it left
  loaded it actually resumes *fine* (the live SSH session and a running `watch` survived the suspend);
  (2) early tests "auto-woke" only because an **active network/SSH session** kept interrupting — idle,
  it holds deep sleep indefinitely and **only the remote wakes it**.
- **The real bug was the power key doing double duty:** the IR press both wakes the SoC (ATF) *and* is
  decoded by the resumed kernel as `KEY_POWER`. Under `HandlePowerKey=poweroff` that meant the
  wake-press immediately *powered the box off* (wake → shutdown in one press). Switching to
  `HandlePowerKey=suspend` makes it a clean toggle: press to sleep, press to wake.
- Resume is **instant** (RAM + WiFi intact), and `mem` keeps the GPIO4 rail alive so the **red standby
  LED holds** (blue stays lit in sleep until the `r69-led-sleep` hook flips it to red).

Both modes are preconfigured; `zz-r69-powerkey.conf` just picks the default (`poweroff`). See the
README "Power button" section for the one-line switch.

### The red standby LED — making "off" show an indicator like stock

Stock Android lights the **red** LED while "off". The fix turned out to be a cheap DTB + hook combo
— *not* a firmware swap — found by reading the **stock DTB pulled straight from the eMMC dump**:
parse the GPT in `backup/emmc-full.img` for partition offsets, `dd` out the `boot` partition, scan
for the FDT magic (`d00dfeed`), carve and decompile with `dtc`.

The stock DTB (`rockchip,rk3518-evb1`) had both LEDs carrying **`rockchip,invert-on-shutdown`** — a
Rockchip-BSP `leds-gpio` property that flips the LED at shutdown. But the Armbian vendor kernel's
`leds-gpio.c` (same `rk-6.1-rkr5.1` branch) **doesn't implement it** — it only knows the mainline
**`retain-state-shutdown`**, and its `gpio_led_shutdown()` otherwise **forces every LED off**. *That*
— not the rail dying — is why "off" had always been dark.

The working recipe (`board.dtb` + two hooks):

- DTB: **`retain-state-shutdown`** + **`retain-state-suspended`** on both LED nodes → the kernel and
  the LED core stop blanking them at shutdown / suspend.
- **system-shutdown hook** (`/usr/lib/systemd/system-shutdown/r69-led`) sets **red on, blue off**
  right before the park; with `retain-state-shutdown` that survives into the parked "off" — the
  no-PMIC rail stays powered, so a driven pin holds (verified: red stays lit when off).
- matching **system-sleep hook** (`/usr/lib/systemd/system-sleep/r69-led`, `pre`/`post`) for the
  suspend path (paired with `retain-state-suspended`), for whenever suspend becomes wake-able.

This also resolved an earlier dead-end. In **suspend** (s2idle/`mem`) the GPIO4 rail really does drop
the LED; but in **poweroff/park** the rail holds — the darkness there was purely the kernel's
shutdown-blanking, which `retain-state-shutdown` cures.

Net behaviour is a clean **3-state** indicator over a power cycle:

| state | LED |
|---|---|
| **off / standby** (parked) | **red** |
| **booting** (~10–15 s cold boot) | **dark** — the SoC reset clears the GPIOs, and `leds-gpio` re-drives them only when it probes |
| **running** | **blue** |

The only un-lit window is that middle cold-boot gap; filling it would mean driving an LED from
**u-boot** early in the boot (we build our own u-boot, so it's doable) — a future nicety, not a bug.

---

## Storage — the ROCK 2F DTB over-drives the SD and eMMC

Two bus-mode traps surfaced once the image ran on more units (other SD cards, a different eMMC
part). Same root cause both times: the ROCK 2F device tree specs faster signaling than the R69
board can hold, and the fix is to **match your own factory Android DTB** (`stock/board.dts`, pulled
off the box) rather than trust the ROCK 2F defaults.

### SD card: no 1.8 V switch → drop UHS

The `sdmmc` node inherited `sd-uhs-sdr12/25/50/104` + a GPIO-switched `vqmmc-supply` from the ROCK
2F. The R69's SD IO rail has **no 1.8 V switch** (`vcc_sd` is a fixed always-on 3.3 V regulator),
and the factory DTB declares neither property. With a UHS-capable card the kernel negotiated a UHS
mode and toggled a GPIO that switches nothing: the card entered 1.8 V signaling while the host pads
stayed at 3.3 V, and since the regulator can't power-cycle the card back, every retry ended in
`Card stuck being busy!` at 187.5 kHz — the rootfs never mounted and first boot never ran. It
failed **only on UHS-capable cards**, which is why the same image booted or hung depending on the
SD. Fix: strip `sd-uhs-*` + `vqmmc-supply`, matching the factory (3.3 V high-speed, 50 MHz). The
Wi-Fi `sdio` node keeps *its* `sd-uhs-sdr104` — different controller, legitimate.

### eMMC: HS400ES writes corrupt → cap at HS200/100 MHz

The `sdhci` node inherited `mmc-hs400-1_8v` + `mmc-hs400-enhanced-strobe` and `max-frequency` =
200 MHz from the ROCK 2F. The R69's eMMC *accepts* HS400ES and **reads** are clean — but sustained
**writes** fail with I/O errors, breaking `armbian-install` and any eMMC write workload. The
asymmetry is the tell: in HS400 the reads are latched off the **data strobe the eMMC returns** (the
device supplies the timing, so they're robust — a read benchmark shows a happy ~290 MB/s), but the
writes are latched off the **host's own 200 MHz DDR launch clock**, which the board's eMMC signal
integrity can't hold. Your factory Android independently caps this part at **HS200 / 100 MHz** — so
match it: `mmc-hs200-1_8v` and `max-frequency` = 100 MHz. (The factory tree also carries a bogus
`mmc-hs200-enhanced-strobe` — enhanced strobe is HS400-only and no kernel parses that name — so it
is *not* copied.)

> **It's one link mode — you can't keep the fast reads.** HS400ES reads and writes are the same
> negotiated mode; the read robustness comes from the returned strobe, not a mode you can select per
> direction. Making writes reliable means dropping the whole link to HS200, which takes the read
> speed with it (**~290 MB/s HS400ES → ~100 MB/s HS200/100 MHz**). Still faster than the SD, and the
> eMMC is the root device after `armbian-install`, so write integrity wins.

---

## Ethernet — the integrated PHY needs its calibration driver

Ethernet is 100 Mb/s by design (no gigabit PHY on the board — the MAC drives an **integrated
RK630-class FEPHY** over RMII, `phy-mode = "rmii"`, MDIO address 2, PHY ID `0x00441400`). But the
FEPHY needs its **per-die OTP calibration** (TX level + bandgap) applied by the vendor `rk630phy`
driver; the DT already wires the `"bgs"` nvmem cell it reads. The stock Armbian kernel ships
`CONFIG_RK630_PHY` **off**, so the uncalibrated **Generic PHY** binds instead — and on units whose
analog silicon doesn't train 100BASE-TX uncalibrated, autonegotiation degrades to **10 Mb/s** (with
a garbled link-partner readout to match).

Shipped exactly like the IR driver — an out-of-tree DKMS module from pinned upstream source, no
kernel rebuild:

- **Source** — `drivers/net/phy/rk630phy.c`, **unmodified**, from the same pinned
  `armbian/linux-rockchip` commit (`31cd4f11…`) as the IR driver. `build-image.sh` fetches it and
  stages it as DKMS source at `/usr/src/rk630-phy-r69-1.0/`; `firmware/ethphy/` holds only the
  `Makefile` + `dkms.conf` (not a copy of the driver).
- **First boot** — `r69-firstboot` runs **`rk630-phy-r69-setup`** once (`dkms add/build/install`,
  offline — the image ships headers), enables early autoload (`modules-load.d`, ahead of
  networking), and does a **live Generic-PHY → RK630-PHY handover**: on `ifdown` the kernel releases
  the generic driver, so a bare `bind` + `ifup` completes the switch with no reboot. It steps aside
  if a future kernel ships `rk630phy` built-in or in-tree.

Result: `end0` links at **100 Mb/s full duplex** with the calibrated driver holding the PHY (check:
`readlink /sys/class/net/end0/phydev/driver` → `RK630 PHY`). DKMS rebuilds it on kernel updates.
DKMS package `rk630-phy-r69/1.0`; module `rk630phy`.

---

## RAM: 1.5 GB is the ceiling, not 2 GB

The box carries 2 GB of DRAM physically — the TPL trains two 1 GB chip-selects (`CS=2`, each
`Row=15 Col=10 Bk=8 BW=32`). But only **~1.5 GB ever reaches an OS**, and that's a hard limit of
the boot chain, not a u-boot bug we can patch.

The factory TPL hands the next stage an `ATAG_DDR_MEM` tag describing exactly two banks:

```
0x00200000 + 0x08200000   (ends 0x08400000,  ~130 MB)
0x08C00000 + 0x57400000   (ends 0x60000000, ~1396 MB)   →  1.5 GB, no bank above it
```

That's all there is, and we proved it. The Rockchip *vendor* u-boot we first built has
`CONFIG_BIDRAM=y` — the path (`lib/bidram.c`) that *adds* any "extended-top" region the TPL
flags. Booted on the box and stopped at the prompt, its `bdinfo` printed exactly those two banks
and nothing else (`gd->ram_top_ext_size == 0`). Every bootloader-level source agrees: the TPL
banner (`Size=1536MB`), stock `/proc/iomem`, the stock DTB `/memory` node, and the factory
u-boot's own bank fixup all say 1.5 GB.

The lone dissenter — stock Android's `/proc/meminfo` (`MemTotal: 2047704` ≈ 2 GB) — is a
**software lie, not evidence.** It *exceeds* stock's own `/proc/iomem` (1.5 GB of System RAM),
which is physically impossible: a kernel can't manage more pages than it has memory regions.

That impossibility is the fingerprint of the well-documented **fake-RAM scam** on cheap Android boxes —
the ROM is patched to *report* the advertised 2 GB no matter what's actually fitted (RK3528/RK3518 boxes
are named offenders). So there's no 0.5 GB to reclaim by rebuilding u-boot; Armbian's honest kernel
reports the truth: `MemTotal: 1500116 kB` (**1.43 GiB usable**), which for a headless Linux box is ample
anyway (a server-class workload runs comfortably in well under 1 GB).

*Why* it's an odd ~1.5 GB is almost certainly **binning**: DRAM dies come in powers of two (1, 2, 4 GB) —
nobody fabs a 1.5 GB die — so 1.5 GB usable points to a 2 GB part with ~0.5 GB fused off as a
partial-good (binned) die. That's strong inference, not read off the die markings, but it's hard to
explain otherwise — and a tidy reason the box is so cheap. (The package is a combined Samsung RAM+eMMC
part, eMMC half `manfid 0x15`.)

## Building our own u-boot

We still build our own `u-boot.itb` — not for RAM, but to **own the bootloader**: no third-party
prebuilt, every input pinned so the build is reproducible. [`build-uboot.sh`](build-uboot.sh)
builds **mainline U-Boot** (pinned tag `v2026.04`) + Rockchip's **ATF blob** (BL31 v1.21, from
`rkbin` pinned by commit), keeping the factory idbloader so only `u-boot.itb` @ sector 16384 changes:

```sh
./build-uboot.sh            # builds straight into firmware/u-boot.itb (scratch in uboot-build/)
```

- **Mainline, not the vendor tree.** The vendor (`next-dev`) tree is Android-flavored — its
  `bootcmd` runs `boot_android`/`bootrkp` and never boots Armbian (it found `/boot/boot.scr`,
  ran it, bailed, then fell through to PXE). Mainline's `generic-rk3528` boots Armbian cleanly
  via `distro_bootcmd`. Since the vendor tree buys nothing on RAM, mainline wins on simplicity.
- **No OP-TEE.** The FIT carries ATF + u-boot only; Armbian doesn't use OP-TEE. BL31 prints one
  benign `No OPTEE provided ... opteed_fast` line and boots normally. (Re-add via `TEE=` + the
  pinned `rk3528_bl32_v1.06.bin` if you ever need a TEE.)
- **`ROCKCHIP_TPL=` is only a binman build input** — mainline assembles its rockchip image
  (TPL+SPL+FIT) as one blob and emits the FIT as a byproduct, which is all we extract; the built
  idbloader is discarded. The TPL choice can't affect the FIT (ATF + u-boot), so the build stays
  reproducible on the u-boot + BL31 pins alone.

On macOS there's no native Linux, so [`build-uboot-finch.sh`](build-uboot-finch.sh) runs the
build in a **native arm64 Linux container** via [Finch](https://github.com/runfinch/finch)
(lighter than Docker Desktop; the same `finch run` would work with `docker`):

```sh
brew install finch          # once (the VM auto-starts on first run)
./build-uboot-finch.sh      # wraps build-uboot.sh in a debian:bookworm container -> firmware/u-boot.itb
```

Both write `firmware/u-boot.itb` directly. Smoke-test before trusting it — the factory idbloader
@ sector 64 stays put:

```sh
sudo dd if=firmware/u-boot.itb of=/dev/<sd> bs=512 seek=16384 conv=notrunc; sync
```

It must reach an Armbian login over serial; `free -h` shows ~1.43 GiB (the 1.5 GB ceiling).

---

## Quirks that matter — the cheat sheet

The quick-reference version of the journey above — the distilled, non-obvious things it takes to get an
R69 (or a similar RK3518 box) running well.

**Boot chain**
- Keep the **factory idbloader @ sector 64** — its DDR tuning is the only one stable on this
  DRAM die; the public blobs are a lottery.
- Use a **BL31 v1.20** `u-boot.itb` @ sector 16384 — older BL31 prints `Unknown SoC` on RK3518.
- Write **both** loaders *after* the OS image, or the image's broken loader wins.

**Device tree**
- Edit the **vendor** rock-2f DTB, not a fresh mainline compile — mainline hangs at
  `Starting kernel` against the vendor kernel.
- **Disable PCIe** (`status = "disabled"`) — RK3518 has no usable PCIe; the driver aborts at boot.
- Compile with `dtc -@` (keep `__symbols__`).
- **Audit GPIOs vs SDIO data lines** — a stray LED/regulator on an SDIO data pin silently
  breaks Wi-Fi.

**Wi-Fi (AIC8800D80)**
- `apt remove aic8800-usb-dkms` — its USB `.ko` duplicate-symbol-clash with the in-tree SDIO
  driver; a blacklist is **not** enough.
- Symlink firmware to the un-suffixed names the driver opens (`*_8800d80_u02.bin` → `fw_patch.bin`…).
- The SDIO clock is **driver-forced to 150 MHz** (`aicbsp`) — DTB `max-frequency` is a no-op.

**USB / Ethernet**
- USB 3.0: `dwc3` → `dr_mode = "host"`, add the usb3 combo-phy, drop `maximum-speed = "high-speed"`.
- Ethernet is **100 Mb/s by design** (integrated RK630 FEPHY / RMII, no gigabit PHY) — and needs the
  **`rk630phy` DKMS driver** (auto-built first boot) for its OTP calibration, or the uncalibrated
  Generic PHY drops some units to 10 Mb/s.
- The Ethernet MAC looks random but is **stable per box** (systemd `MACAddressPolicy=persistent`);
  don't hardcode one in the DTB — systemd overrides it anyway.

**Power — there is no PMIC**
- `poweroff` **doesn't cut power** — it's a *virtual deep-sleep* (`rockchip,virtual-poweroff`),
  so the box stays parked-but-powered. **Unplug to fully power off.**

**Storage — match the factory, not the ROCK 2F DTB**
- **SD**: no 1.8 V switch on the rail — strip `sd-uhs-*` + `vqmmc-supply`, or UHS cards hang at boot
  (`Card stuck being busy`). 3.3 V high-speed only.
- **eMMC**: HS400ES **writes** corrupt (reads are strobe-timed and fine) — cap at `mmc-hs200-1_8v` /
  100 MHz to match the factory. One link mode, so it costs read speed (~290 → ~100 MB/s).

**Host tooling**
- **macOS**: pull binaries with `adb exec-out`, not over serial (1.5 Mbaud base64 drops bytes);
  e2tools into the image's ext4 via the **buffered** block node (`/dev/diskNs1`), not raw
  `/dev/rdiskNs1`.
- **Linux**: `chown` the loop rootfs partition to your user and run e2tools **without** `sudo` — as
  root with a user-owned `/tmp` scratch, e2cp's copy-out hits `Permission denied` on some hosts.
- `e2ln -s` is stubbed on both, so enable a unit via a `multi-user.target.d/*.conf` `Wants=`
  drop-in, not a `wants/` symlink.

---

## Troubleshooting reference (the RK3518 traps)

| Symptom | Real cause | Fix |
|---|---|---|
| `SoC not recognized` / `Unknown SoC` in U-Boot | BL31 v1.17 predates RK3518 | rk3528 **BL31 v1.20+** `u-boot.itb` |
| Random `Synchronous Abort` whose `far` is ASCII text | marginal **public DDR blob** corrupting RAM | use the **factory idbloader** (sector 64) |
| `mmc fail to send stop cmd` loading kernel | one oversized multi-block read | `CONFIG_SYS_MMC_MAX_BLK_COUNT=2048` |
| Hang at `Starting kernel` | mainline-compiled DTB vs **vendor** kernel | **edit the vendor DTB**, don't compile mainline |
| External abort referencing `pcie`/`rk_pcie` | no usable PCIe | `status = "disabled"` on the PCIe node |
| Wi-Fi `Exec format error` / duplicate symbol | `*-usb-dkms` clashes with in-tree SDIO driver | `apt remove` the USB DKMS + `depmod -a` |
| Wi-Fi enumerates, reads IDs, firmware TX `-110` | a GPIO (LED) steals an **SDIO data line** | remove/repoint the offending `gpio-leds` |
| `*.bin file failed to open` | driver wants un-suffixed firmware names | symlink un-suffixed → `*_<chip>_uXX.bin` |
| DKMS modules fail on a kernel `apt upgrade` (`scripts/basic/fixdep: not found`, apt left half-broken) | dpkg configures **linux-image before linux-headers**, so the dkms hook runs before the headers postinst compiles the kernel host tools (`fixdep`/`modpost`) | `00-r69-kernel-prepare` postinst.d hook (sorts before `dkms`) pre-builds them; one-time recovery on an already-broken box: `dkms autoinstall -k $(uname -r)` then `dpkg --configure -a` |
| SD card hangs at boot (`Card stuck being busy!`), rootfs never mounts — only with **some** cards | ROCK 2F `sd-uhs-*` + `vqmmc-supply`, but the R69 SD rail has no 1.8 V switch | strip `sd-uhs-*` + `vqmmc-supply` (match factory: 3.3 V high-speed) |
| eMMC reads fine but **writes** fail with I/O errors (`armbian-install` breaks) | ROCK 2F runs HS400ES @ 200 MHz; writes are host-clock-timed and the board can't hold it | `mmc-hs200-1_8v` + `max-frequency` 100 MHz (match factory) |
| Ethernet links at **10 Mb/s** with a garbled link partner | uncalibrated Generic PHY bound — `CONFIG_RK630_PHY` off, FEPHY OTP calibration not applied | build `rk630phy` as DKMS (auto on first boot) |

---

## Doing this on another RK3518 box

The method generalizes; only the device tree is board-specific.

1. **Get in** — try ADB; if Developer options is locked, use the **debug UART** (3 wires,
   3.3 V, 1.5 Mbaud) for a root shell, then bootstrap ADB over the network. Maskrom +
   `rkdeveloptool` is the fallback when there's no serial (needs a USB-A-to-A cable into a
   real host, box in a cold-boot maskrom via a recovery pinhole/AV-jack button).
2. **Back up** the whole eMMC and carve `factory_idbloader.bin` (sector 64). Verify the
   DDR banner. This is irreplaceable.
3. **Recon** — dump the live Android `board.dts` + `gpio`/`pinmux`/`dmesg`/`sdio`/
   `firmware-list`/`cmdline`.
4. **Device tree** — give an AI (capable coding model, large context) the **Radxa ROCK
   2F** DTB as the base and your stock dumps as the pin source. Ask it to identify the
   changes (console earlycon, disable PCIe, enable gmac0, enable the SDIO Wi-Fi controller
   with the chip's real REG_ON/host-wake/32 k GPIOs and a `wlan-platdata` node) **and to
   run the GPIO-vs-SDIO-data-line conflict audit**. Apply those edits to the **decompiled
   vendor DTB**, recompile with `dtc`.
5. **Assemble** — stock Armbian rk35xx image + factory idbloader@64 + BL31-v1.20
   u-boot.itb@16384 + your DTB. (`build-image.sh` is exactly this, parameterized for
   the R69 — adapt the `firmware/` for your box.)
6. **Debug loop** — boot, capture serial + `dmesg`, hand them back to the AI against the
   trap table above, get the *minimal* DT/config change, recompile, reboot, repeat until
   `ip -br link` shows your interfaces up.

---

## Credits

The original RK3518 bring-up — the DDR/idbloader lottery, the AIC8800 SDIO work, the
SDIO-data-line trap, and the "edit the vendor DTB" method — was worked out by
**[juliovendramini/rk3518_armbian](https://github.com/juliovendramini/rk3518_armbian)**
(with AI assistance for the device tree). This repo applies that method to one box, the
R69. RK3518 support lives inside Rockchip's **rk3528** rkbin; the device-tree base is the
mainline Linux **Radxa ROCK 2F** (GPL-2.0+/MIT).
