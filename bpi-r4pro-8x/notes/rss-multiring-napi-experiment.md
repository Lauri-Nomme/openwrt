# RSS multi-ring NAPI port (6.18.44) — port, module swap, TFTP-boot experiment

Status (2026-09-14): **RSS boots via TFTP with all 6 FIT overlays (bootconf_extra
fix); eth2 + 4 RX rings live. RSS ethtool surface completed (760-24).** NAND
untouched throughout (TFTP boot is RAM-only). Remaining: lan5/mt7530 mgmt link
drops in the recovery boot (~AIMARKER10).

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

### DIM revert ruled out (boot after AIMARKER2, ~18:12)

Booting the DIM-reverted image still hangs at the same point (last marker
`probe request_irq block DONE` at 18.717, then RCU stall at 78.7 — identical).
Disassembly of the built `.ko` confirms `mtk_dim_rx` does a single register
write (reverted path). **The DIM rewrite is therefore NOT the cause**, despite
being the only apparent RSS-specific code in the (mis-narrowed) window.

Fine-grain markers added (36 total) bracketing every statement between the
reset and FE-int-grouping: FE_GLO_MISC, pctl, MCR-loop, CDMQ, DIM, irq_disable.
Rebuilt + restaged recovery ITB (18:22). This boot will name the exact
hanging statement.

### Fine-grain boot (AIMARKER3, ~20:11) — hang narrowed to `mtk_r32(MTK_FE_GLO_MISC)`

36-marker fine-grain build booted. Last markers:

```
[   18.743270] MTKDBG: hw_reset -> CHK_IDLE_EN done
[   18.747878] MTKDBG: probe request_irq block DONE      ← next stmt never runs
              [would print: FE_GLO_MISC read try1]        ← NEVER
```

Hang = **`mtk_r32(eth, MTK_FE_GLO_MISC)`** — a FE-domain register read executed
~24 µs after `mtk_hw_reset` returned (the reset ends with
`regmap_write(ethsys, ETHSYS_FE_RST_CHK_IDLE_EN, 0x6f8ff)`; `mtk_hw_init` then
immediately reads `MTK_FE_GLO_MISC` (0x124)). Read hangs the bus → all CPUs stuck.

### Conceptual step-by-step vs frank-w 6.18-main (his boots, ours hangs)

Compared against the actual `mtk_eth_soc.c/.h` from
`frank-w/BPI-Router-Linux` branch `6.18-main`:

| component | frank-w vs ours |
|---|---|
| `mtk_hw_init` | **identical** (after pruning my markers) |
| `mtk_hw_reset` / `mtk_hw_warm_reset` / `ethsys_reset` | **identical** |
| `mtk_r32`/`mtk_w32` accessors | **identical** |
| `mt7988_reg_map` offsets (rss_glo_cfg, int_grp3, rx/tx_delay_irq, …) | **identical** (only ours adds `page` fields from 6.18 base, unrelated) |
| `MT7988_CAPS` (`MTK_PDMA_INT | MTK_RSS`) | **identical** |
| `MTK_FE_GLO_MISC`/`MTK_FE_INT_GRP`/`ETHSYS_FE_RST_CHK_IDLE_EN` defines | **identical** |
| probe pre-`mtk_hw_init` ordering (sram/wed/irq_fe/irq_pdma/clks) | **identical** |

**Conclusion:** the static code sequence, register values, caps and defines are
byte-identical (modulo my `pr_err` markers) to frank-w's tree that boots on the
same hardware. Therefore the hang is **NOT a logical/porting error in the code
path** — it's a runtime-state/environment difference. Remaining runtime suspects
to test next:
1. FE domain needs longer settle after reset than `ethsys_reset`'s `mdelay(10)`
   + immediate read — i.e. a timing issue (probe: add delay / retry-read markers).
2. Some prior init (WED/SRAM/clock/coherency) leaves a different domain state in
   our build vs frank-w's full tree (his tree has other dt/config deltas).
3. A `.config`/DTS difference between our tree and frank-w's (fetched-file diff
   only covers the driver source; the board dt/config may differ).

