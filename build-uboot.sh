#!/usr/bin/env bash
# Build the R69's bootable u-boot.itb (rk3528) from mainline U-Boot + Rockchip's ATF blob,
# straight into firmware/u-boot.itb (what build-image.sh bakes in). All inputs are pinned so the
# build is reproducible. Why mainline + why we keep the factory idbloader: HOW-IT-WAS-DONE.md.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
BUILD="$REPO/uboot-build"                         # scratch (gitignored): the clones + compile tree
OUT="${1:-$REPO/firmware/u-boot.itb}"             # the artifact we ship; pass an absolute path to override

# --- pinned dependencies (bump deliberately, never float) ---
UBOOT_REPO="https://github.com/u-boot/u-boot.git"
UBOOT_TAG="v2026.04"                              # mainline release; boots Armbian via distro_bootcmd
RKBIN_REPO="https://github.com/rockchip-linux/rkbin.git"
RKBIN_SHA="ecb4fcbe954edf38b3ae037d5de6d9f5bccf81f4"
BL31="bin/rk35/rk3528_bl31_v1.21.elf"            # ATF (EL3 secure monitor); recognizes RK3518
TPL="bin/rk35/rk3528_ddr_1056MHz_v1.13.bin"      # mainline binman needs a TPL to assemble its image; the FIT we extract is TPL-independent
DEFCONFIG="generic-rk3528_defconfig"             # mainline's catch-all rk3528 board (no vendor board support needed)

[ "$(uname -s)" = Linux ] || { echo "Linux host needed — on macOS run ./build-uboot-finch.sh"; exit 1; }
# native gcc on arm64, cross prefix otherwise
if [ "$(uname -m)" = aarch64 ] && ! command -v aarch64-linux-gnu-gcc >/dev/null; then
  : "${CROSS_COMPILE:=}"; else : "${CROSS_COMPILE:=aarch64-linux-gnu-}"; fi
export CROSS_COMPILE ARCH=arm64
command -v "${CROSS_COMPILE}gcc" >/dev/null || { echo "Missing ${CROSS_COMPILE}gcc toolchain"; exit 1; }

mkdir -p "$BUILD"; cd "$BUILD"

# rkbin pinned to an exact commit (GitHub serves a bare SHA via fetch)
if [ ! -e "rkbin/$BL31" ]; then
  rm -rf rkbin && mkdir rkbin && ( cd rkbin
    git init -q && git remote add origin "$RKBIN_REPO"
    git fetch -q --depth 1 origin "$RKBIN_SHA" && git checkout -q FETCH_HEAD )
fi

# mainline u-boot pinned to a release tag
[ -d u-boot ] || git clone -q --depth 1 -b "$UBOOT_TAG" "$UBOOT_REPO" u-boot

cd u-boot
make "$DEFCONFIG"
make -j"$(nproc)" BL31="../rkbin/$BL31" ROCKCHIP_TPL="../rkbin/$TPL"   # binman emits u-boot.itb (FIT: ATF + u-boot) as a byproduct
cp u-boot.itb "$OUT"                                                   # ship only this FIT; the built idbloader is discarded

echo "-> $OUT ($(wc -c < "$OUT") bytes), mainline U-Boot $UBOOT_TAG — baked into the image by build-image.sh."
