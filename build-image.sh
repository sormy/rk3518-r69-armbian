#!/usr/bin/env bash
# Build a flash-and-go Armbian image for the R69 (generic RK3518 TV box).
#
# Takes a stock Armbian rk35xx (vendor 6.1) base image and bakes in everything that
# makes the R69 boot and bring up its hardware:
#   - factory idbloader @ sector 64      (the only DDR config stable on this DRAM die)
#   - our u-boot.itb @ sector 16384      (mainline + BL31 v1.21; build it with build-uboot.sh)
#   - the R69 device tree                (vendor rock-2f DTB, edited: wifi + gmac + usb3, pcie off)
#   - the firmware payload               (scripts/services/confs from firmware/payload.list)
#   - an AIC8800 Wi-Fi first-boot fixup  (the apt-remove + firmware-symlink dance that can
#                                         only run on the live system, not at image-build time)
#   - IR-remote + RK630 Ethernet-PHY DKMS sources (vendor drivers the stock kernel lacks,
#                                         fetched by firmware/fetch-dkms-src.sh; built on first boot)
#
# The same firmware/payload.list + fetch-dkms-src.sh drive r69-update, which applies these to a
# RUNNING box without reflashing. Everything injected lives in firmware/. No kernel build, no Docker —
# native macOS via e2tools, or native Linux via a loop device.
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

# every static payload file (mode src dest) lives in firmware/payload.list; verify each source exists
PAYLOAD_SRCS="$(sed -E 's/^[[:space:]]*#.*//; /^[[:space:]]*$/d' "$FW/payload.list" | awk '{print $2}')"
for f in "$BASE" "$IDBLOADER" "$UBOOT" "$DTB" "$FW/payload.list" "$FW/fetch-dkms-src.sh" "$FW/ir/r69.patch"; do
  [ -f "$f" ] || { echo "Missing: $f"; exit 1; }
done
for s in $PAYLOAD_SRCS; do
  [ -f "$FW/$s" ] || { echo "Missing payload source: firmware/$s"; exit 1; }
done
for t in e2cp e2ls e2ln e2mkdir; do
  command -v "$t" >/dev/null || { echo "Need e2tools ($t). macOS: brew install e2tools"; exit 1; }
done
for t in curl patch; do
  command -v "$t" >/dev/null || { echo "Need $t (fetch-dkms-src.sh fetches + patches the DKMS sources)"; exit 1; }
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
else
  ATTACHED="$(sudo losetup -fP --show "$OUT")"
  FS="$(lsblk -lnpo NAME "$ATTACHED" | tail -1)"
  # Hand the rootfs partition node to the invoking user (rw) so every e2tools call runs WITHOUT
  # sudo -- exactly like the macOS path above. Running e2cp as root while its /tmp scratch files
  # are owned by the user makes e2cp's copy-OUT (open(outfile,...)) fail with "Permission denied"
  # on some hosts (root/uid mismatch on the temp file). Keeping e2tools unprivileged sidesteps it.
  sudo chown "$(id -un)" "$FS"   # own the node so e2tools run unprivileged (no sudo below)
fi
echo "      rootfs partition: $FS"

# ---- 4. install the R69 device tree + console ----------------------------------------
echo "[4/5] Installing R69 DTB + console"
VERDIR="$(e2ls "$FS:/boot" | tr -s ' \t' '\n' | grep '^dtb-' | head -1)"
[ -n "$VERDIR" ] || { echo "Could not find /boot/dtb-<ver> in the image"; exit 1; }
FDT="rockchip/board.dtb"
e2cp "$DTB" "$FS:/boot/$VERDIR/$FDT"

ENV="$(mktemp)"
e2cp "$FS:/boot/armbianEnv.txt" "$ENV"
# console=display drops boot.cmd's stray console=ttyS2 (the BT UART); ours goes via extraargs
grep -v -E '^fdtfile=|^extraargs=|^console=' "$ENV" > "$ENV.new" || true
printf 'fdtfile=%s\nconsole=display\nextraargs=%s\n' "$FDT" "$SERIALCON" >> "$ENV.new"
e2cp "$ENV.new" "$FS:/boot/armbianEnv.txt"
rm -f "$ENV" "$ENV.new"

# ---- 5. firmware payload + generated drop-ins + DKMS sources + rebrand ----------------
echo "[5/5] Installing firmware payload + DKMS sources + rebrand"
TMP="$(mktemp -d)"

# --- static payload: every file from firmware/payload.list, verbatim into the rootfs ---
# (the same manifest r69-update reads to apply these to a running box)
while read -r mode src dest; do
  case "$mode" in ''|\#*) continue ;; esac
  e2mkdir "$FS:$(dirname "$dest")" 2>/dev/null || true
  e2cp -P "$mode" "$FW/$src" "$FS:$dest"
done < "$FW/payload.list"