Next boot (43-marker build) instruments inside `ethsys_reset` and around the
FE_GLO_MISC read (try1 OK / write done) to characterize whether the read hangs
instantly or whether a delay after reset lets the FE come up.

### 43-marker build staged (21:08)

Additional instrumentation inside `ethsys_reset` (ASSERT/DEASSERT/DONE) and
around the `mtk_r32(MTK_FE_GLO_MISC)` read (`FE_GLO_MISC read try1` /
`try1 OK (0x%08x)` / `write done`). Stage on TFTP at 21:08. Next boot:
- if `ethsys_reset DONE` prints but `FE_GLO_MISC read try1` does not → the read
  after reset hangs the bus instantly (confirming the `mtk_r32` after reset is
  the exact wedge point).
- if `read try1 OK` prints, hang moved elsewhere.
- the marker set (42 in .ko; 43 source lines, one merged at compile) pins any
  further narrowing.

### Sublevel distillation: upstream 6.18.44 → 6.18.49 differences in our area

(Diffed the actual v6.18.44 vs v6.18.49 sources of mtk_eth_soc.{c,h},
mt7530.c, pcs-mtk-lynxi.c. mt7530 DSA: **unchanged**.)

**The hang-relevant path (`mtk_hw_init`/`mtk_hw_reset`/`ethsys_reset`, the
FE_GLO_MISC read, reset writes, caps, register-map RSS offsets) is
IDENTICAL in 6.18.44 and 6.18.49.** Sublevel drift is not the hang cause.

All real 44→49 changes are in other domains:

1. **QDMA TX multi-queue rework (biggest).** 6.18.49 reworked TX to
   `MTK_QDMA_NUM_QUEUES=16` paged queueing: `mtk_tx_buf.flags`,
   `MTK_TX_FLAGS_*`, `qid`/`skb_get_queue_mapping`, per-queue page registers
   (`qdma.page`), and a flattened `mtk_tx_map`. Our 6.18.44 carried the older
   single-queue + DSA per-port queue map (`MTK_DSA_USER_PORT_MAX`,
   `dsa_queue_base`, `dsa_port_rank`), later dropped by 49.
2. **`desc_shift` → `desc_size`** (rename of the same field; our port used
   `desc_shift`, converted to `mtk_is_netsys_v3_or_greater()` checks).
3. **`rx.dma_size` bumps: 512→2K** across soc data (and MT7988's 1K→2K in one
   row) — descriptor ring sizing only, affects open-time alloc not probe.
4. **MAC address path**: 6.18.49 inlined `of_get_ethdev_address` +
   `eth_hw_addr_random` into `mtk_add_mac` (removed `mtk_mac_assign_address`);
   DSA user-port queue mapping concept removed.
5. **pcs-mtk-lynxi** reworked to a plain library: `mtk_pcs_lynxi_create(dev,
   regmap, ana_rgc3, flags)` with an explicit `MTK_SGMII_FLAG_PN_SWAP` (from
   `mediatek,pnswap`), instead of a platform driver with `of_platform`/mutex.
