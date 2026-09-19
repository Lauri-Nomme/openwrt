# 760-29 rework: dedicated RX-buffer-length worker — full reasoning & design

Date: 2026-09-19. Branch: `bpi-r4pro-8x-v2-multiring-napi`. Base: 6.18.44 + 760-21..29 + 979/980.
Status: **design complete, implementation NOT started (per user: no code yet).**

---

## 0. Problem statement

`mtk_eth_soc` sizes the RX ring buffers once, at first `ndo_open()`, from the then-current
`eth->rx_buf_len`. Changing MTU on a *running* interface updates `rx_buf_len` + PDMA SDL but
does NOT resize the already-allocated rings -> a jumbo frame larger than the old buffer
overruns in `mtk_poll_rx`'s `skb_put()` => `skb_over_panic`. (Observed at 9K on the 10G path.)

`760-29` = first fix; coarse (reuses full FE reset). This doc = analysis toward the design
frank-w landed on his `7.3-jumbo` branch (dedicated `rx_buf_len_work`), so it can be
implemented mechanically, matching OUR tree.

---

## 1. Evidence — verified facts (file:line in our build_dir / patches)

### 1.1 Current 760-29 `mtk_change_mtu()` (result of 760-27/28/29)
Sequence:
1. `length = new_mtu + MTK_RX_ETH_HLEN`
2. XDP gate: `eth->prog && length > MTK_PP_MAX_BUF_SIZE` -> EINVAL
3. **`mtk_set_mcr_max_rx(mac, length)` — writes MAC/XMAC max-rx using `new_mtu` EARLY**
4. `WRITE_ONCE(dev->mtu, new_mtu)`
5. `mtk_max_gmac_mtu()`; `mtk_ppe_update_mtu()` per ppe
6. `old_buf_len = eth->rx_buf_len`
7. size-bucket: <=1536->1536 ; <=2048->2048 ; <=9216->9216 ; else -EINVAL
8. SDL write (netsys_v3): `pdma.rx_cfg |= (MTK_PDMA_LRO_SDL + rx_buf_len)<<SDL_OFFSET`
9. if `old_buf_len != rx_buf_len && !MTK_RESETTING && any netdev running`
     `schedule_work(&eth->pending_work)`     <-- FULL FE reset worker

Problem with step 3: you let ONE MAC accept frames up to new_mtu BEFORE rings are resized;
on the async-window between change_mtu returning and pending_work running, a frame up to 9K
can arrive into rings still sized 1536/2048 => overrun. We never hit it in tests because we
always set MTU via uci + network restart (down/up), never `ip link set` on a live link.

### 1.2 Our tree lifecycle (verified)
- `mtk_open` (4051): phylink connect; `if !dma_refcnt`: start_dma->dma_init, ppe_start, gdm,
  napi_enable, irq enable, `refcount_set(&dma_refcnt,1)`; else `refcount_inc`. then phylink_start,
  `netif_tx_start_all_queues`, sets per-mac `max_mtu` (9K if MTK_NETSYS_RX_9K+xgmii else 2K).
- `mtk_stop` (4189): phylink_stop, netif_tx_disable, phylink_disconnect_phy; only if
  `refcount_dec_and_test`: gdm DROP_ALL, irq/napi disable (tx+rx0 [+RSS 1..]), cancel rx_dim/tx_dim,
  stop_dma qdma+pdma, `mtk_dma_free`, ppe_stop.
- `mtk_dma_init` (3609): busy_wait, fq_dma(qdma), tx_alloc, rx_alloc(0,QDMA), rx_alloc(0,NORMAL),
  **if hwlro**: hwlro rings + hwlro_rx_init, **if RSS**: rings 1.. + rss_init. **does NOT derive
  `eth->rx_buf_len`.**
- `mtk_dma_free` (3674): resets subqueues, frees scratch_ring, tx_clean, rx_clean(0),
  rx_clean(qdma), hwlro rings, rss, fq.
