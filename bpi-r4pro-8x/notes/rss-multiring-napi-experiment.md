# RSS multi-ring NAPI port (6.18.44) — port, module swap, TFTP-boot experiment

Status (2026-09-13): **ported + builds clean; TFTP-boot test HANGS in
`mtk_eth` module init — under active diagnosis with an instrumented driver.**
NAND untouched throughout (TFTP boot is RAM-only).

Branch: `bpi-r4pro-8x-v2-multiring-napi` (off `bpi-r4pro-8x-v2`).

## Why

The MT7988 bridged/local-routing path is CPU-limited to ~1.6 Gbit/s on the
upstream single-NAPI `mtk_eth_soc`. frank-w's RSS series spreads flows across
4 PDMA RX rings (measured ~7.3 Gbit/s; forum user 4.5→8.4). Upstream 6.18.44 is
single-NAPI, so the series does not apply (see `rsslro-portability.md`); this is
a hand-port onto 6.18.44.

## What was built (6 commits on the branch)

| commit | change |
|---|---|
| `0460d996de` | **760-21** register definitions + **760-22** multi-ring NAPI + RSS (87 hunks) |
| `a038cfdac3` | **760-23** restrict `MTK_PDMA_INT`/`MTK_RSS` to **MT7988 only** |
| `d49c11f56d` | filogic: `CONFIG_NET_MEDIATEK_SOC=m` (driver as a module) |
| `d3bac81c44` `4d414712a4` `538802bccf` | `kmod-net-mediatek` package + ship on bpi-r4-pro devices |

### 760-22 port highlights (onto the single-NAPI tree)

- `struct napi_struct rx_napi` → `struct mtk_napi rx_napi[MTK_RX_NAPI_NUM]`
  (per-ring NAPI, each bound to `rx_ring[i]`).
- `MTK_RX_DONE_INT` object-macro → function-like `MTK_RX_DONE_INT(ring_no)`
  (`BIT(24+ring)` on netsys-v3, `BIT(30)`/`BIT(24+ring)` on v1/v2).
- Per-ring PDMA IRQs `pdma0..3` (`mtk_get_irqs_pdma`, `IRQF_SHARED`,
  `dev_id=&rx_napi[i]`) — the names already exist in the MT7988 dts.
- `mtk_poll_rx` drains the NAPI's own ring; `mtk_update_rx_cpu_idx(eth, ring)`.
- RSS core: Toeplitz key + 128-entry indirection table, PSE ring mode,
  int-group routing, ethtool `rxfh` get/set.
- 6.18 drift fixed: upstream uses `desc_shift`, not `desc_size` →
  `!mtk_is_netsys_v3_or_greater(eth)`; `reg_map` locals added where hwlro used
  the macros.
- immutable-string fixup (`char rxring[]`).

### 760-23 (the "makes sense" fix)

The raw series granted `MTK_PDMA_INT` to MT7981/MT7986. **MT7981 has no
`pdma0..3` interrupts in its dts** (only `fe0..fe3`) → probe would fail on all
MT7981 boards. MT7986 has the IRQs but gains nothing without `MTK_RSS`. Port
restricts multi-ring/RSS to **MT7988** (the only SoC with both). All other
filogic SoCs keep the exact upstream single-NAPI path.

## Module swap (rollback strategy)

`NET_MEDIATEK_SOC=m` on filogic ⇒ `mtk_eth.ko` is a loadable module (WED parts
are inside it; `mtk_wed_ops` stays builtin). A known-good **v2** `mtk_eth.ko`
is stashed at `/data/tftp/bpi-r4pro-8x-v2-multiring-napi/mtk_eth_v2-KNOWN-GOOD.ko`
(same `vermagic=6.18.44 SMP mod_unload aarch64`, 0 RSS symbols). On a bad boot:
serial console → `rmmod mtk_eth; insmod <v2.ko>` to recover without reflash.

## TFTP-boot experiment (2026-09-13) — HUNG

Booted the RSS recovery image over TFTP (U-Boot menu 2 → `$bootfile` =
`...-initramfs-recovery.itb`, RAM only, **no NAND write**).

### Observed

1. `Cannot find device "eth0"` at **preinit (~6.8s)** — **benign**. OpenWrt's
   `lib/preinit/05_set_preinit_iface` runs `ip link set eth0 up` (8X falls into
   the `*)` default case) *before* `/etc/modules.d/*` kmods load. In v2 the
   driver is builtin (netdevs at 3.9s, before preinit) so the message never
   appears; with `=m` the driver loads at ~18s, after preinit. Nothing
   functional depends on eth0 at that instant (netifd config uses `lan1..lan6`).
   Confirmed by log: v2 has eth0 at 3.9s and **no** such message; RSS printed it.
2. **Hard hang in module init.** Booted with `initcall_debug`, the console
   shows:
   ```
   [   18.473135] calling  init_module+0x0/0xfdc [mtk_eth] @ 1131
   [   78.635968] rcu: INFO: rcu_sched detected stalls on CPUs/tasks:
   ```
   `mtk_eth`'s `init_module` **never returns** — no `initcall ... returned`, no
   driver printk (not even "mediatek frame engine"). Five consecutive RCU stalls
   (60 s each → ~780 s) on **CPU 1** (busy, irq-wedged), then watchdog reset.
   The DSA/MxL switch never even gets to load.
3. NAND untouched; watchdog auto-recovered; back on v2 production.

### Diagnosis

