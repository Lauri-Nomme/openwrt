# 760-29 rework: runtime verification (RX-buffer ring realloc worker)

Date: 2026-09-19. Branch: `bpi-r4pro-8x-v2-multiring-napi`.
Target: BPI-R4 Pro 8X (MT7988, mtk_eth_soc built-in). Kernel: linux 6.18.44.

Status: **hardware-verified**. This documents the procedure + results so the
rework can be re-validated after any further change.

---

## 1. Object under test

- Rework of patch `760-29` (`mtk_eth_soc: reallocate RX rings on runtime MTU
  change`): replaces the heavy full-FE `mtk_pending_work` reset with a
  dedicated light `rx_buf_len_work` worker (rings-only, under
  `MTK_RESETTING`), `mtk_rx_buf_len()` derive-at-ring-alloc, and SDL
  programmed in `mtk_dma_init()` for the no-HWLRO path. See
  `760-29-rework-design.md` for the full design + rationale, and
  `760-29-handoff-ctx.md` for the implementation handoff.
- Patch is quilt-canonical (second `make target/linux/refresh V=s` is a no-op).
  `980` re-baselined in hunk line numbers only.

Commits (pushed to `origin/bpi-r4pro-8x-v2-multiring-napi`):
- `6ecd87b87f` mediatek: mtk_eth_soc: rework 760-29 to dedicated rx-ring realloc worker
- `eb8f58aedf` bpi-r4pro-8x: notes - 760-29 rework handoff context
- Image revision on device: **r195-eb8f58aedf**

---

## 2. Build

```
make -j24 target/linux/compile V=s     # authoritative kernel build (OK)
./bpi-r4pro-8x/build.sh                # full image set from config.seed (exit 0)
```

Artifacts staged in `/data/tftp/bpi-r4pro-8x-v2-multiring-napi-rxrework/`:
`*-squashfs-sysupgrade.itb`, `*-initramfs-recovery.itb`, `*-sdcard.img.gz`.

Sysupgrade image md5: `dfbc47f35b619a56d3e15389d0d85f99` (matches on device).

---

## 3. Flash procedure (retain config)

1. Pre-state snapshot: banana was `r182-042ac7380d`, `br-lan` mtu 9000.
2. Clear pstore (otherwise recovery could auto-boot):
   `ssh root@10.222.1.2 'rm -f /sys/fs/pstore/*'`
3. Transfer + verify:
   `cat ...squashfs-sysupgrade.itb | ssh root@10.222.1.2 'cat > /tmp/img.itb; md5sum /tmp/img.itb'`
4. `ssh root@10.222.1.2 'sysupgrade /tmp/img.itb'` (NO `-n` -> config retained).
   Output: `Signature check OK`, `Saving config files...`, `Commencing upgrade`.
5. Wait for SSH; post-flash revision **r195-eb8f58aedf**, config intact.

---

## 4. Runtime verification — procedure & results

### 4.1 Core contract: live ring realloc on running interface

Toggle the **off-path** conduit `eth0` (leaf `lan5` has no carrier, so the data
path via `eth2`/`br-lan` is untouched) between the 1536 and 9216 buckets.
Both the pdma `SDL` and the MAC `max-rx` are re-programmed from
`eth->rx_buf_len` which `mtk_dma_init()` re-derives on ring (re)alloc.

| Step | Command (on banana) | dmesg result |
|---|---|---|
| boot | netifd raises conduits to jumbo | `rx buffer length 1536 -> 9216, reallocating the rx rings` (t=37.5s) |
| shrink | `ip link set dev eth0 mtu 1504` | `rx buffer length 9216 -> 1536, reallocating the rx rings` (t=571.8s) |
| grow | `ip link set dev eth0 mtu 9004` | `rx buffer length 1536 -> 9216, reallocating the rx rings` (t=577.4s) |

Post-checks at each step:
- `eth0/eth1/eth2` stayed `up`, `carrier=1` (no link flap).
- `dmesg | grep -ic "skb_over_panic\|WARNING:"` = **0**.
- Conduit `carrier_changes` = **1** each (single boot link-up only -> the two
  live reallocs never toggled the links).
- Conduit `rx_errors`/`tx_errors` = **0** on eth0/eth2 (eth1 WAN had 2 pre-existing
  rx_errors, untouched by the test).

### 4.2 Functional jumbo test

The 8K baseline initially failed with `sendmsg: Message too long`. Root cause was
**environmental, not the rework**:
- changwang fabric NIC `eth0` was mtu **1500** (not 9000 as documented).
- banana DSA conduit `eth2` was mtu **1504** (user ports at 9000 but the conduit
  had not been elevated).

Fix applied: `sudo ip link set eth0 mtu 9000` (changwang),
`ip link set dev eth2 mtu 9004` (banana). No ring realloc was triggered (same
9216 bucket — expected).

