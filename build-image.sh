#!/usr/bin/env bash
# Build a flash-and-go Armbian image for the R69 (generic RK3518 TV box).
#
# Takes a stock Armbian rk35xx (vendor 6.1) base image and bakes in everything that
# makes the R69 boot and bring up its hardware:
#   - factory idbloader @ sector 64      (the only DDR config stable on this DRAM die)
#   - our u-boot.itb @ sector 16384      (mainline + BL31 v1.21; build it with build-uboot.sh)
#   - the R69 device tree                (vendor rock-2f DTB, edited: wifi + gmac + usb3, pcie off)
#   - an AIC8800 Wi-Fi first-boot fixup  (the apt-remove + firmware-symlink dance that can
#                                         only run on the live system, not at image-build time)
#   - IR-remote + RK630 Ethernet-PHY DKMS sources (vendor drivers the stock kernel lacks,
#                                         fetched at build time from a pinned commit; built on first boot)
#
# Everything it injects lives in firmware/. No kernel build, no Docker — native macOS via
# e2tools, or native Linux via a loop device.
#
# Usage:  ./build-image.sh  Armbian_rk35xx.img[.xz]  [out.img]
#   With no out.img, the output is "<base>-r69.img" written next to the base image.
#   brew install e2tools xz     (macOS)   /   apt install e2tools xz-utils  (Linux)
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
FW="$REPO/firmware"

BASE="${1:?usage: build-image.sh Armbian_rk35xx.img[.xz] [out.img]}"
# default output: the base image's name with a -r69 suffix, alongside the base
if [ -n "${2:-}" ]; then OUT="$2"; else
  base_noext="${BASE%.xz}"; OUT="${base_noext%.img}-r69.img"
fi

IDBLOADER="$FW/factory_idbloader.bin"   # -> sector 64
UBOOT="$FW/u-boot.itb"                   # -> sector 16384
DTB="$FW/board.dtb"
IDBLOADER_SEEK=64
UBOOT_SEEK=16384
# serial console on ff9f0000/ttyS0, not Armbian's stock ttyS2 (= the BT UART)
SERIALCON="earlycon=uart8250,mmio32,0xff9f0000 console=ttyS0,1500000"
# vendored driver sources (IR remote + RK630 Ethernet PHY): pinned vendor-kernel commit;
# build-image fetches from it (the IR source additionally gets firmware/ir/r69.patch)
RK_SHA=31cd4f11b5ec31fc361256a04237416f278b62b2
RK_RAW_BASE="https://raw.githubusercontent.com/armbian/linux-rockchip/$RK_SHA"
IR_RAW_BASE="$RK_RAW_BASE/drivers/input/remotectl"

for f in "$BASE" "$IDBLOADER" "$UBOOT" "$DTB" "$FW/r69-bt" "$FW/r69-bt.service" "$FW/rockchip-pwm-remotectl-r69-setup" \
         "$FW/ir/r69.patch" "$FW/ir/Makefile" "$FW/ir/dkms.conf" \
         "$FW/rk630-phy-r69-setup" "$FW/ethphy/Makefile" "$FW/ethphy/dkms.conf" \
         "$FW/r69-firstboot" "$FW/r69-firstboot.service" "$FW/r69-mac-pin" "$FW/r69-mac-pin.service" "$FW/r69-dtb-persist" \
         "$FW/r69-kernel-prepare" \
         "$FW/r69-led-shutdown" "$FW/r69-led-sleep" "$FW/r69-suspend.conf" "$FW/r69-powerkey.conf" \
         "$FW/r69-motd-bluetooth"; do
  [ -f "$f" ] || { echo "Missing: $f"; exit 1; }
done
for t in e2cp e2ls e2ln e2mkdir; do
  command -v "$t" >/dev/null || { echo "Need e2tools ($t). macOS: brew install e2tools"; exit 1; }
done
for t in curl patch; do
  command -v "$t" >/dev/null || { echo "Need $t (the image-time IR fetch+patch step)"; exit 1; }
done