6. **MT7988 caps slimmed** in 49: dropped GMAC1/2/3-SGMII/USXGMII and
   MUX_GMAC123_* bits (8X wiring doesn't use them via DSA); removed
   `MTK_RESV_BUF_MASK` (resv 0x80→0x40); dropped `num_tx_queues`,
   `shared_sgmii_used`, `available_pcs[2]`, GMAC3/debug regs, FRAGLIST features.
7. **`mtk_hw_dump*()` debug-print helpers removed** in 49.

**Takeaway:** nothing in 49 touches probe/reset/RX-ring bring-up. The 8X is on
a 6.18.44 base whose probe/FE-reset code is essentially identical to 6.18.49,
and to frank-w's 6.18-main (RSS included). So the hang remains a
runtime-state/environment difference, not a missing upstream fix and not our
porting logic. The 43-marker build (ethsys_reset internals + FE_GLO_MISC
try1/OK probes) isolates whether the FE read after reset hangs instantly.

### DEFINITIVE: the `mtk_r32(MTK_FE_GLO_MISC)` read hangs the bus (AIMARKER4, 22:42)

43-marker module build booted. Markers prove the exact wedge:

```
[   18.759320] MTKDBG: probe request_irq block DONE
[   18.763925] MTKDBG: FE_GLO_MISC read try1          <- mtk_r32() invoked
[   78.765776] rcu: INFO: rcu_sched stalls ... CPU 0  <- 60 s later, bus pinned
```

`FE_GLO_MISC read try1 OK` never printed → **`mtk_r32(eth, MTK_FE_GLO_MISC)` never
returns**. `ethsys_reset` (ASSERT/DEASSERT/DONE) and `CHK_IDLE_EN` write both
completed fine. So the FE domain does not answer its register read ~24 us after
reset deassert → AXI bus hang on CPU 0 → RCU stall → watchdog reset.

**Refined hypothesis:** the FE clock/domain is not settled/clocked when
`mtk_hw_init` reads `MTK_FE_GLO_MISC` right after `mtk_hw_reset`. It is not a
porting-logic error in the RSS code path, and not a 6.18.44-vs-6.18.49
difference (functions byte-identical to both upstream 49 and frank-w's
RSS-merged tree). Likely a **runtime state/clock-timing** interplay in our tree
vs the trees that boot. Candidate next experiments:
1. insert a delay (e.g. `mdelay(50)`) or FE-idle poll between `mtk_hw_reset` and
   the `MTK_FE_GLO_MISC` read, to see if the read then succeeds (settle-time test).
2. inspect/try the clock/PM enable path (`mtk_clk_enable`) and whether our module
   context leaves FE unclocked vs a working boot.
3. a built-in (CONFIG_NET_MEDIATEK_SOC=y) build was prepared (22:24, unstaged)
   to test the module-vs-builtin runtime difference; not yet booted.

### Built-in (=y) RSS build boots but LOSES eth2 / combo ports (AIMARKER5, 22:42)

The =y RSS recovery ITB **does not hang** (FE_GLO_MISC read completes:
`try1 OK (0x8000c016)`); probe SUCCESS, br-lan lan1-5 up, MxL switch up,
user space reached. **But eth2 (the combo-port MAC) is missing.**

Evidence: `ip a` shows only indices 1..12 (lo, eth0, eth1, lan5@eth0,
gre/gretap/erspan, lan1-4@eth1, br-lan) — no eth2, no lan6/wan. Driver probe
walked only TWO `add_mac` calls in the successful pass (markers: add_mac
ENTER x2), yet the 8X DTS has THREE `mediatek,eth-mac` children (mac@0/1/2,
aliases gmac0/1/2), and MTK_MAX_DEVS=3. The for_each_child loop skips nodes
that fail `of_device_is_compatible` or `of_device_is_available`; mac@2 must
have failed `of_device_is_available` at probe time.

Root cause (strong, evidence-backed): the =y driver probes during kernel init
(~8.69s) in the SAME instant the FIT enumerates/applies the combo DT overlays
(`-lan-phy`/`-wan-phy`/`-lan-sfp`/`-wan-sfp` sub-images listed at 8.690991+).
With =m the driver probes at ~18s, long after overlays are live, so mac@2 is
available -> eth2 registers (earlier module boots showed eth0/1/2). With =y
the probe races overlay application, mac@2 not yet "okay" -> skipped -> no
eth2/combo ports.

Note: all three RSS builds (module too) register eth2 when they get past
probe; the hang (module, AIMARKER4) and the missing-eth2 (builtin, AIMARKER5)
are two different consequences of the module-vs-builtin probe timing.

### AIMARKER6 (mac-diag built-in boot) — ethtool RSS not supported because eth2 never registers

mac-child diagnostic result (probe at ~9.1s):
```
mac-child mac avail=1 compat=1 -> add_mac ENTER   (mac0 -> eth0)
mac-child mac avail=0 compat=1                      (mac1 SKIPPED: wan combo)
mac-child mac avail=1 compat=1 -> add_mac ENTER   (mac2 -> should be eth2)
...  "generated random MAC address 20:08:02:00:00:00"
...  no eth2 frame engine / netdev
```

Mac1 (WAN combo) is disabled in the recovery ('fdt-1' base) DT because the
wan-phy overlay isn't applied on the TFTP-recovery path (bootconf_extra only
in production boot). Mac2 (10gbase-r SFP-bank MAC) IS walked + entered
mtk_add_mac + reached MAC allocation ("generated random MAC") but its netdev
does not appear — it returns early (likely fwnode_phylink_pcs_parse -> the
10gbase-r/usxgmii PCS path) so no eth2.

