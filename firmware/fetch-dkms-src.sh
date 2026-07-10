#!/bin/sh
# Fetch the two out-of-tree DKMS driver *sources* from the pinned armbian/linux-rockchip commit and
# stage them into the given dirs: the IR-remote source (patched with ir/r69.patch) and the RK630
# Ethernet-PHY source (unmodified). Shared by build-image.sh (into a temp, then e2cp into the image)
# and by r69-update (straight into /usr/src on the live box). Needs network + curl + patch.
#   usage: fetch-dkms-src.sh <ir-src-dir> <phy-src-dir>
set -e
IRDIR="${1:?usage: fetch-dkms-src.sh <ir-src-dir> <phy-src-dir>}"
PHYDIR="${2:?usage: fetch-dkms-src.sh <ir-src-dir> <phy-src-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# pinned vendor-kernel commit (the branch moves; the commit doesn't) — same one HOW-IT-WAS-DONE cites
SHA=31cd4f11b5ec31fc361256a04237416f278b62b2
BASE="https://raw.githubusercontent.com/armbian/linux-rockchip/$SHA"

mkdir -p "$IRDIR" "$PHYDIR"

# IR: pristine .c/.h from the pinned commit, then our shared-IRQ patch on the .c
curl -fsSL "$BASE/drivers/input/remotectl/rockchip_pwm_remotectl.c" -o "$IRDIR/rockchip_pwm_remotectl.c"
curl -fsSL "$BASE/drivers/input/remotectl/rockchip_pwm_remotectl.h" -o "$IRDIR/rockchip_pwm_remotectl.h"
patch -p1 -d "$IRDIR" < "$HERE/ir/r69.patch"

# RK630 Ethernet PHY: unmodified vendor driver
curl -fsSL "$BASE/drivers/net/phy/rk630phy.c" -o "$PHYDIR/rk630phy.c"