# --- generated drop-ins (not verbatim files, so not in payload.list; image-build only) ---
# blacklist the aic8800 USB driver. NOTE: we do NOT bake /etc/modules-load.d/aic8800.conf — loading
# aic8800_fdrv early fails while the conflicting aic8800-usb DKMS is still installed (duplicate
# symbol). r69-firstboot removes that DKMS and THEN creates aic8800.conf, so the early load never
# collides.
printf 'blacklist aic8800_fdrv_usb\n' > "$TMP/blacklist-aic8800-usb.conf"
e2cp "$TMP/blacklist-aic8800-usb.conf" "$FS:/etc/modprobe.d/blacklist-aic8800-usb.conf"
# enable the payload's oneshots without a wants/ symlink (e2tools can't create symlinks): a
# multi-user.target drop-in that Wants= them pulls the units at boot, same as enabling.
printf '[Unit]\nWants=r69-firstboot.service r69-mac-pin.service r69-bt.service\n' > "$TMP/10-r69.conf"
e2mkdir "$FS:/etc/systemd/system/multi-user.target.d" 2>/dev/null || true
e2cp "$TMP/10-r69.conf" "$FS:/etc/systemd/system/multi-user.target.d/10-r69.conf"

# --- DKMS driver SOURCES: fetched from the pinned vendor kernel by fetch-dkms-src.sh (build host has
# network). The setup scripts + Makefile + dkms.conf already came from payload.list above; the .c/.h
# go into the src dirs it created. r69-firstboot builds them on first boot (offline — image ships
# headers) so the remote/power-button and 100 Mb/s Ethernet work out of the box. ---
DKMSTMP="$(mktemp -d)"
"$FW/fetch-dkms-src.sh" "$DKMSTMP/ir" "$DKMSTMP/phy"
e2cp "$DKMSTMP/ir/rockchip_pwm_remotectl.c" "$FS:/usr/src/rockchip-pwm-remotectl-r69-1.0/rockchip_pwm_remotectl.c"
e2cp "$DKMSTMP/ir/rockchip_pwm_remotectl.h" "$FS:/usr/src/rockchip-pwm-remotectl-r69-1.0/rockchip_pwm_remotectl.h"
e2cp "$DKMSTMP/phy/rk630phy.c"              "$FS:/usr/src/rk630-phy-r69-1.0/rk630phy.c"
rm -rf "$DKMSTMP"

# --- Bluetooth AutoEnable — edit main.conf only if the base already ships bluez. e2cp on macOS
# returns 0 even when the source is absent, so gate on a non-empty copy ([ -s ]). Minimal base images
# ship no bluez; we NEVER auto-install it — the user installs bluez and re-runs r69-firstboot (the
# login MOTD prompts for this). ---
BTMAIN="$(mktemp)"
if e2cp "$FS:/etc/bluetooth/main.conf" "$BTMAIN" 2>/dev/null && [ -s "$BTMAIN" ]; then
  if grep -qiE '^[[:space:]]*#?[[:space:]]*AutoEnable=' "$BTMAIN"; then
    sed -E 's/^[[:space:]]*#?[[:space:]]*AutoEnable=.*/AutoEnable=true/' "$BTMAIN" > "$BTMAIN.new"
  else
    cp "$BTMAIN" "$BTMAIN.new"; printf '\n[Policy]\nAutoEnable=true\n' >> "$BTMAIN.new"
  fi
  e2cp "$BTMAIN.new" "$FS:/etc/bluetooth/main.conf"
fi
rm -f "$BTMAIN" "$BTMAIN.new"

# ---- rebrand: the ROCK 2F base ships hostname "rock-2f" -> r69 ------------------------
e2cp "$FS:/etc/hostname" "$TMP/oldhost" 2>/dev/null || true
OLDH="$(tr -d '[:space:]' < "$TMP/oldhost" 2>/dev/null)"
printf 'r69\n' > "$TMP/hostname"
e2cp "$TMP/hostname" "$FS:/etc/hostname"
if [ -n "$OLDH" ] && e2cp "$FS:/etc/hosts" "$TMP/hosts" 2>/dev/null; then
  sed "s/$OLDH/r69/g" "$TMP/hosts" > "$TMP/hosts.new"
  e2cp "$TMP/hosts.new" "$FS:/etc/hosts"
fi
# relabel the login MOTD board name (display only; BOARD= identifier stays for armbian tooling)
if e2cp "$FS:/etc/armbian-release" "$TMP/arel" 2>/dev/null; then
  sed 's/^BOARD_NAME=.*/BOARD_NAME="R69"/' "$TMP/arel" > "$TMP/arel.new"
  e2cp "$TMP/arel.new" "$FS:/etc/armbian-release"
fi
rm -rf "$TMP"

detach; ATTACHED=""; sync
echo
echo "Done -> $OUT"
echo "Flash it (with progress):"
echo "  macOS:  diskutil unmountDisk /dev/diskN; sudo gdd if=$OUT of=/dev/rdiskN bs=4M conv=fsync status=progress   (brew install coreutils)"
echo "  Linux:  sudo dd if=$OUT of=/dev/sdX bs=4M conv=fsync status=progress"
echo "  ...or Balena Etcher on either OS."
echo "Wi-Fi is fixed up on first boot; it associates reliably after the first power-cycle."
