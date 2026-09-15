# RSS/LRO — portability analysis to 6.18.44

Status: **NOT portable as-is.** Frank-w's RSS/LRO patches (from `6.18-main`,
BPI-Router-Linux) do not apply to upstream 6.18.44.

> **Update (2026-09-13):** the RSS half has since been **hand-ported** onto
> 6.18.44 (option 2 below) on branch `bpi-r4pro-8x-v2-multiring-napi`. It
> builds clean but the first TFTP-boot test **hangs in `mtk_eth` module init**.
> See [`rss-multiring-napi-experiment.md`](rss-multiring-napi-experiment.md)
> for the port details, module-swap rollback plan and boot-log diagnosis.
> LRO remains unported.

## Commits (RSS/LRO series, dependency order)

| commit | content | applies to 6.18.44? |
|---|---|---|
| `f7157855` Add register definitions | reg-map offsets (rss_glo_cfg, lro_*, rx_cfg, int_grp3, tx/rx_delay_irq, lro_alt_dbg*) | ✅ (verified clean) |
| `d319bc5653` Add RSS support | RSS init/indr-table/hash + **ring-NAPI ownership rework**; measured 7.3 Gbit/s MT7988 | ❌ 17/57 hunks |
| `c28e2d70bc` Add LRO support | HW-LRO rings + IRQ; reworks existing `mtk_hwlro` | ❌ 4+2 hunks |
| `66bc038ce3` Fix immutable-string IRQ | 1-line | ❌ (context out of date) |

## Why they fail on 6.18.44

1. Our tree's `mtk_eth_soc.c` = upstream 6.18.44 (no frank-w downstream).
2. RSS/LRO write against register fields that the **register-defs patch adds** —
   that part is fine (patch 1 applies).
3. RSS/LRO code uses functions/context that **do not exist in 6.18.44**:
   - `mtk_update_rx_cpu_idx` ring-NAPI pattern (different RX-ring ownership
     in frank-w's older tree vs 6.18.44 upstream).
   - `mtk_hwlro_add_ipaddr_idx`, `mtk_hwlro_netdev_enable` renames — **0
     occurrences** in our 6.18.44 (upstream keeps older `mtk_hwlro` shape).
4. Therefore the LRO/RSS patches cannot be applied by just picking the 4
   commits; they are entangled with frank-w's whole mtk_eth_soc development
   lineage (ring ownership, NAPI, XDP setup).

## Options

1. **Do not apply (recommended)**. Register-defs alone is pointless without
   RSS/LRO. Wait for RSS/LRO to land in upstream main (frank-w's netdev RFC)
   → then it will apply/rebase cleanly onto our tree.
2. Re-implement RSS/LRO onto 6.18.44's ring-NAPI model — a proper porting
   effort, risk of divergence, not a mechanical pick.
3. Adopt frank-w's mtk_eth_soc lineage wholesale — diverges from upstream
   policy, large change, not advisable for a stable image.

## Note on expected value

- RSS on MT7988: **7.3 Gbit/s** measured upstream-internal with 4 CPUs
  (forum user saw 4.5→8.4 with RSS).
- LRO helps further by cutting per-packet cost, but current mainline
  `mtk_hwlro` already provides *some* LRO in 6.18.44 (old fixed-ring form);
  frank-w's is the newer register-based form.

## Where the RSS/LRO work lives
- `frank-w/BPI-Router-Linux` branch `6.18-main` (merged v6.18.49).
- netdev RFC: see forum #26071; patchwork series (Nov 2025) still unmerged.
- No timeline yet.
### Upstream status check (2026-09-16, after flash + RSS-measurement phase)

**OpenWrt main absorbed the 8X board work** — all PRs cited in
`bpi-r4pro-8x/README.md` are MERGED:
- PR #21083 (BPi-R4 Pro 8X support) — merged 2026-08-24
- PR #24900 (as21xxx phy) — merged 2026-09-01
- PR #23477 / #24642 (MxL862xx DSA sync) — merged 2026-05-27 / 2026-08-23
- PR #24892 (mxl862xx assisted learning) — merged 2026-09-01

**Kernel RSS/LRO series is STILL NOT merged** (now `[net-next v8]`, posted
2026-05-09 by Frank Wunderlich, from Mason Chang's SDK series). Jakub
Kicinski requested splitting it (multi-queue/NAPI support vs RSS programming);
review ongoing. Track:
- patchwork/lore: "Add RSS and LRO support" mtk_eth_soc, v8 (2026-05-09), msg
  id `20260509190938.169290-1-linux@fw-web.de`
- key review points raised so far: `rss_num=4` set on mt7981/7986 without
  `MTK_RSS` (inconsistent caps); `.get_rxfh`/`.set_rxfh` exposed
  unconditionally for all SoCs (should be gated on MTK_RSS);
  `mtk_dim_rx` v3 branch only programs 2 ring slots; `MTK_RX_DONE_INT(eth,0)`
  changed V3 bit 14 → 24; `rx.desc_size`-gated (not caps-gated) LRO paths.

**Upstream v8 deltas vs OUR 760-21/22/23/24 port** (things to cherry-pick if
upstream ever merges — or to learn from now):
- `netdev_rss_key_fill()` + `ethtool_rxfh_indir_default()` (randomized key
  per boot) instead of our hardcoded static key.
- `.get_rx_ring_count` new ethtool op (upstream moved GRXRINGS there) —
  our 760-24's GRXFH handling would need rebasing onto that.
- Keeps `MTK_HWLRO` (rings 4-7, `MTK_RX_NAPI_NUM=8`) on MT7988 — RSS and
  HW-LRO rings coexist; our port pruned HWLRO (note that as "upstream does
  NOT prune").
- Cover letter claims **~7.3 Gbps RX** on MT7988 with the 4 PDMA IRQs spread
  to 4 CPUs via `/proc/irq/*/smp_affinity` — higher than our measured
  ~5.4 G (we spread threaded-NAPI kthreads; they spread the IRQs). Worth
  re-testing whether spreading IRQs AND kthreads together or the HWLRO rings
  account for the difference.

**Action when RSS/LRO merges upstream:** the 760-21/22/23/24 patches should
be dropped in favour of the upstream kernel series (and re-verify nothing of
760-24's ethtool surface is lost).