- `mtk_rx_alloc` (3022): rx_data_len = ETH_DATA_LEN (normal) / MTK_MAX_LRO_RX_LENGTH (hwlro);
  frag_size=buf_size from rx_buf_len via mtk_max_frag_size/mtk_max_buf_size; page_pool if
  mtk_page_pool_enabled(eth) [netif v2+], i.e. our 760-28 gate: returns false when any netdev
  mtu > MTK_PP_MAX_BUF_SIZE -> falls back to napi_alloc_frag/mtk_max_buf_alloc path (9K-capable).
- `mtk_hw_init(eth, reset)` (~4489): **never touches `eth->rx_buf_len`** (grep-verified).
  => pending_work preserves change_mtu's rx_buf_len; reopen re-allocs rings from it. So 760-29's
  resize IS functionally correct (rings do get reallocated at the new size).
- MTK_RESETTING quiesces both directions (verified):
  - start_xmit -> goto drop (2037); XDP TX -> -EBUSY (2244); poll_rx -> release_desc (2493);
    monitor (4664) + mac_config (744) guard their schedule with !MTK_RESETTING.
- HWLRO: our MT7988_CAPS has **no MTK_HWLRO**; `eth->hwlro` true only for mt7622/23/29.
  So HWLRO ring special-casing is N/A for us (keep guarded).

### 1.3 frank-w 7.3-jumbo design (fw73.c fetched from GitHub)
a) Central derivation — the core architectural change:
```
static u32 mtk_rx_buf_len(struct mtk_eth *eth) {
	int length = mtk_max_gmac_mtu(eth) + MTK_RX_ETH_HLEN;
	if (length <= MTK_MAX_RX_LENGTH) return MTK_MAX_RX_LENGTH;
	return DIV_ROUND_UP(length, MTK_MAX_RX_LENGTH_UNIT) * MTK_MAX_RX_LENGTH_UNIT;
}
// top of mtk_dma_init (fw73.c:3707):
/* Derived here, at ring allocation, so eth->rx_buf_len always describes the
 * buffers the rings actually hold and mtk_mac_config() never lets a MAC
 * accept a frame the rings cannot take. */
eth->rx_buf_len = mtk_rx_buf_len(eth);
```
MTK_MAX_RX_LENGTH_UNIT = 1024 (fw73.h:32) — GMAC jumbo length field granularity.
=> ONE writer of rx_buf_len: mtk_dma_init. change_mtu never writes it.

b) change_mtu becomes minimal (fw73.c:5064):
```
WRITE_ONCE(dev->mtu, new_mtu);
if (refcount_read(&eth->dma_refcnt) && mtk_rx_buf_len(eth) != eth->rx_buf_len)
	schedule_work(&eth->rx_buf_len_work);
return 0;
```
- NO mac max-rx write in change_mtu (all ordering handled in worker).
- NO SDL write in change_mtu (SDL programmed in ring-init path; see d).
- dma-running check = `refcount_read(&eth->dma_refcnt)` (not netif_running).