# ---- 1. base image -> OUT ------------------------------------------------------------
echo "[1/5] Writing base image -> $OUT"
case "$BASE" in
  *.xz) command -v xz >/dev/null || { echo "Need xz to decompress $BASE"; exit 1; }; xz -dc "$BASE" > "$OUT" ;;
  *)    cp "$BASE" "$OUT" ;;
esac

# ---- 2. factory bootloader (raw sectors, before the first partition) -----------------
echo "[2/5] Overlaying factory idbloader @${IDBLOADER_SEEK} + our u-boot.itb @${UBOOT_SEEK}"
dd if="$IDBLOADER" of="$OUT" bs=512 seek="$IDBLOADER_SEEK" conv=notrunc 2>/dev/null
dd if="$UBOOT"     of="$OUT" bs=512 seek="$UBOOT_SEEK"     conv=notrunc 2>/dev/null

# ---- 3. attach the image, find the Armbian rootfs partition --------------------------
echo "[3/5] Attaching image to reach the ext4 rootfs"
OS="$(uname -s)"
ATTACHED=""
detach() { [ -n "$ATTACHED" ] || return 0
  case "$OS" in Darwin) hdiutil detach "$ATTACHED" >/dev/null 2>&1 || true ;;
                Linux)  sudo losetup -d "$ATTACHED" 2>/dev/null || true ;; esac; }
trap detach EXIT

if [ "$OS" = Darwin ]; then
  ATTACHED="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$OUT" | head -1 | awk '{print $1}')"
  PART="$(diskutil list "$ATTACHED" | awk '/[0-9]+:/{p=$NF} END{print p}')"   # last partition = rootfs
  # buffered BLOCK node (not /dev/r…): libext2fs does unaligned I/O, which the raw char
  # node rejects. hdiutil hands the node to the attaching user (rw), so no sudo needed.
  FS="/dev/${PART}"
  E2=''
else
  ATTACHED="$(sudo losetup -fP --show "$OUT")"
  FS="$(lsblk -lnpo NAME "$ATTACHED" | tail -1)"
  # Hand the rootfs partition node to the invoking user (rw) so every e2tools call runs WITHOUT
  # sudo -- exactly like the macOS path above. Running e2cp as root while its /tmp scratch files
  # are owned by the user makes e2cp's copy-OUT (open(outfile,...)) fail with "Permission denied"
  # on some hosts (root/uid mismatch on the temp file). Keeping e2tools unprivileged sidesteps it.
  sudo chown "$(id -un)" "$FS"
  E2=''                     # we own the partition node now; no sudo needed
fi
echo "      rootfs partition: $FS"

# ---- 4. install the R69 device tree + console ----------------------------------------
echo "[4/5] Installing R69 DTB + console"
VERDIR="$($E2 e2ls "$FS:/boot" | tr -s ' \t' '\n' | grep '^dtb-' | head -1)"
[ -n "$VERDIR" ] || { echo "Could not find /boot/dtb-<ver> in the image"; exit 1; }
FDT="rockchip/board.dtb"
$E2 e2cp "$DTB" "$FS:/boot/$VERDIR/$FDT"

ENV="$(mktemp)"
$E2 e2cp "$FS:/boot/armbianEnv.txt" "$ENV"
# console=display drops boot.cmd's stray console=ttyS2 (the BT UART); ours goes via extraargs
grep -v -E '^fdtfile=|^extraargs=|^console=' "$ENV" > "$ENV.new" || true
printf 'fdtfile=%s\nconsole=display\nextraargs=%s\n' "$FDT" "$SERIALCON" >> "$ENV.new"
$E2 e2cp "$ENV.new" "$FS:/boot/armbianEnv.txt"
rm -f "$ENV" "$ENV.new"

# ---- 5. first-boot setup + per-unit MAC + Bluetooth services -------------------------
echo "[5/5] Installing first-boot setup (Wi-Fi/u-boot/IR/eth-PHY) + per-unit MAC + Bluetooth"
TMP="$(mktemp -d)"