`init_module [mtk_eth]` = `module_init(mtk_init)` → `platform_driver_register`
→ the DT node exists at boot → `really_probe` → **`mtk_probe` runs synchronously
and hangs before `mtk_add_mac`** (no "frame engine" print). The RSS port added
these probe-time steps: `mtk_get_irqs_pdma` + per-ring `request_irq`,
`mtk_napi_init`, and the `mtk_hw_init` FE-int-group changes. The next boot uses
a driver instrumented with `pr_err("MTKDBG: ...")` markers at every probe step
(31 markers, incl. `mtk_hw_reset`/`mtk_hw_init` internals) to pin the exact
function.

### Rules of thumb learned

- "Cannot find device eth0" at preinit is a **cosmetic** `=m` artifact, not a
  failure signal.
- With `=m`, `mtk_probe` runs from `init_module` and any probe-time hang wedges
  boot with **no driver output**; `initcall_debug` + `loglevel=8` is the tool
  that localises it (`calling init_module [...]` with no return).
- Boot a recovery image over TFTP (U-Boot menu 2) to test drivers with **zero
  NAND risk**.

## Artifacts

- `/data/tftp/bpi-r4pro-8x-v2-multiring-napi/` — RSS sysupgrade/sdcard/recovery
  images + `mtk_eth_v2-KNOWN-GOOD.ko`.
- `/data/tftp/openwrt-...-initramfs-recovery.itb` — RSS recovery (TFTP menu 2).
- `/data/tftp/console.log` — full console capture of the experiment.

## Next test (staged)

Instrumented recovery image (31 `MTKDBG:` markers in `mtk_eth.ko`, all `pr_err`
so loglevel-independent) is staged as the TFTP-root recovery itb. Boot via
U-Boot menu **2** with:

```
setenv bootargs 'console=ttyS0,115200n1 loglevel=8 initcall_debug'
run boot_tftp
```

Expected: the console prints `calling init_module+0x0/... [mtk_eth]`, then the
`MTKDBG:` markers up to the last step that completes — the next (unprinted)
marker names the hanging function (suspects: `mtk_get_irqs_pdma`,
per-ring `request_irq`, `mtk_napi_init`, or `mtk_hw_init` FE int-group).

## RESULT (boot with 31 MTKDBG markers) — hang located

The marker trace (console `/data/tftp/console.log`) localised the hang to a
4-line window inside `mtk_hw_init`, **after** FE/GMAC register setup and
**exactly at the rewritten DIM calls**:

```
[   16.793304] MTKDBG: hw_reset -> CHK_IDLE_EN done
[   16.797914] MTKDBG: probe request_irq block DONE     ← misnamed; it is the
              ...                                       marker right AFTER the
              ^C[   76.805846] rcu: INFO: ... CPU 1     reset call in mtk_hw_init
```

The unprinted following marker is `hw_init -> FE int grouping`. The code
executed between the two markers (printed → not printed) is: v3 `FE_GLO_MISC`
r/w, pctl GPIO regmap writes, MAC-MCR loop, CDMQ r/w — **all identical to
v2** — and then the **only RSS-specific change in this window**:

- `mtk_dim_rx()` → for netsys-v3 writes **`reg_map->pdma.rx_delay_irq` (`0x6ac0`)**
  with `val |= val << MTK_PDMA_DELAY_RX_RING_SHIFT` (bit 16 duplicated to ring bits)
- `mtk_dim_tx()` → for netsys-v3 writes **`reg_map->pdma.tx_delay_irq` (`0x6ab0`)**

v2 (working) wrote DIM only to `pdma.delay_irq` (`0x6a0c`). The RSS port
introduced the split TX/RX delay-IRQ registers `0x6ab0/0x6ac0` together with
the `val << 16` ring-duplication, inside the `mtk_dim_rx/tx` that
`mtk_hw_init` calls inline during probe.

**Conclusion:** the hang is caused by the RSS DIM rewrite — most likely
writing the wrong register offset (`0x6ab0/0x6ac0` vs the real PDMA
delay-IRQ register) and/or the `val << MTK_PDMA_DELAY_RX_RING_SHIFT`
duplication at a point in probe where it corrupts the IRQ config and fires an
unhandled interrupt (no NAPI/IRQ handler registered yet) → CPU 1 IRQ storm +
RCU stall. `mtk_hw_init` subsequently disables IRQs (`mtk_tx/rx_irq_disable
~0`), but the damage (pending/active IRQ with no handler) already spins CPU1.

### Proposed fix (next boot to validate)

Keep the v2 DIM behaviour on 6.18.44: in `mtk_dim_rx`/`mtk_dim_tx`, **drop the
RSS split-register + ring-shift path for netsys-v3** and write the plain value
to `reg_map->pdma.delay_irq` (0x6a0c) exactly like upstream. I.e. remove the
`rx_delay_irq`/`tx_delay_irq`/`MTK_PDMA_DELAY_RX_RING_SHIFT` branches added by
the port. If it then boots, the RSS ring hash/NAPI layer can still be tested
(this only affects interrupt coalescing, not RSS routing).

### Fix applied (build 17:48, staged on TFTP)

`mtk_dim_rx` and `mtk_dim_tx` restored to upstream bodies (single
`pdma.delay_irq` 0x6a0c write, no 0x6ab0/0x6ac0 split, no `val<<16` ring
duplication). The instrumented module (31 `MTKDBG:` markers) was rebuilt and
the recover ITB restaged. **Next TFTP boot validates the fix** — if it boots,
the hang was the DIM delay-IRQ rewrite as suspected.