| Test | Command | Result |
|---|---|---|
| 8K DF ping cw→banana | `ping -M do -s 8000 -c3 10.222.1.2` | 3/3, ~0.37 ms |
| 8K ping banana→cw | `ping -s 8000 -c3 10.222.1.22` (busybox, no -M) | 3/3, ~0.34 ms |
| iperf3 banana→cw | `iperf3 -c 10.222.1.1 -t 6` | **9.88 Gbit/s**, 0 retr (sender) |
| iperf3 cw→banana | `iperf3 -c 10.222.1.2 -t 6` | **9.83 Gbit/s**, 24 retr (~0.4%) |

End state MTUs: eth0=9004, eth1=1500 (WAN), eth2=9004, br-lan=9000, lan*=9000.

### 4.3 CI (GitHub Actions, fork mirror)

Run `35466581399` "Build Kernel" (on push of eb8f58aedf):
- `Check Kernel patches (mediatek, filogic)` — **PASSED** (12m10s).
- Build jobs for mediatek/filogic, mt7623, mt7629 — in progress at time of
  writing (patch series is shared across the mediatek subtargets).

---

## 5. Gotchas / notes for the next run

- **Do not** background a socket-listening process inside a captured shell step
  (`iperf3 -s ... &` with inherited stdout) — it wedges the step until timeout.
  On OpenWrt use `iperf3 -s -D` (daemon mode); on Debian use `setsid ... </dev/null
  >log 2>&1 &` or the daemon flag.
- changwang has a recycled `iperf3 --server --bind 10.222.1.1` process that
  respawns; bind/point clients at `10.222.1.22`/`10.222.1.1` accordingly.
- busybox `ping` has no `-M do`; use iputils `ping -M do` from changwang for a
  DF (unfragmented) jumbo test, or `ping -s 8000` for a fragmented check.
- The DSA conduit mtu does not self-elevate from the user ports on this tree;
  raise `eth2` to `9004` manually (also `eth0` if lan5 is used).
- The realloc worker is async (scheduled), so give it ~1 s before grepping
  dmesg, and expect the change to appear as a new timestamped line.

---

## 6. Serial console boot audit (`/data/tftp/console.log`)

Source: minicom capture spanning many boots (40+ "Starting kernel" markers).
This section audits the **r195-eb8f58aedf** boot (last region, kernel built
`Sep 19 20:10:29`); historical occurrences are given to show pre-existence.

### 6.1 Result: the rework boot is clean

- Kernel boots and driver probes: `eth0/eth1/eth2: mediatek frame engine at
  ... irq 104`; `br-lan` up at mtu 9000; UBI healthy (`good PEBs: 2032,
  bad PEBs: 0`).
- **No** oops/panic/RIP/segfault/hung-task/soft-lockup/RCU-stall/OOM, **no**
  skb/mt8090 page_pool/DMA/PSE warnings.
- The worker's three realloc events are visible on the serial console too:
  boot grow `1536 -> 9216` (t=37.5s) and our live shrink `9216 -> 1536`
  (t=571.8s) / grow `1536 -> 9216` (t=577.4s).
- WLAN `mt7996e` firmware loads (WM/DSP/WA, build 2026-03-11); MxL86252
  `switch ready after 2490ms, firmware 1.0.85`; AS21010 PHY fw 1.9.1.
- **No `mtk_ppe`/WED errors anywhere in the whole log.**

### 6.2 Noteworthy (all pre-existing, NOT caused by the rework)

| # | Log line | Context / note |
|---|---|---|
| 1 | `mt7530-mmio ...: nonfatal error -34 setting MTU to 1500 on port 0` (and mxl862xx port 1), followed by `eth0/eth2: mtu greater than device maximum` + `mtk_soc_eth eth0: error -22 setting MTU to 1504 to include DSA overhead` | Present in **11+ boots** (back to pre-rework). DSA's early conduit-mtu provisioning is rejected; netifd later sets the real MTUs. This is why user-port 9000 never propagates to the conduit (stays 1504) and the manual `eth2 mtu 9004` was needed for CPU-bound jumbo (§4.2/§5). Harmless for the realloc path. |
| 2 | `mtk-pcie-gen3 11xx0000.pcie: probe ... failed with error -110` | 96× across log; timeouts on non-WLAN PCIe controllers (mt7996e WLAN on the one that succeeds). Likely unpopulated slots. |
| 3 | `xhci-mtk 11190000.usb: probe ... failed with error -110` | 47×; USB3 controller timeouts. |
| 4 | `mtk-xsphy soc:xs-phy@11e10000: failed to get ref_clk(id-1)` | 49×; optional second ref clock. |
| 5 | `Alternate GPT is invalid, using primary GPT` | 41×; benign block-device scan. |
| 6 | `block: unable to load configuration (fstab: Entry not found)` | Expected: no `/etc/config/fstab` (dnsmasq/fstab disabled). |
| 7 | `urandom-seed: Seed file not found (/etc/urandom.seed)` | First boot after sysupgrade (fresh seed). |
| 8 | `rdinit=/init failed: -2, ignoring` | Normal UBI rootfs fallback. |
| 9 | `mt7996e ... Firmware Version: ____000000` | Blank placeholder fields in fw banner — cosmetic, loads fine. |