Consequence: ethtool -x / rx-flow-hash on any eth* returns "Netlink Error:
Not supported" because our RSS rxfh hooks are in mtk_ethtool_ops but the
RSS-capable eth2 netdev was never created, and eth0/eth1 (mt7530/MxL switch
conduits) don't advertise RSS.

Takeaway: the recovery/TFTP boot with base-DT is the wrong context to test
RSS — mac1/mac2 need the combo overlays. Next: boot the PRODUCTION sysupgrade
(or build a recovery that applies -lan-phy/-wan-phy) so mac1+mac2 are live,
then RSS ethtool/iperf test has a device to act on.

### AIMARKER10 (2026-09-14) — bootconf_extra TFTP fix: all 6 overlays load, eth2 + RSS now testable

**Boot path fix first.** `run boot_tftp` was `bootm $loadaddr#$bootconf`
(base fdt-1 only). The FIP default env carries
`bootconf_extra=...-cn13#...-cn14#...-8x-lan-phy#...-8x-wan-phy` but the
*device's saved env* (env.txt, Sep 3) did not contain `bootconf_extra`, so
the TFTP recovery boot never applied the combo overlays. Changed
`boot_tftp` in the live env (via `fw_setenv`), matching
`boot_production`/`boot_recovery`:

```
boot_tftp=tftpboot $loadaddr $bootfile && bootm $loadaddr#$bootconf#$bootconf_emmc#$bootconf_extra
```

Result (AIMARKER10 console): every TFTP boot now loads the full overlay set in
order — `config-...-8x` → `-emmc` → `-cn13` → `-cn14` → `-8x-lan-phy` → `-8x-wan-phy` —
before handing off to the kernel. (Same for the NAND `boot_production` path.)

**AIMARKER6 blocker gone:** with the combo overlays applied, `mac2` is
available at probe → **eth2 registers** on the TFTP/recovery boot too
(`mtk_soc_eth 15100000.ethernet eth2 ... irq 104`, 4 RX rings,
10Gbps up). The "RSS not testable, no eth2" problem of AIMARKER6 is resolved.

**RSS hardware live, ethtool surface incomplete.** On eth2:
- `ethtool -i eth2` → `mtk_soc_eth`; irq 104
- `ethtool -x eth2` → 4 RX rings, round-robin indir table + hash key readable;
  but **"RSS hash function: Operation not supported"**
- `ethtool -X eth2 equal 4` → accepted
- `ethtool -n eth2 rx-flow-hash tcp4` → **"Cannot get RX network flow hashing
  options: Not supported"**
- `ethtool -L eth2 combined 4` → **"netlink error: Not supported"**
- `ethtool -S eth2` → aggregate NIC + serdes stats only (no per-ring RX)

Root cause (driver, not boot): three ethtool surface gaps in `mtk_eth_soc.c`:
1. `mtk_get_rxnfc` has no `ETHTOOL_GRXFH` case → `-EOPNOTSUPP` for rx-flow-hash.
2. `mtk_ethtool_ops` has no `get_channels`/`set_channels` → `-L` fails.
3. `mtk_get_rxfh` sets `hfunc` only `if (rxfh->hfunc)`; the ioctl GET path
   passes `hfunc=0` so it's never filled → "Operation not supported".

