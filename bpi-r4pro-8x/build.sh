#!/usr/bin/env bash
# Build script for BPI-R4 Pro 8X OpenWrt (branch bpi-r4pro-8x)
#
# Run from the top of an OpenWrt source tree that has this script
# (e.g. the repo root). It reproduces the full 8X image set including
# the package set that was installed on the user's Banana
# (luci, collectd, ksmbd, iperf3, ...).
#
#   usage:  path/to/bpi-r4pro-8x/build.sh   (run from OpenWrt tree root)
set -euo pipefail

# Top of the OpenWrt tree = parent of the directory containing this script
TOPDIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TOPDIR"

SEED="$(dirname "$0")/config.seed"

# 1. Update + install feeds (needed once; idempotent)
./scripts/feeds update -a
./scripts/feeds install -a

# 2. Seed .config. The device symbol + U-Boot/TFA deps must survive,
#    so use `make oldconfig` (NOT `make defconfig`, which drops them).
#    A full working .config snapshot lives in config.seed next to this script.
if [ -f "$SEED" ]; then
    cp "$SEED" .config
else
    cat > .config <<'EOF'
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_mediatek_filogic_DEVICE_bananapi_bpi-r4-pro-8x=y
CONFIG_PACKAGE_u-boot-mt7988_bananapi_bpi-r4-pro-8x-emmc=y
CONFIG_PACKAGE_u-boot-mt7988_bananapi_bpi-r4-pro-8x-sdmmc=y
CONFIG_PACKAGE_u-boot-mt7988_bananapi_bpi-r4-pro-8x-snand=y
CONFIG_PACKAGE_trusted-firmware-a-mt7988-emmc-comb=y
CONFIG_PACKAGE_trusted-firmware-a-mt7988-emmc-comb-4bg=y
CONFIG_PACKAGE_trusted-firmware-a-mt7988-sdmmc-comb=y
CONFIG_PACKAGE_trusted-firmware-a-mt7988-sdmmc-comb-4bg=y
CONFIG_PACKAGE_trusted-firmware-a-mt7988-spim-nand-ubi-comb=y
CONFIG_PACKAGE_trusted-firmware-a-mt7988-spim-nand-ubi-comb-4bg=y
EOF
fi
make oldconfig

# 3. Build (toolchain + kernel + images). First run is long.
make -j"$(nproc)" V=s

echo
echo "Images in bin/targets/mediatek/filogic/:"
ls -1 bin/targets/mediatek/filogic/openwrt-mediatek-filogic-bananapi_bpi-r4-pro-8x-* 2>/dev/null || true