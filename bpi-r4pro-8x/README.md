# OpenWrt fork for BananaPi BPI-R4 Pro 8X

Fork of [openwrt/openwrt](https://github.com/openwrt/openwrt) with a minimal
deviation branch to make the **BPi-R4 Pro 8X** fully functional, including
the **10G combo ports** (copper AS21010P / SFP) which upstream main does not
yet support.

## Branch: `bpi-r4pro-8x-v2` (recommended)

Fresh branch cut from **upstream `main`** (OpenWrt @ 2026-09). Upstream has by
now fully absorbed the R4 Pro 8X work and surpassed the original
`bpi-r4pro-8x` fork:

- 8X board support, MxL86252 switch, the **as21xxx PHYs and the four
  combo-port overlays** (`lan-phy/lan-sfp/wan-phy/wan-sfp`) are all in main
  (PR #21083 + #24900).
- The Aeonsemi driver is the **upstream `782-05` backport** plus newer fixes
  (`786-02` HW-reset-on-soft-reset, mediatek `805`/`969`/`970`/`974`/`976`/
  `977`: stale-C45-ID matching, IPC recovery after warm reboot, runtime
  behavior, LEDs, advertisements).
- MxL86822 driver is the 1.0.85-ready sync (PR #23477/#24642) + assisted
  learning (PR #24892).

What this branch **still changes** vs main (the minimal, intentional deltas):

| Delta | v2 | upstream main |
|---|---|---|
| Combo-port default | **Copper RJ45** (`lan-phy`/`wan-phy`) | SFP (`lan-sfp`/`wan-sfp`) |
| U-Boot PCIe | `PCIE_MEDIATEK_GEN3` | `PCIE_MEDIATEK` |
| U-Boot NVMe | `NVME_PCI` + `CMD_NVME` + `BLK` | not enabled |
| gmac1 (WAN combo) name | **`eth1`** (drop upstream `wan` rename) | `wan` |

everything else (as21xxx, MxL driver, packaging) is taken verbatim from
upstream main. See `git log bpi-r4pro-8x-v2 --not upstream/main` for the
single delta commit.

## Branch: `bpi-r4pro-8x` (superseded)

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

```sh
./scripts/feeds update -a
./scripts/feeds install -a
# minimal config
echo 'CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_mediatek_filogic_Device_bananapi_bpi-r4-pro-8x=y' > .config
make defconfig
make -j$(nproc)
```

Images land in `bin/targets/mediatek/filogic/`:
- `openwrt-mediatek-filogic-bananapi_bpi-r4-pro-8x-sdcard.img.gz` — write to
  microSD, boot (non-destructive)
- `*-squashfs-sysupgrade.itb` — sysupgrade
- U-Boot `*-emmc/sdmmc/snand-*` fip/preloader for permanent install

### Choosing combo-port media per boot
In U-Boot, set `bootconf_extra` to select:
- `mt7988a-bananapi-bpi-r4-pro-8x-wan-phy` / `-wan-sfp`
- `mt7988a-bananapi-bpi-r4-pro-8x-lan-phy` / `-lan-sfp`

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

## MxL86252 switch firmware upgrade (1.0.70 → 1.0.85)

The MxL86252 switch runs a proprietary ZephyrOS firmware on its internal flash
(an integrated ARC MCU). It is **not** stored on the host SPI-NAND; it lives in
the switch's own flash and is reached via the driver's MDIO-based devlink
interface.

### Background

- The driver requires **WSP 1.0.78+** to work well and **1.0.83+** for the
  logical PCE-rule API. Our build (kernel `6.18.44`, driver synced past
  OpenWrt PR #23477 / #24642) is **1.0.85-ready**: it selects the **XPCS v2**
  API at `fw >= 1.0.84`, uses `PCERULELOGICWRITE` at `>= 1.0.83`, and keeps a
  legacy SFP-PCS fallback for `< 1.0.84` (so 1.0.70 still probes/forwards).
- The stock board shipped with **1.0.70**. Old firmware reports
  `SerDes PCS unsupported on old firmware`, which is what left the combo LAN
  copper port (`lan6`, Aeonsemi AS21010JB1 on usxgmii) unable to link while
  the WAN combo (`eth1`) worked at 1G.

### Firmware source & integrity

The 1.0.85 firmware is distributed by BananaPi (their docs `MxL86252C update`
section + forum thread
`[BPI-R4 PRO] Maxlinear switch firmware update` #27023, post 34+). The
download is a Google Drive file:

- Drive file ID: `1UWM9FcXXODB3urIuEHKBPlv8zLsU08_E`
- Local filename: `mxl86252-fw-1.0.85-signed-xfi-upgrade-fca.bin`
  (originally `/mxl862xxc_1030_1085_1085_0069_signed_xfi_upgrade_fca.bin)`)
- **sha256: `68a510b7333d7974c1bf21a190f0bd35312db4f77abca9e93794a4e672bf9b90`**

Archived on changwang at `~/dev/openwrt-bpi-r4pro-8x/backups/` (next to the
other stock blobs bl2/fip/fit) and `/data/tftp/repair/`. Checksum file:
`backups/mxl86252-fw-1.0.85.sha256`. (Backups live outside the inner
`openwrt/` git checkout, alongside the project's top-level files.)

Format (verified against `mxl862xx_flash_validate()`):
- 20-byte MCUboot header: `image_type 0xf48af48a`, one image slot of
  2,052,096 bytes, `size2 = 0`
- Payload CRC32 (standard zlib crc, no seed) = `0x4ac60b30` == header
  `checksum_1`

### Download gotcha (do not repeat)

Saving the file from a phone/browser "Save Page As" on the Google Drive
*preview* page yields an **MHTML web snapshot** (`From: <Saved by Blink>`,
`Snapshot-Content-Location: https://drive.google.com/file/d/.../view`) — not
the binary. `devlink flash` then fails with `firmware image validation
failed`. To get the real blob, download via the Drive direct endpoint and then
verify magic + CRC:

```sh
curl -L "https://drive.google.com/uc?export=download&id=1UWM9FcXXODB3urIuEHKBPlv8zLsU08_E" -o mxl-fw.bin
python3 - <<'EOF'
import struct, zlib
d = open('mxl-fw.bin','rb').read()
_, s1, c1, s2, c2 = struct.unpack('<IIIII', d[:20])
assert struct.unpack('<I', d[:4])[0] == 0xf48af48a           # magic
assert len(d) == 20 + s1 + s2                                 # length
assert (zlib.crc32(d[20:20+s1]) & 0xffffffff) == c1           # crc
print("OK: valid single-image MxL firmware, size", len(d))
EOF
```

### Flash procedure

Run from the Banana (OpenWrt). The switch reboots into MCUboot rescue mode
during flashing, which **drops the network for ~1 minute** — if the Banana is
your gateway, launch the flash detached so the session survives:

```sh
# 1. install the blob where the driver can find it (request_firmware path)
cp mxl86252-fw-1.0.85-signed-xfi-upgrade-fca.bin /lib/firmware/

# 2. sanity-check current version
devlink dev info mdio_bus/mdio-bus:10     # running/stored fw 1.0.70

# 3. run detached (survives the link drop)
cat > /root/flash-mxl.sh <<'EOF'
#!/bin/sh
exec >> /root/flash.log 2>&1
echo "=== $(date) flash start ==="
devlink dev info mdio_bus/mdio-bus:10
time devlink dev flash mdio_bus/mdio-bus:10 \
     file mxl86252-fw-1.0.85-signed-xfi-upgrade-fca.bin
echo "flash rc=$? at $(date)"
sleep 30
dmesg | grep -i mxl | tail -20
devlink dev info mdio_bus/mdio-bus:10
echo "=== $(date) flash end ==="
EOF
setsid /root/flash-mxl.sh </dev/null >/dev/null 2>&1 &
```

Expected success output (`flash rc=0`, ~52s):

```
Waiting for bootloader
Erasing flash
Flashing
running:  fw 1.0.85
stored:   fw 1.0.85
```

Internal GPHY firmware also updates **0.77 → 0.105** (build 0x0069, reported as
"test version"). No driver errors appear on re-probe (the XPCS-v2 / logical-PCE
paths in this build handle 1.0.85); a `<1.0.84`-era driver would hit `-134`
(ENOTSUP) and `-1022` on PCE writes and lose all ports.

### Rollback

There is **no read-back** in the driver (devlink flash is write-only), so the
original **1.0.70 is not recoverable from the chip by the driver**. Keep the
1.0.85 blob archived here; BPI have not released a 1.0.70 image either. The
firmware uses **dual bank switching + MCUboot rescue** on the switch, so a
failed flash is recoverable in-rescue; a physical SOP-8 clip/flashrom can dump
the switch SPI (8 MB QSPI) as the only external backup route.

### Verified result (2026-09-03)

The 1.0.85 fix was confirmed live with a cable in the combo LAN copper port
(`lan6`) and changwang's Aquantia AQC113 NIC on the other end:

- **Banana `lan6`**: `Link is Up - 10Gbps/Full - flow control rx/tx`, bridge
  port moved straight to **forwarding** after the upgrade (was NO-CARRIER on
  1.0.70 with `SerDes PCS unsupported on old firmware`).
- **changwang `eth0`**: Aquantia negotiated **10Gb/s Full duplex**, link
  detected, ping ~0.17 ms, no loss.
- **Errors, both sides, both during iperf and cumulative**: `rx_errors 0`,
  `tx_errors 0`, `rx_crc 0`, `rx_dropped 0` deltas; no link flaps after the
  single `Link is Up` event (no down/up cycling over the whole session).
- **MxL switch-side RMON** (`ethtool -S lan6`): all discard/bad counters 0
  (`RxExtendedVlanDiscardPkts 0`, `MtuExceedDiscardPkts 0`, `RxBadBytes 0`);
  only benign SerDes adaptation reads present.
- **iperf3** (banana server, `-P4`, 6s): ~**1.63 Gbit/s**, **0 retransmits**.
  Aggregate is identical in single-stream and `-P4`, i.e. throughput is
  **CPU-bound on the router**, not limited by the 10G link/PHY.

## Upstream tracking
- phy_port framework merged into Linux mainline (Feb 2026).
- Generic MII mux framework: **not yet merged** — this is why runtime
  SFP/copper switching still requires the overlay approach.
- Watch: Maxime Chevallier's netdev series + any mediatek as21xxx backports
  in upstream OpenWrt; once they land, this deviation can shrink further.