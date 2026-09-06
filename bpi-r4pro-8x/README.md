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

## Config snapshot / restore

The BananaPi's working configuration (stock-derived, migrated to this fork) is
saved as plain `/etc/config/*` text files on changwang at:

```
~/dev/openwrt-bpi-r4pro-8x/backups/config-restore/
    network wireless system dhcp firewall collectd restore.sh
```

(also mirrored to `/data/tftp/repair/v1-config/` and the repo `backups/`).

Settings carried: LAN `br-lan 10.222.1.2/24` (lan1..6), **WAN = `eth1`** (10G
combo copper, DHCP, hostname `hellohi`), route `10.222.20.0/24` via
`10.222.1.1`, hostname `banana`, dnsmasq LAN server, 4 DNAT port-forwards to
changwang (`10.222.1.1`: 7777, 22222→22, 65534→80, 22→22), WiFi `banaiot`
(2g ch7) + `banana5ax` (5g ch48 EHT80), collectd → `10.222.1.1:25826`.

Restore onto any freshly-flashed system:

```sh
~/dev/openwrt-bpi-r4pro-8x/backups/config-restore/restore.sh [10.222.1.2]
```

**Interface-name notes (v1 → v2):**
- WAN combo stays **`eth1`** (the v2 branch deliberately drops upstream's
  `gmac1 → wan` rename so stock/v1 configs keep working).
- WiFi moved from per-phy `radio0/1/2` to **single `phy0` with `radio=` 0/1/2**
  (2g/5g/6g) index options — the saved `wireless` config uses the v2 format.

## Performance tuning (applied + persisted 2026-09-03)

Applied to the live Banana and persisted via `/etc/rc.local` (also saved as
`backups/config-restore/rc.local.perf`):

```sh
for c in /sys/devices/system/cpu/cpu[0-3]/cpufreq/scaling_governor; do echo schedutil > $c; done
echo 3 > /proc/irq/104/smp_affinity        # 15100000.ethernet rx status irq -> cpus 0-1
echo c > /proc/irq/105/smp_affinity        # ... -> cpus 2-3
for q in /sys/class/net/eth[12]/queues/rx-*/rps_cpus; do echo f > $q; done   # RPS all 4 cpus
```

### Software flow offload (`firewall @defaults { flow_offloading '1' }`)
- nftables flowtable on `{ br-lan, eth1 }`; accelerates **WAN NAT routing**
  (lan↔internet, incl. the DNAT port-forwards to changwang). Not applied to
  bridged LAN traffic or host-local traffic.
- **Verified clean** on this board: `ssh git@github.com` connects, and two
  35 MB downloads through the NAT produced **identical sha256** (no TCP
  truncation/reordering).

### Known MT7988A (BPi-R4 Pro) performance reality
- **SW flowtable is the right choice here.** Do **NOT** enable
  `flow_offloading_hw` (PPE):
  - GitHub openwrt #24687: MT7988 PPE HW offload *drops* throughput (burst
    congestion, ~1300 vs 1500-1800 Mbps for pure sw), and QDMA MAX_RATE is
    skipped for MT7988.
  - Forum #27340: the stock BPI `/etc/flowtable.conf` (hw offload w/ flowtable
    on the MxL ports) **corrupts large TCP segments** (SSH resets, 224-byte
    gaps) on the R4 Pro 8X. Our mainline fw4 does not ship that file.
- **Bridged LAN forwarding ceiling ~1.6-1.7 Gbit**: identical with 1/4/16
  iperf streams, CPUs at 1.8 GHz — a platform/DSA-path limit, not CPU or IRQ
  bound. Forum #23414: multi-10G bridged needs the `bridger` package (L2 only,
  not NAT routing).
- **WAN is 1G-bound** (ISP), so offload frees router CPU but can't exceed the
  uplink.

### Misc
- WiFi channel survey (2026-09-03): 2.4G moved **ch7 → ch1** (least
  interference; 5G stays ch48 — max legal power, no neighbours).
- `br_netfilter` module present but unused (`bridge-nf-* = 0`) — safe to drop
  if building images from scratch.

## Upstream watchlist (open PRs / frank-w branches)

Not yet adopted, tracked here for when they land/mature:

- **OpenWrt #24990** — `as21xxx: add hwmon temperature support`. Exposes the
  AS21xxx PHY on-chip temp via `sensors` (temp1_input); **tested on BPI-R4 Pro**
  with both AS21010JB1 PHYs at firmware 1.9.1 (our exact hardware/fw). Would
  give MxL-side PHY temps without extra drivers. Not merged yet — do not take.
- **OpenWrt #24073** — `BPI-R4 I2C1 overlay` (adds the GPIO-header I2C1 for
  INA219/SHT31 sensors via `bootconf_extra`). Useful if sensors are added.
- **OpenWrt #24800** — kernel `6.18.44 → 6.18.49` (three 6.18 bumps) — apply
  when merging upstream/main into v2.
- **OpenWrt #24687 (watch)** — MT7988 PPE HW-offload is slower + IDQMA shaping
  proposal. If adaptive QDMA shaping lands upstream, hardware offload may
  become worthwhile; revisit then.
- **frank-w branches**: `R4Pro_PR10` (Aug 30, latest as21xxx + 970),
  `R4Pro_4e` (Sep 2, 4E support). Both are en route to upstream main, which is
  already our v2 base — so v2 is ahead for the 8X; only changes that hit upstream main
  get adopted on rebase.

## UPnP (`miniupnpd`)

Enabled on the Banana: `upnpd.config.enabled '1'` (was `0`). Bound
`ext_ifname=eth1` (WAN), `listening_ip=br-lan`, port 5000 (UPnP IGD + NAT-PMP).
Config saved in the restore kit as `backups/config-restore/upnpd`. `secure_mode 1`,
perm rules allow ext ports 1024-65535 → LAN, default-deny.

## Fan (`pwm-fan`) — 5V fan on a 12V rail, no tach

The Banana drives its fans through the kernel `pwm-fan` (hwmon1, `pwm1`
0-255 = 0%..100% duty). This board actually has **5V** Noctua fans fitted,
but they are driven from the **12V** rail, so:

- `V_eff = pwm1/255 * 12V` — to keep a 5V fan ≤ 5V, cap duty at
  `255 * 5/12 = 106`.
- Fork DTS patch `050-...5v-fan-on-12v-rail.patch` recalibrates
  `cooling-levels = <0 60 83 106>` (≈ 2.8V / 3.9V / 5.0V) so even the
  hottest cooling state never overvolts the fan. Idle state sits at
  PWM 60 (≈ 2.8V), measured to hold CPU at ~47-48 °C.
- **Tach is not wired on this board.** The fan header exposes only
  VCC/GND/PWM (confirmed by frank-w and the lack of any `fan*` node in
  sysfs); the kernel `pwm-fan` tach support can't be used, so `fan1_input`
  (RPM) is not available and never will be without hardware mods. Monitor
  **fan PWM duty** instead.
- **Fan PWM → collectd** requires the `collectd-mod-exec` plugin
  (`config.seed` enables it). The box-side script
  `/usr/lib/collectd/pwmfan.sh` emits a `banana/fan-pwm` gauge; once that
  module is in the image the PWM trend lands in changwang's
  `rrd/banana/`.
- Keep-alive: `rc.local` pins the fan to PWM 60 on boot (`backups/config-restore/rc.local.perf`).
- Caveat: BPI forum #26769 documents a potential **12V fan-rail fault**
  on some R4 Pro boards (dim LEDs / weak spin). Watch for that on top of
  the 5V-vs-12V mismatch.