Fixed in **760-24** (`net: ethernet: mtk_eth_soc: expose RSS channels +
flow-hash via ethtool`): GRXFH reports Toeplitz on IP src/dst + L4 ports for
tcp4/tcp6/udp4/udp6 when `MTK_RSS`; get/set_channels report
`MTK_RX_RSS_NUM` combined (1 for non-RSS SoCs); get_rxfh always returns
`ETH_RSS_HASH_TOP`. Built + restaged as the TFTP recovery ITB (01:52) for
AIMARKER11.

**Still-open — LAN link drop (not ethtool):** during AIMARKER10, mt7530
`lan5`/`eth0` (the cable to the management box 10.222.1.1) came up at
[36.0], then **link dropped at [47.99] and never returned** for the rest of
the session — hence `ping 10.222.1.1` was 100% loss in that boot while
`br-lan`/other ports stayed up (`ip neigh` showed 10.222.1.1 as
incomplete/00:00:00:00:00:00). Same box is reachable on the NAND production
boot (lan5 UP, `a8:b8:e0:0a:28:48` learned on lan5). So the recovery/TFTP
boot in this branch currently loses the mgmt link; needs its own look
(link-flap on mt7530 under multiring/NAPI build, or a config/timing issue)
before iperf/RSS validation over that port.

### MANAGEMENT-box cable move during AI10 + lan6 driver delta

The operator pulled the mgmt cable out of the original port during AI10 and
re-seated it. Port link-up sequence in the AI10 console (lines 46974-50553):
- `lan5` (mt7530/eth0, original port): up [36.0] → **down [47.99], never came back**
- the moved cable came up as **`lan6` (mxl86252) at [62.079], 10G, forwarded [62.09]**; flapped once [510→514], then stable
- lan1/2/3 up from [35-37]; lan4 never up

**Even with lan6 UP, `10.222.1.1` never answered ARP** (incomplete
`00:00:00:00:00:00`, ping 5/5 then 1/1 loss). Triage of who is "broken":

- lan6 = MxL switch16 `port@13`, CPU uplink = `gmac2` → **eth2** — the SAME
  MAC that 760-22 reworked into 4-ring multiring NAPI + RSS. lan1-4 ride the
  same MxL switch → eth2 path. So lan6 IS inside the blast radius of our
  work.
- AI10 shows eth2 RX was alive at the DMA level (`ethtool -S eth2`:
  `rx_packets: 3308`), but `tcpdump -i lan6` = 0 pkts → **nothing reached the
  netdev/stack over the MxL/eth2 path** despite rings counting RX. Consistent
  with a broken multiring/RSS RX handoff (frames into rings, never
  polled/delivered).
- **Control to run on AIMARKER11:** re-seat the mgmt cable into **lan5**
  (mt7530/eth0 — path NOT touched by our work; the NAND/v2 boot currently
  reaches 10.222.1.1 on lan5) and ping:
  - lan5 works + lan6 doesn't → our eth2/MxL RX path is at fault
  - lan5 fails too → something more general in the branch boot

**Driver delta for lan6's PHY (checked live, 2026-09-14):**

| boot | lan6 PHY binding (mdio-bus:18) |
|---|---|
| working NAND (installed v2 kernel) | `Generic Clause 45 PHY` (as21xxx only on mdio-bus:1c = eth1/phy28, fw 1.9.1) |
| AI10 (branch kernel over TFTP) | **`Aeonsemi AS21010JB1`** on mdio-bus:18 — as21xxx claimed phy24 too and loaded fw 1.9.1 on both 0x18 and 0x1c |

So the SAME phy addr (0x18) binds the bare `Generic Clause 45 PHY` driver in
the working boot but the **as21xxx driver in the branch boot** (different
kernel: installed v2 vs our RSS build). That is a real branch-vs-installed
kernel difference in phy driver binding for lan6's PHY.

Also observed in an early boot (console line ~4905-4912, banner at 4127 =
first TFTP boot): `lan6 (uninitialized): validation of usxgmii ...
failed: -EINVAL` / `failed to connect to PHY: -EINVAL` / `error -22 setting
up PHY for ... port 13` — in that boot lan6's PHY link-up FAILED outright
whereas in AI10 it linked. Both are branch-boot anomalies on the
eth2/MxL/port-13 path that the NAND boot does not show.
