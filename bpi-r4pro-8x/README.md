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

## Live configuration of the production Banana (as of 2026-09-03)

The running device boots from **SPI-NAND with a NAND `rootfs_data` overlay**
(persisted across reboots). Config lives in `/overlay/upper/etc/config/`
on the NAND volume.

**Hostname:** `banana`

**Network** (`/etc/config/network`):
- `br-lan` = lan1 lan2 lan4 lan5 lan6 → **10.222.1.2/24**
- `wan` = **eth1** (10G WAN combo) → **DHCP** (ISP uplink)
  - note: the WAN combo netdev is `eth1` (the `wan-phy` overlay does not
    assign an `openwrt,netdev-name`), so `network.wan.device='eth1'`
- the 10G LAN combo = `lan6` (MxL switch port 13, Aeonsemi AS21010JB1 PHY,
  usxgmii) — present in br-lan, links when a cable is plugged in

**Wireless** (`/etc/config/wireless`, mt7996e card, country EE):
- `banaiot`   — 2.4 GHz ch **7**, WPA2
- `banana5ax` — 5 GHz  ch **48**, EHT80, WPA2

**collectd / luci_statistics** (`/etc/config/luci_statistics`):
- Enabled plugins: `cpu interface iwinfo load memory network rrdtool sensors thermal`
- Reports to changwang central collectd: `Server "10.222.1.1" "25826"`
  (via `config collectd_network_server { host 10.222.1.1, port 25826 }`
  — note `stat-genconfig` needs a dedicated `collectd_network_server`
  section with `host`+`port`, not a list on the statistics section)
- RRD data locally in `/tmp/rrd` and remotely in changwang's
  `/var/lib/collectd/rrd/banana/`

**Persistence:** `uci commit` writes into `/overlay` which IS the NAND
`rootfs_data` volume (`/dev/ubi0_6`); `sync` makes it durable.

---

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

## Boot-source switches (BPI-R4 / R4 Pro)

Two slide switches (docs call them **SW3-A** and **SW3-B**) select the boot
media. Table from BPI "Getting Started BPI-R4":

| SW3-A | SW3-B | Boot source |
|---|---|---|
| 1 | 1 | SD card |
| **0** | **1** | **SPI NAND** |
| 1 | 0 | eMMC |

Useful combos in practice:
- **SPI NAND** (production): SW3-A **down (0)**, SW3-B **up (1)**
- **SD card** (recovery tool): SW3-A **up (1)**, SW3-B **up (1)**

## Field notes (2026-09-03) — the NAND adventure & rescue

What happened and how the board was recovered, for future reference.

### Symptom
After an interrupted write test, NAND boot failed in U-Boot:

```
ubi0 error: ubi_read_volume_table: the layout volume was not found
ubi0 error: ubi_attach_mtd_dev: failed to attach mtd2, error -22
UBI error: cannot attach mtd2
** Cannot find mtd partition "ubi"
```

…then falling back to TFTP. **Important:** even with a corrupt UBI volume
table, the Linux kernel attaches the same NAND fine (0 bad PEBs, all
volumes readable) — only U-Boot's stricter parser chokes.

### Rescue procedure (what actually worked)
1. Booted from the **SD card** (SW3-A=1, SW3-B=1). The SD card carries our
   custom U-Boot + recovery image, so the board comes up even with NAND dead.
2. From that U-Boot menu, used **option 7 "Install bootloader, recovery and
   production to NAND"** — it flashes U-Boot, env, recovery and a production
   image from the SD into NAND with a fresh, valid UBI.
3. Rebuilt/updated NAND from Linux (`ubiupdatevol` the `fit`/`recovery`
   volumes to the newest images; the `fit` volume was resized
   `ubirmvol`/`ubimkvol -s 36MiB` first because the new image is larger).
4. Set boot switches back to SPI NAND and verified standalone boot.

### Locked-volume gotcha
While UBI is attached, the kernel always block-maps the `fit` volume
(`ubiblock0_4` → `/dev/fit0`), and there is **no runtime way** to remove
that block device (built-in fitblk, no sysfs delete knob). This blocked any
`ubiupdatevol` on `fit` during a running (non-TFTP-locked) boot. The working
sequence that did NOT hit this: boot from SD → U-Boot option 7 wrote NAND
directly; subsequent `ubiupdatevol` of `fit` worked only because the volume
was recreated and the block device had no holders at that moment.

### Backups
Full NAND backup exists on changwang at
`~/dev/openwrt-bpi-r4pro-8x/backups/` and `/data/tftp/repair/`:
`bl2.bin`, `fip.bin`, `env.txt`, `fit.itb` (stock prod), `recovery.itb`
(stock), `rootfs_data.bin` (live overlay incl. config), plus the newest
`production.itb` / `recovery-new.itb`. `backups/recover.sh` verifies them;
`rootfs_data.bin` is a raw UBIFS dump (magic `31 18 10 06`) — mountable via
`nandsim`/`ubifs` tooling on changwang if the Banana is down.