# static drop-in. NOTE: we do NOT bake /etc/modules-load.d/aic8800.conf — loading aic8800_fdrv early
# fails while the conflicting aic8800-usb DKMS is still installed (duplicate symbol). r69-firstboot
# removes that DKMS and THEN creates aic8800.conf, so the early-boot load never collides.
printf 'blacklist aic8800_fdrv_usb\n' > "$TMP/blacklist-aic8800-usb.conf"

# the single idempotent first-boot script + its service are vendored files (firmware/r69-firstboot
# [.service]) — Wi-Fi fixup, u-boot hold, IR + Ethernet-PHY DKMS builds; staged below.

# enable the oneshots without a wants/ symlink (e2tools can't create symlinks): a
# multi-user.target drop-in that Wants= them pulls the units at boot, same as enabling.
printf '[Unit]\nWants=r69-firstboot.service r69-mac-pin.service r69-bt.service\n' > "$TMP/10-r69.conf"

# per-unit MAC pin (stable vendor-OUI + cpuid MAC, every boot, so the DHCP lease stops churning)
# is the vendored r69-mac-pin + r69-mac-pin.service, staged below.
$E2 e2cp "$TMP/blacklist-aic8800-usb.conf" "$FS:/etc/modprobe.d/blacklist-aic8800-usb.conf"
$E2 e2cp -P 0755 "$FW/r69-firstboot"         "$FS:/usr/local/sbin/r69-firstboot"
$E2 e2cp         "$FW/r69-firstboot.service" "$FS:/etc/systemd/system/r69-firstboot.service"
$E2 e2mkdir "$FS:/etc/systemd/system/multi-user.target.d" 2>/dev/null || true
$E2 e2cp "$TMP/10-r69.conf" "$FS:/etc/systemd/system/multi-user.target.d/10-r69.conf"
$E2 e2cp -P 0755 "$FW/r69-mac-pin" "$FS:/usr/local/sbin/r69-mac-pin"
$E2 e2cp "$FW/r69-mac-pin.service"  "$FS:/etc/systemd/system/r69-mac-pin.service"

# ---- IR remote: opt-in setup + DKMS source built here from PINNED upstream + our patch ----------
# We don't vendor the driver wholesale; we author firmware/ir/r69.patch against a pinned upstream
# commit ($IR_SHA). Here (build host, has network) we fetch that exact commit, apply the patch, and
# stage the result as the image's DKMS source. r69-firstboot builds + loads it on first boot
# (offline — the image ships kernel headers) so the bundled remote (and the power button, the only
# way to wake from poweroff) works out of the box; the setup script is also runnable by hand.
$E2 e2cp -P 0755 "$FW/rockchip-pwm-remotectl-r69-setup" "$FS:/usr/local/sbin/rockchip-pwm-remotectl-r69-setup"
IRTMP="$(mktemp -d)"
curl -fsSL "$IR_RAW_BASE/rockchip_pwm_remotectl.c" -o "$IRTMP/rockchip_pwm_remotectl.c"
curl -fsSL "$IR_RAW_BASE/rockchip_pwm_remotectl.h" -o "$IRTMP/rockchip_pwm_remotectl.h"
patch -p1 -d "$IRTMP" < "$FW/ir/r69.patch"
$E2 e2mkdir "$FS:/usr/src/rockchip-pwm-remotectl-r69-1.0" 2>/dev/null || true
$E2 e2cp "$IRTMP/rockchip_pwm_remotectl.c" "$FS:/usr/src/rockchip-pwm-remotectl-r69-1.0/rockchip_pwm_remotectl.c"
$E2 e2cp "$IRTMP/rockchip_pwm_remotectl.h" "$FS:/usr/src/rockchip-pwm-remotectl-r69-1.0/rockchip_pwm_remotectl.h"
$E2 e2cp "$FW/ir/Makefile"  "$FS:/usr/src/rockchip-pwm-remotectl-r69-1.0/Makefile"
$E2 e2cp "$FW/ir/dkms.conf" "$FS:/usr/src/rockchip-pwm-remotectl-r69-1.0/dkms.conf"
rm -rf "$IRTMP"