c) dedicated worker mtk_rx_buf_len_work (fw73.c:4981), exact order:
```
rtnl_lock();
if MTK_RESETTING: goto out;                 // reset owns rings; it re-derives on reopen
old_len = eth->rx_buf_len; new_len = mtk_rx_buf_len(eth);
if !refcount_read(&dma_refcnt) or new==old: goto out;
set_bit(MTK_RESETTING);
for running devs: netif_tx_disable(dev), __set_bit(i,&running);
dev_info("rx buffer length %u -> %u, reallocating the rx rings", old, new);
if (new_len < old_len)  mtk_set_max_rx_running(running, new_len);   // SHRINK: narrow MACs first
mtk_rings_stop(eth);      // light ring teardown
err = mtk_rings_start(eth);   // light re-init -> dma_init re-derives rx_buf_len, RX alloc new size
if (err) { dev_err; refcount_inc; dev_close(running devs); refcount_set(&dma_refcnt,0);
           clear(MTK_RESETTING); goto out; }
mtk_set_max_rx_running(running, eth->rx_buf_len);   // GROW: widen MACs after rings
clear_bit(MTK_RESETTING);
for running: netif_tx_wake_all_queues;
out: rtnl_unlock();
```
- mtk_set_max_rx_running(eth,running,len): calls set_mcr_max_rx(netdev_priv(netdev[i]),len) per running.
- WHERE does SDL get set in grow case? => In mtk_hwlro_rx_init (fw73.c:3210 netsys_v3 branch:
  `mtk_w32(... (MTK_PDMA_LRO_SDL + rx_buf_len)<<SDL_OFFSET, pdma.rx_cfg)`) which is called from
  dma_init ONLY when eth->hwlro. frank's MT7988_CAPS includes MTK_HWLRO, so his 7988 runs
  hwlro_rx_init every dma_init -> SDL always re-synced on each ring (re)alloc.
  OUR MT7988 has NO HWLRO -> that hook does not run -> we MUST set SDL in our own
  non-hwlro ring-init path (or in the worker) for bytes>1518 to be accepted after grow.
  (Our 760-28 currently sets SDL in change_mtu AND in mtk_hwlro_rx_init; the change_mtu SDL
  write covers alive-MTU-changing today.)

d) frank refactored programs: mtk_rings_stop() (fw73.c:4243) == the "last user" tail of our
   mtk_stop (gdm DROP_ALL, irq/napi disable incl RSS, cancel dim, stop_dma, dma_free, ppe_stop);
   mtk_rings_start() (fw73.c:4096) == the "first user" body of our mtk_open (start_dma/dma_init,
   ppe_start, gdm config, napi_enable, irq enable). netif_tx_disable/wake is done in the WORKER,
   not in rings_start/stop; phylink is NOT toggled by rings_start/stop (that's the point: no
   link flap). Our tree does NOT have these two functions — they would be introduced by the port.

e) Cancel in teardown: frank cancels rx_buf_len_work in mtk_free_dev (5244) + INIT_WORK in
   probe (6112).

---

## 2. Interrelationships & reasoning (the core analysis)

### 2.1 Why frank's "derive at ring-alloc" is the load-bearing invariant
When `change_mtu` writes `rx_buf_len` itself (our 760-29), there is a *brief* state where
`rx_buf_len` (rings size, at init) and the MAC/XMAC max-rx disagree. frank collapses this:
`rx_buf_len` is only ever the value that matches the rings that are actually in the DMA, and
`mtk_mac_config()`/`mtk_change_mtu` read that same value. So "MAC accepts more than the
rings hold" becomes impossible by construction.

### 2.2 The disable/stop/start ordering contract
The worker must guarantee: (i) no new TX into rings being freed, (ii) no NAPI/RX poll touching
freed buffers, (iii) no IRQ firing into semi-dead ring state. Evidence our tree satisfies
this under MTK_RESETTING (see 1.2): start_xmit drops, XDP -EBUSY, poll_rx release_desc,
and rings_stop disables IRQs before napi_disable before stop_dma before dma_free. This is
exactly the tail we already run on last-user *stop* today — proven at every link-down.
So the light worker is "guest-starring" the proven stop/open ring sequences under the same flag.

### 2.3 Shrink vs grow ordering (why it matters)
- SHRINK (e.g. 9216 -> 1536): narrow the MACs FIRST so no 8K frame can arrive while the
  new smaller rings are being installed; then stop/swap; then (nothing: MAC already narrow).
- GROW (e.g. 1536 -> 9216): install the bigger rings FIRST, then widen MACs; otherwise a
  frame up to old max is accepted (fine) but more importantly we never accept > ring size.
frank's `if (new_len < old_len) narrow;  rings_stop; rings_start; widen` is exactly this.

### 2.4 Why the worker, not a synchronous change_mtu
change_mtu runs under RTNL (net-core holds it for ndo_change_mtu). Stopping/starting links
synchronously inside it (mtk_stop/mtk_open) can deadlock/reenter phylink. frank defers with a
workqueue + rtnl_lock inside; change_mtu only schedules. This matches the existing
mtk_pending_work pattern (also scheduled). Consistent with the codebase.

