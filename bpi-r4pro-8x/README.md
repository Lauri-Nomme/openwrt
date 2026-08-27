# OpenWrt fork for BananaPi BPI-R4 Pro 8X

Fork of [openwrt/openwrt](https://github.com/openwrt/openwrt) with a minimal
deviation branch to make the **BPi-R4 Pro 8X** fully functional, including
the **10G combo ports** (copper AS21010P / SFP) which upstream main does not
yet support.

## Branch: `bpi-r4pro-8x`

Based on `openwrt/main` + a small cherry-picked set from
[frank-w/openwrt](https://github.com/frank-w/openwrt) branch `R4Pro_PR9`
(which is itself OpenWrt main + R4Pro patches, continuously rebased).

### What upstream main already provides (NOT re-added here)
- Base board DTS (`mt7988a-bananapi-bpi-r4-pro-8x`), PCIe/mmc/SD overlays,
  FIT partitions, MxL86252 switch node — merged via PR #21083
- MxL862xx DSA driver (v7.2 backports incl. SerDes ports)
- `kmod-phy-aeonsemi-as21xxx` + `aeonsemi-as21xxx-firmware` packages
- U-Boot support for the 8X (emmc/sdmmc/snand)
- Device entry in `target/linux/mediatek/image/filogic.mk`

### What this branch adds (the deviation)
All under `target/linux/mediatek/patches-6.18/`:

| Patches | Purpose |
|---|---|
| `801-01` `801-02` | PHY_DETACH_NO_HW_RESET flag + as21xxx use |
| `802-01` `802-02` `802-03` | as21xxx link corner case, read_status, C45 autoneg |
| `804` `805` | as21xxx C45 read workaround, discard stale response |
| `968` | **lan-phy/lan-sfp/wan-phy/wan-sfp combo-port overlays** (replaces upstream `968-sfp-hog`) |
| `969` | as21xxx additional match/read fixes |
| `973` | AS21010P PHY nodes `phy24`/`phy28` with LEDs |
| `974` | as21xxx AS2101x runtime behavior fixes |
| `975` | usxgmii link flapping fix on mac1 |
| `976` | phy LED fixes |
| `977` `978` | as21 LED + ethtool advertisement fixes |

Plus:
- `target/linux/mediatek/image/filogic.mk` — 8X device gains
  `kmod-phy-aeonsemi-as21xxx aeonsemi-as21xxx-firmware` and the 4 combo
  overlays in `DEVICE_DTS_OVERLAY`
- `package/boot/uboot-mediatek/patches/472-add-bpi-r4-pro-8x.patch` — PCIe
  Gen3, NVMe, and combo overlays in `bootconf_extra`

### Why overlays instead of the downstream eth-mux
The 10G combo ports route a SerDes lane to either the copper PHY or the SFP
cage via one GPIO. Instead of a runtime mux driver, this branch uses U-Boot
DTS overlays: pick SFP **or** PHY per boot via `bootconf_extra`. Pure DT, no
kernel mux framework needed, survives kernel bumps.

## Build

Use the committed build script from the OpenWrt tree root (it seeds the
config from `config.seed` — the exact `.config` that produced a verified
image, including the package set carried over from the original Banana):

```sh
# from the OpenWrt tree root:
bpi-r4pro-8x/build.sh
```

Or manually:

```sh
./scripts/feeds update -a
./scripts/feeds install -a
cp bpi-r4pro-8x/config.seed .config
make oldconfig        # NOT make defconfig (drops the device/boot symbols)
make -j$(nproc)
```

Images land in `bin/targets/mediatek/filogic/`:
- `openwrt-mediatek-filogic-bananapi_bpi-r4-pro-8x-sdcard.img.gz` — write to
  microSD, boot (non-destructive)
- `*-squashfs-sysupgrade.itb` — sysupgrade
- U-Boot `*-emmc/sdmmc/snand-*` fip/preloader for permanent install

### Combo-port media
Both 10G combo ports default to **copper** (`lan-phy` + `wan-phy`), baked
into the U-Boot `bootconf_extra`. To switch a port to SFP per boot, set the
U-Boot env on the device:

```sh
fw_setenv bootconf_extra 'mt7988a-bananapi-bpi-r4-pro-cn13#mt7988a-bananapi-bpi-r4-pro-cn14#mt7988a-bananapi-bpi-r4-pro-8x-lan-sfp#mt7988a-bananapi-bpi-r4-pro-8x-wan-sfp'
```

Overlays available: `-wan-phy` / `-wan-sfp` / `-lan-phy` / `-lan-sfp`.

## Rebase / retarget when upstream main moves

```sh
git fetch upstream
git rebase upstream/main          # or: git reset --hard upstream/main, re-apply
# quilt patches are applied by make target/linux/clean + rebuild
make target/linux/clean
make
```

Or track frank-w's `R4Pro_PR9` (his branch is rebased regularly):

```sh
git fetch frankw
git log --oneline frankw/R4Pro_PR9 -- target/linux/mediatek/patches-6.18/
# cherry-pick / diff any new R4Pro-relevant patches
```

## Upstream tracking
- phy_port framework merged into Linux mainline (Feb 2026).
- Generic MII mux framework: **not yet merged** — this is why runtime
  SFP/copper switching still requires the overlay approach.
- Watch: Maxime Chevallier's netdev series + any mediatek as21xxx backports
  in upstream OpenWrt; once they land, this deviation can shrink further.