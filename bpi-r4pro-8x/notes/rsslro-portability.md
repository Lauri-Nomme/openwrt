# RSS/LRO — portability analysis to 6.18.44

Status: **NOT portable as-is.** Frank-w's RSS/LRO patches (from `6.18-main`,
BPI-Router-Linux) do not apply to upstream 6.18.44.

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