# ---- Ethernet PHY: DKMS source fetched here from the same PINNED vendor kernel, unmodified ------
# The RK3528's integrated RK630 FEPHY (ID 0x00441400) needs this vendor driver to apply its per-die
# OTP TX calibration; the stock kernel ships CONFIG_RK630_PHY off, so the uncalibrated Generic PHY
# binds instead and many units negotiate only 10 Mb/s. r69-firstboot builds + activates it offline
# on first boot (and it steps aside if a future kernel enables the driver in-tree).
$E2 e2cp -P 0755 "$FW/rk630-phy-r69-setup" "$FS:/usr/local/sbin/rk630-phy-r69-setup"
PHYTMP="$(mktemp -d)"
curl -fsSL "$RK_RAW_BASE/drivers/net/phy/rk630phy.c" -o "$PHYTMP/rk630phy.c"
$E2 e2mkdir "$FS:/usr/src/rk630-phy-r69-1.0" 2>/dev/null || true
$E2 e2cp "$PHYTMP/rk630phy.c"   "$FS:/usr/src/rk630-phy-r69-1.0/rk630phy.c"
$E2 e2cp "$FW/ethphy/Makefile"  "$FS:/usr/src/rk630-phy-r69-1.0/Makefile"
$E2 e2cp "$FW/ethphy/dkms.conf" "$FS:/usr/src/rk630-phy-r69-1.0/dkms.conf"
rm -rf "$PHYTMP"

# ---- standby-LED hooks: light red 'standby' (blank blue) when off/suspended, like stock ----
# The DTB carries retain-state-shutdown + retain-state-suspended so the kernel/LED-core stop
# blanking the LEDs; these hooks set the actual red-on/blue-off state at poweroff and suspend.
$E2 e2mkdir "$FS:/usr/lib/systemd/system-shutdown" 2>/dev/null || true
$E2 e2mkdir "$FS:/usr/lib/systemd/system-sleep"    2>/dev/null || true
$E2 e2cp -P 0755 "$FW/r69-led-shutdown" "$FS:/usr/lib/systemd/system-shutdown/r69-led"
$E2 e2cp -P 0755 "$FW/r69-led-sleep"    "$FS:/usr/lib/systemd/system-sleep/r69-led"

# ---- power-button behaviour: suspend-to-RAM is enabled + available; the power key defaults to
# poweroff and is switched to suspend by editing r69-powerkey.conf (see README). zz- so they win.
$E2 e2mkdir "$FS:/etc/systemd/sleep.conf.d"  2>/dev/null || true
$E2 e2mkdir "$FS:/etc/systemd/logind.conf.d" 2>/dev/null || true
$E2 e2cp "$FW/r69-suspend.conf"  "$FS:/etc/systemd/sleep.conf.d/zz-r69-suspend.conf"
$E2 e2cp "$FW/r69-powerkey.conf" "$FS:/etc/systemd/logind.conf.d/zz-r69-powerkey.conf"

# ---- AIC8800 Bluetooth: r69-bt attaches hci_uart on the BT UART; AutoEnable powers hci0 on
# bluez ships in the base image
$E2 e2cp -P 0755 "$FW/r69-bt" "$FS:/usr/local/sbin/r69-bt"
$E2 e2cp "$FW/r69-bt.service" "$FS:/etc/systemd/system/r69-bt.service"
# Set BlueZ AutoEnable=true if the base already has main.conf. e2cp on macOS returns 0 even when the
# source is absent, so gate on a non-empty copy ([ -s ]). Minimal base images ship no bluez at all —
# we never auto-install it; the user installs bluez and re-runs r69-firstboot, which then sets
# AutoEnable + starts BT (the login MOTD prompts for this).
BTMAIN="$(mktemp)"
if $E2 e2cp "$FS:/etc/bluetooth/main.conf" "$BTMAIN" 2>/dev/null && [ -s "$BTMAIN" ]; then
  if grep -qiE '^[[:space:]]*#?[[:space:]]*AutoEnable=' "$BTMAIN"; then
    sed -E 's/^[[:space:]]*#?[[:space:]]*AutoEnable=.*/AutoEnable=true/' "$BTMAIN" > "$BTMAIN.new"
  else
    cp "$BTMAIN" "$BTMAIN.new"; printf '\n[Policy]\nAutoEnable=true\n' >> "$BTMAIN.new"
  fi
  $E2 e2cp "$BTMAIN.new" "$FS:/etc/bluetooth/main.conf"