### 2.5 Interaction with our 760-28 page_pool/jumbo gate
- page_pool_active depends on max MTU > MTK_PP_MAX_BUF_SIZE at allocation time.
- During a ring re-alloc, mtk_rx_alloc re-evaluates -> crossing 1500<->9000 flips
  page_pool<->frag path correctly on the NEW rings. 760-28 gate is per-alloc => no residue.

### 2.6 SDL (PDMA max frame) — the item we must NOT simply copy from frank
frank re-syncs SDL inside mtk_hwlro_rx_init (runs on 7988 ONLY because he added MTK_HWLRO).
We deliberately do NOT enable HWLRO (packet-ordering bug + order-0 page overrun, see notes).
=> blind-copying frank leaves SDL stale on grow: DMA would drop frames > old SDL even though
rings are 9K (or worse, accept > SDL into wrong-sized buffers). So the port MUST set SDL in a
place that runs on every ring (re)alloc WITHOUT relying on eth->hwlro — either in dma_init
(netsys_v3) or in the worker's grow path (set SDL from new rx_buf_len). This is the #1
"frank's shit may be buggy for us" trap.

### 2.7 HWLRO rings in rings_stop/start
frank's rings_stop/start handle hwlro NA/IRQ + hwlro ring count. We have eth->hwlro=false
for 7988. Keep those branches guarded by `if (eth->hwlro)` or omit — but keep the guard so the
port stays correct if hwlro is ever enabled. Must use our macro names (MTK_HW_LRO_RING etc.).

### 2.8 Macro/signature differences (we cannot copy verbatim)
- IRQ: ours `mtk_rx_irq_enable(eth, MTK_RX_DONE_INT(0))`; frank `MTK_RX_DONE_INT(eth, 0)`.
- RSS count: ours `MTK_RX_RSS_NUM` (eth->soc->rss_num); frank splits `MTK_RX_RSS_NUM(eth)`;
  ours uses `MTK_RX_DONE_INT(MTK_RSS_RING(i))`.
- HWLRO macros ours: `MTK_HW_LRO_RING_NUM` / `MTK_HW_LRO_RING(i)`; frank different names.
- UNIT granularity: ours has no MTK_MAX_RX_LENGTH_UNIT; frank=1024. "2K/9K bucket" ours
  (1536/2048/9216) already matches XMAC jumbo granularity for our caps; either fine but keep OURS
  to minimize diff (9216 == 9*1024, 2048 == 2*1024 are representable).

### 2.9 Existing 760-27/28 encroachment
760-27 already: dynamic rx_buf_len in change_mtu, mtk_set_mcr_max_rx, per-open max_mtu,
mtk_max_buf_alloc(size). 760-28 already: SDL write in hwlro init + change_mtu, page_pool gate.
The rework must REMOVE rx_buf_len/SDL/XMAC writes from change_mtu (frank-style) and move them
cleanly: rx_buf_len->dma_init, SDL->non-hwlro ring-init or worker, XMAC->worker grow/shrink.
Careful: keep `mtk_set_mcr_max_rx(mac, length)` behavior for the *requesting* mac consistent —
frank relies on derived len for all macs at ring-alloc.

---

## 3. Risks & mitigations (frank's code may be buggy for us)

R1 SDL stale on grow (2.6) — MUST set SDL without hwlro hook. Mitigation: set in dma_init
   (netsys_v3, non-hwlro) OR in worker after rings_start from eth->rx_buf_len.
R2 change_mtu no longer writes rx_buf_len — boot-time sizing relies on dma_init derivation.
   Verify probe path sets an initial value consistent with MTU (fw73 sets at probe too; and
   probe/change_mtu call order). Mitigation: port derives at dma_init; keep probe init.
R3 Worker races with mtk_pending_work (whole-FE reset). Mitigation: both take rtnl + set
   MTK_RESETTING; worker bails if already set; pending_work's reopen re-derives rings anyway,
   so a dropped buf_len change self-heals (2.1 invariant).
R4 netif_tx_disable before rings swap + wake_all_queues after; if we skip this, a TX could
   slip in under MTK_RESETTING? start_xmit drops on MTK_RESETTING, but wake/disable keeps
   queue state coherent across the swap. Keep frank's disable/wake for correctness.
R5 phylink untouched (rings_start/stop do NOT toggle phylink) — good: no link flap; but
   means max_mtu per-mac (set in mtk_open) is NOT recomputed; worker handles via
   set_max_rx_running(MAC hw regs, not netdev max_mtu). netdev->max_mtu stays from open.
R6 netif_running vs dma_refcnt: use refcount as the DMA-alive test exactly like frank.
R7 dim (dynamic interrupt moderation) work: rings_stop must cancel_work_sync rx_dim/tx_dim
   (frank does); else they may poke freed rings. Our mtk_stop already does this in tail — reuse.
R8 Memory/allocation failure in rings_start: frank closes devs with refcount dance. Port it.

---

## 4. Conclusions (firm)

C1 Current 760-29 (FE-reset reuse) is functionally OK but: (a) heavyweight (full FE/WED
   reset, pinctrl, 15ms sleep — overkill for a buffer resize), (b) has a real
   grow-window race (MAC widened in change_mtu before rings resized).
C2 frank's direction (derive-at-ring-alloc + dedicated light worker) is correct and fixes
   both; matches MTK's own runtime-realloc feed work (a7ee029fd/54f68b94df).
C3 We CANNOT copy frank verbatim. Differences: no mtk_rings_stop/start (must introduce by
   extracting our stop/open tails), no MTK_HWLRO on 7988 (SDL must be set non-hwlro), our IRQ/
   RSS/HWLRO macro names and signatures differ, no MTK_MAX_RX_LENGTH_UNIT.
C4 Use OUR 1536/2048/9216 bucket derivation in mtk_dma_init (they're valid units), don't add
   1024-unit unless needed.
C5 Net effect: rings size safety (no skb_over_panic on runtime MTU change), no link flap, no
   WED/FE reset on a mere buffer resize.

## 5. Implementation steps (mechanical, for later — NOT applied yet)

1. Add `mtk_rx_buf_len()` helper (our buckets) in mtk_eth_soc.c near mtk_max_gmac_mtu.
2. At top of `mtk_dma_init`: `eth->rx_buf_len = mtk_rx_buf_len(eth);` (keep probe init).
3. Extract `mtk_rings_stop()` + `mtk_rings_start()` from our mtk_stop/mtk_open bodies
   (exact same statements, our macro names, hwlro guarded) so open/stop call them.
4. Add `mtk_set_max_rx_running(eth, running_bitmap, len)` (loops running devs, set_mcr_max_rx).
5. Add `rx_buf_len_work` worker (`INIT_WORK` in probe, cancel in free) implementing 1.3c with
   OUR macro names; include SDL sync for netsys_v3 non-hwlro in grow (and shrink) path.
6. Rewrite `mtk_change_mtu`: drop rx_buf_len/XMAC/SDL writes; only set_mtu + ppe_update_mtu +
   schedule `rx_buf_len_work` when `refcount_read(&dma_refcnt) && mtk_rx_buf_len()!=rx_buf_len`.
7. Keep 760-28's page_pool gate; adjust its SDL-in-change_mtu (move/supersede by worker/dma_init).
8. compile-check (target/linux/compile), full `make target/linux/refresh` for quilt-canonical
   form, then CI push.

## 6. Verification plan (later)

- static: build clean; quilt refresh idempotent; CI patch-check green.
- runtime (banana, no reboot until asked): `ip link set lan6 mtu 9000` on a running 9000? no —
  start 1500 running, `ip link set mtu 9000` live, then 8K ping both ways + iperf; then back to
  1500 live; watch dmesg for skb_over_panic, ring realloc log line, MAC max-rx; no link flap
  observed (link counters unchanged), no WED reset in trace.