fi
rm -f "$BTMAIN" "$BTMAIN.new"
# login hint while bluez is missing (self-silences once installed)
$E2 e2mkdir "$FS:/etc/update-motd.d" 2>/dev/null || true
$E2 e2cp -P 0755 "$FW/r69-motd-bluetooth" "$FS:/etc/update-motd.d/99-r69-bluetooth"

# ---- rebrand: the ROCK 2F base ships hostname "rock-2f" -> r69 ------------------------
$E2 e2cp "$FS:/etc/hostname" "$TMP/oldhost" 2>/dev/null || true
OLDH="$(tr -d '[:space:]' < "$TMP/oldhost" 2>/dev/null)"
printf 'r69\n' > "$TMP/hostname"
$E2 e2cp "$TMP/hostname" "$FS:/etc/hostname"
if [ -n "$OLDH" ] && $E2 e2cp "$FS:/etc/hosts" "$TMP/hosts" 2>/dev/null; then
  sed "s/$OLDH/r69/g" "$TMP/hosts" > "$TMP/hosts.new"
  $E2 e2cp "$TMP/hosts.new" "$FS:/etc/hosts"
fi
# relabel the login MOTD board name (display only; BOARD= identifier stays for armbian tooling)
if $E2 e2cp "$FS:/etc/armbian-release" "$TMP/arel" 2>/dev/null; then
  sed 's/^BOARD_NAME=.*/BOARD_NAME="R69"/' "$TMP/arel" > "$TMP/arel.new"
  $E2 e2cp "$TMP/arel.new" "$FS:/etc/armbian-release"
fi

# ---- persist our DTB across kernel updates -------------------------------------------
# A kernel apt-upgrade drops a fresh dtb-<newver>/ holding the STOCK DTBs; without this our
# board.dtb wouldn't be in the new kernel's dtb dir and the box would boot the wrong tree.
# Stash a master copy + a kernel postinst.d hook that reinstalls it after each kernel update.
$E2 e2mkdir "$FS:/usr/local/share/r69" 2>/dev/null || true
$E2 e2cp "$DTB" "$FS:/usr/local/share/r69/board.dtb"
$E2 e2mkdir "$FS:/etc/kernel/postinst.d" 2>/dev/null || true
$E2 e2cp -P 0755 "$FW/r69-dtb-persist" "$FS:/etc/kernel/postinst.d/r69-dtb-persist"

# ---- let DKMS modules build on combined image+headers kernel upgrades ----------------
# dpkg configures linux-image before linux-headers, so the dkms hook fires before the headers
# postinst has compiled the kernel host tools (fixdep/modpost) -- every DKMS build then dies with
# "scripts/basic/fixdep: not found" and apt half-breaks. The 00- prefix runs this before dkms; it
# builds those tools from the already-unpacked headers source so DKMS succeeds on the first pass.
$E2 e2cp -P 0755 "$FW/r69-kernel-prepare" "$FS:/etc/kernel/postinst.d/00-r69-kernel-prepare"
rm -rf "$TMP"

detach; ATTACHED=""; sync
echo
echo "Done -> $OUT"
echo "Flash it (with progress):"
echo "  macOS:  diskutil unmountDisk /dev/diskN; sudo gdd if=$OUT of=/dev/rdiskN bs=4M conv=fsync status=progress   (brew install coreutils)"
echo "  Linux:  sudo dd if=$OUT of=/dev/sdX bs=4M conv=fsync status=progress"
echo "  ...or Balena Etcher on either OS."
echo "Wi-Fi is fixed up on first boot; it associates reliably after the first power-cycle."
