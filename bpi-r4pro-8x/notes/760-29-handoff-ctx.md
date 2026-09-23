========================================================================
HANDOFF CONTEXT — 760-29 rework (mtk_eth_soc runtime RX-buffer realloc)
========================================================================
Date: 2026-09-19. Purpose: give a fresh AI everything needed to pick up
mid-task and IMPLEMENT (code) the rework of patch 760-29 from a blank state.

========================================================================
0. WHAT THE TASK IS (one paragraph)
========================================================================
The MT7988 mtk_eth_soc driver sizes RX ring buffers ONCE at first ndo_open()
from eth->rx_buf_len. Changing MTU on a *running* interface (ip link set mtu)
updates rx_buf_len + PDMA SDL register but does NOT resize the already-allocated
rings -> a jumbo frame larger than the old buffer overruns in mtk_poll_rx's
skb_put() => kernel skb_over_panic (observed at 9K on the 10G path).
Patch 760-29 currently works around it by scheduling the HEAVY full-FE-reset
worker (mtk_pending_work) — works but heavyweight and has a grow-window race.
The rework replaces it with MTK/frank's design: a DEDICATED light worker
(rx_buf_len_work) that stops/restarts only the DMA rings under the MTK_RESETTING
flag, with correct shrink-before/grow-after MAC max-rx ordering, and rx_buf_len
derived at ring-alloc time (single source of truth). FULL DESIGN + evidence in
bpi-r4pro-8x/notes/760-29-rework-design.md (362 lines, sections 0-7).

========================================================================
1. HARD CONSTRAINTS (do not violate)
========================================================================
- Do NOT reboot, flash, or network-restart the banana or any box unless the user
  explicitly asks. Compile/iterate on source is fine.
- Do NOT run `find /` or broad recursive scans of the whole filesystem.
  Work inside /vokk/home/lauri/dev/openwrt-bpi-r4pro-8x/openwrt and /tmp.
- Remote boxes: banana=root@10.222.1.2 (OpenWrt), changwang=this machine (lauri),
  precision=lauri@precision (Debian, on MxL lan3). All at MTU 9000 persistent.
- The user's global rule: never comment on GitHub issues/PRs just to subscribe;
  only add real-value comments.
- Keep responses concise; user reacts badly to verbosity/preamble.

========================================================================
2. REPOSITORIES / BRANCHES / REMOTES
========================================================================
- Work repo: /vokk/home/lauri/dev/openwrt-bpi-r4pro-8x/openwrt
  active branch: bpi-r4pro-8x-v2-multiring-napi
  HEAD: d5902e1d7e (notes only; no rework code applied yet)
- origin = https://github.com/Lauri-Nomme/openwrt.git  (user's fork; push here)
- upstream = https://github.com/openwrt/openwrt.git (fetch-only)
- frankw = https://github.com/frank-w/openwrt.git (fetch-only)
- BPI-Router-Linux (frank's kernel repo, NOT cloned; use raw.githubusercontent)
- The pre-fork ledger of 760-21..980 patches lives in
  target/linux/mediatek/patches-6.18/ (these ARE the source of truth that
  survive clean rebuilds; build_dir is ephemeral).

========================================================================
3. THE PATCH SERIES (target/linux/mediatek/patches-6.18/)
========================================================================
Relevant files (all committed + quilt-refreshed canonical form):
- 760-27 net-ethernet-mtk_eth_soc-rx-buf-len-and-9k-jumbo-mtu.patch
  (dynamic rx_buf_len selection, mtk_set_mcr_max_rx XMAC support, per-open
   max_mtu 9K, mtk_max_buf_alloc explicit size, MTK_NETSYS_RX_9K cap added)
- 760-28 ...-program-pdma-sdl-max-rx-frame-and-disable-page_pool-for-jumbo.patch
  (SDL write in mtk_hwlro_rx_init AND mtk_change_mtu; page_pool disabled when
   any netdev mtu > MTK_PP_MAX_BUF_SIZE)
- 760-29 ...-reallocate-rx-rings-on-runtime-mtu-change.patch  [TO BE REWORKED]
  (current: change_mtu computes old_buf_len + sets rx_buf_len bucketed +
   writes SDL + schedules schedule_work(&eth->pending_work))
- 979/980: stable-MAC nvmem dts patch / napi dummy-device-before-registration

IMPORTANT lineage/insight: 760-27 came from frank-w jumbo series
(92bfdbdd4de1, b4c6cb1d5532, ca4c976dce22, a3207a383794). 760-28 SDL +
page_pool-gate + 760-29 were authored by us on this branch. MTK's actual
implementation (which frank LIFTED from) is:
  clone in /tmp/mtkfeed (github mediatek/mtk-openwrt-feeds, 25.12/patches-6.12):
  - 999-eth-31 ...-add-9k-jumbo-frame-support.patch
  - 999-eth-33 ...-add-dynamic-rx-buffer-adjustment-support.patch  (Mason Chang)
  - 999-eth-50 ...-add-netdev-restart-work.patch  (Mason Chang; = frank's worker ancestor)
  Read them in full. frank's 7.3-jumbo = MTK design + hardening.

========================================================================
4. KEY VERSIONS / TOOLCHAIN / BUILD FLOW
========================================================================
- Kernel base: linux 6.18.44 (build_dir/
  target-aarch64_cortex-a53_musl/linux-mediatek_filogic/linux-6.18.44)
- Driver is BUILT-IN (CONFIG_NET_MEDIATEK_SOC=y) — no .ko; object is
  drivers/net/ethernet/mediatek/mtk_eth_soc.o linked into kernel image.
- Compile-check (fast, no reboot): 
    cd build_dir/.../linux-6.18.44
    touch drivers/net/ethernet/mediatek/mtk_eth_soc.c
    make M=drivers/net/ethernet/mediatek      # runs cc + MODPOST; syntax proof
  NOTE: this does NOT fully compile built-in .o reliably; the authoritative
  build is `make target/linux/compile` (slower) or full `make`.
- Full kernel+image build:
    make target/linux/compile   (or `make -j$(nproc)` for whole image)
  Output itb: bin/targets/mediatek/filogic/openwrt-mediatek-filogic-bananapi_bpi-r4-pro-8x-squashfs-sysupgrade.itb
- Quilt canonical patch refresh (CRITICAL for CI green):
    make target/linux/refresh V=s
  This re-derives ALL patches in patches-6.18 from the applied tree. After
  editing build_dir source, run refresh; it rewrites patch files to canonical
  quilt form (removes diff --git/index lines, corrects hunk offsets). Then
  COMMIT the refreshed .patch files. Second refresh must be a no-op.
- CI: push to origin bpi-r4pro-8x-v2-multiring-napi triggers fork workflow
  "Build Kernel" (openwrt/openwrt reusable kernel CI). Watch:
    gh run list --repo Lauri-Nomme/openwrt --limit 6
    gh run view <id> --repo Lauri-Nomme/openwrt
  The "Check Kernel patches (mediatek, filogic)" job FAILED before the
  quilt-refresh (because hand-written patches had fuzz/offset); after refresh
  (commit 2984f27e04) that job PASSED (run 35439017755 all green).
========================================================================
EOF
echo "part1 written"; wc -l /tmp/ctx.md

========================================================================
5. DRIVER LIFECYCLE FACTS (verified against build_dir source; file:line)
========================================================================
All line numbers are in build_dir/.../linux-6.18.44/drivers/net/ethernet/mediatek/
mtk_eth_soc.c (the POST-all-patches applied tree; re-verify if changed).

- mtk_open (4051): phylink_of_phy_connect; if !refcount_read(&dma_refcnt):
    mtk_start_dma->mtk_dma_init (allocates rings), mtk_ppe_start, gdm config loop
    (gdma_to_ppe per mac), ppe_update_mtu, napi_enable(tx, rx0), irq enable, then
    RSS 1.. napi_enable+irq_enable, refcount_set(1). else refcount_inc. Then
    phylink_start, netif_tx_start_all_queues, per-mac max_mtu 9k/2k.
- mtk_stop (4189): phylink_stop, netif_tx_disable, phylink_disconnect_phy;
    only if refcount_dec_and_test (last user): gdm DROP_ALL, irq+napi_disable
    (tx, rx0, +RSS), cancel_work_sync(rx_dim, tx_dim), stop_dma(qdma,pdma),
    mtk_dma_free, ppe_stop.
- mtk_dma_init (3609): mtk_dma_busy_wait; [QDMA] fq_dma, tx_alloc, rx_alloc(0,QDMA),
    rx_alloc(0,NORMAL); [hwlro=true] hwlro rings+mtk_hwlro_rx_init; [RSS] rings
    1.. + rss_init; [QDMA] fc_th. DOES NOT derive eth->rx_buf_len (frank added that).
- mtk_dma_free (3674): resets subqueues, free scratch_ring, tx_clean, rx_clean(0),
    rx_clean(qdma), hwlro rings, rss, free fq.
- mtk_rx_alloc (3022): rx_data_len = ETH_DATA_LEN (normal) / MTK_MAX_LRO_RX_LENGTH
    (hwlro); ring->frag_size = mtk_max_frag_size(eth, rx_data_len);
    ring->buf_size = mtk_max_buf_size(eth, frag_size); kcalloc(rx_dma_size);
    page_pool if mtk_page_pool_enabled(eth); else napi_alloc_frag/mtk_max_buf_alloc.
- mtk_hw_init(eth, reset) (~4489): does NOT touch eth->rx_buf_len. => full
  pending_work reset preserves rx_buf_len written by change_mtu (that's why
  current 760-29 "works" for the resize itself).
- MTK_RESETTING state-bit quiescing (already present, verified):
  start_xmit -> goto drop (2037); XDP path -> -EBUSY (2244); mtk_poll_rx ->
  release_desc (2493); reset monitor (4664) + mtk_mac_config (744-745) guard
  their schedule_work with !test_bit(MTK_RESETTING). mtk_pending_work (5021)
  sets it, does FE/WED reset, re-opens; clears at end.
- IRQ helper signature in OUR tree: mtk_rx_irq_disable(eth, MTK_RX_DONE_INT(0));
  RSS loop uses MTK_RX_RSS_NUM (eth->soc->rss_num) and MTK_RSS_RING(i);
  HWLRO macros ours: MTK_HW_LRO_RING_NUM / MTK_HW_LRO_RING(i) (guarded by eth->hwlro).
- MT7988_CAPS has NO MTK_HWLRO (mtk_eth_soc.h:1270) => eth->hwlro=false on 7988.
- MTK_MAX_RX_LENGTH=1536, _2K=2048, _9K=9216. MTK_PP_MAX_BUF_SIZE=PAGE_SIZE-MTK_PP_PAD.
  Our tree has no MTK_MAX_RX_LENGTH_UNIT (frank/MTK=1024). Our buckets already
  coincide with MTK formula on 1500/2000/9000.
- mtk_set_mcr_max_rx(mac, val): non-xgmii -> MAC_MCR encoder (ours caps at 2048;
  MTK adds MAC_MCR_MAX_RX_JUMBO(DIV_ROUND_UP(val,1024)) for 2.5G ports — optional);
  xgmii+netsys_v3+mac.id!=GMAC1 -> XMAC_RX_CFG2 with val up to 9K.
- page_pool gate (our 760-28): mtk_page_pool_enabled(eth) returns false when any
  eth->netdev[i]->mtu > MTK_PP_MAX_BUF_SIZE => jumbo rings use frag alloc path.

========================================================================
6. TARGET DESIGN (from design doc §5) — implement this
========================================================================
1. Add helper `static u32 mtk_rx_buf_len(struct mtk_eth *eth)` near
   mtk_max_gmac_mtu: length = mtk_max_gmac_mtu(eth)+MTK_RX_ETH_HLEN;
   if <=1536 return 1536; else DIV_ROUND_UP(len,1024)*1024 (==our buckets here).
   (If we keep 760-27 bucket style, make sure it returns SAME sizes: 2048/9216.)
2. At TOP of mtk_dma_init, after busy_wait: eth->rx_buf_len = mtk_rx_buf_len(eth);
   (the real "derive at ring-alloc" invariant; keep probe init ~6217 too).
3. Extract mtk_rings_stop() and mtk_rings_start() from mtk_stop/mtk_open bodies
   (exact same statements, OUR macro names, hwlro guarded) — rings only, NO
   phylink, NO netif_tx_*, NO refcount (refcount stays in stop/open).
   Then mtk_stop/mtk_open call them (like frank/Mtk swap so open/stop unchanged).
4. Add `static void mtk_set_max_rx_running(struct mtk_eth*, unsigned long running,
   u32 buf_len)`: for_each_set_bit(i,&running,MTK_MAX_DEVS)
   mtk_set_mcr_max_rx(netdev_priv(eth->netdev[i]), buf_len).
5. Add dedicated worker `mtk_rx_buf_len_work(struct work_struct*)`:
     rtnl_lock();
     if (test_bit(MTK_RESETTING,&eth->state)) goto out;
     old_len=eth->rx_buf_len; new_len=mtk_rx_buf_len(eth);
     if (!refcount_read(&eth->dma_refcnt) || new_len==old_len) goto out;
     set_bit(MTK_RESETTING,&eth->state);
     for running devs: netif_tx_disable(dev); __set_bit(i,&running);
     if (new_len < old_len) mtk_set_max_rx_running(running, new_len);   // SHRINK first
     mtk_rings_stop(eth);
     err = mtk_rings_start(eth);
     if (err) { dev_err; refcount_inc; for running: dev_close; 
       refcount_set(&dma_refcnt,0); clear_bit(MTK_RESETTING); goto out; }
     // GROW: rings are now right-sized; set SDL (netsys_v3, non-hwlro) from
     //   eth->rx_buf_len, then widen MACs:
     if (mtk_is_netsys_v3_or_greater(eth)) { write pdma.rx_cfg SDL bits with
       MTK_PDMA_LRO_SDL + eth->rx_buf_len };
     mtk_set_max_rx_running(eth, running, eth->rx_buf_len);
     clear_bit(MTK_RESETTING);
     for running: netif_tx_wake_all_queues;
     out: rtnl_unlock();
6. Rewrite mtk_change_mtu: DROP the early mtk_set_mcr_max_rx(mac,length), DROP the
   rx_buf_len selection, DROP SDL write there (moves to dma_init/worker); keep
   WRITE_ONCE(dev->mtu,new_mtu), mtk_max_gmac_mtu, ppe_update_mtu, XDP gate;
   then if (refcount_read(&dma_refcnt) && mtk_rx_buf_len(eth)!=eth->rx_buf_len)
     schedule_work(&eth->rx_buf_len_work); return 0.
   (Matches MTK 999-eth-33/50 and frank 7.3.)
7. Add field `struct work_struct rx_buf_len_work;` to struct mtk_eth in
   mtk_eth_soc.h; INIT_WORK(&eth->rx_buf_len_work, mtk_rx_buf_len_work) in
   mtk_probe; cancel_work_sync(&eth->rx_buf_len_work) in mtk_free_dev cleanup.
8. Keep 760-28 page_pool gate. Its SDL-write in mtk_change_mtu is superseded
   (removed in step 6); its SDL-write in mtk_hwlro_rx_init stays (harmless,
   only runs if hwlro). Ensure SDL gets set on our no-hwlro 7988 via dma_init
   or worker grow path (DO NOT forget — this is the #1 trap).

========================================================================
7. MAINTAINERSHIP / PATCH FORMAT NOTES
========================================================================
- Edits land in build_dir/.../mtk_eth_soc.c + mtk_eth_soc.h, then quilt refresh
  rewrites the .patch files in target/linux/mediatek/patches-6.18/.
  Which patch file absorbs the new hunks depends on which patch is "active"
  during refresh. For a NEW standalone change create a NEW patch file
  760-30-...patch (or rewrite 760-29 wholesale). Historically we appended as
  760-2X then refreshed. For this rework, REPLACE 760-29's content (it IS the
  runtime-realloc patch) OR add 760-30 that supersedes. Simplest: modify 760-29
  to implement the final coherent design; commit that + refresh all.
- Patch header format (quilt-canonical after refresh): starts with
  "From 0000... Mon Sep 17 00:00:00 2001" plus Subject/body/Signed-off-by, then
  the diff WITHOUT "diff --git"/index lines. Verify with: second refresh no-op.

========================================================================
8. TEST / VERIFY PATH (when user says go)
========================================================================
- After compile + refresh + CI green:
  flash sysupgrade.itb to banana keeping config (NO -n):
    cat bin/targets/mediatek/filogic/openwrt-...-squashfs-sysupgrade.itb |
      ssh root@10.222.1.2 'cat > /tmp/img.itb; md5sum /tmp/img.itb'
    (verify md5 matches local), then:
    ssh root@10.222.1.2 'sysupgrade /tmp/img.itb'  (NOT -n)
    (First CLEAR pstore: rm /sys/fs/pstore/* or next boot auto-boots recovery.)
- Runtime validation (no panic, dmesg shows "rx buffer length X -> Y"):
    ssh root@10.222.1.2 'ip link set dev lan6 mtu 9000'  (live, running)
    8K ping both ways, iperf3 vs 10.222.1.22; then 'ip link set dev lan6 mtu 1500';
    check `dmesg | grep -i "rx buffer length"`, `dmesg | grep -ic skb_over_panic`.
- All boxes MTU 9000 currently (banana uci, changwang /etc/network/interfaces
  mtu 9000, precision NetworkManager bridge-br0 9000). Backup restore config:
  /vokk/home/lauri/dev/openwrt-bpi-r4pro-8x/config/v1-restore/ (network has all
  lan ports + eth2 at 9000; dhcp has dnsmasq enable=0).

========================================================================
9. LIVE ENVIRONMENT STATE (as of handoff)
========================================================================
- banana: root@10.222.1.2, running production r18x, MTU 9000 on lan1-6/eth2/br-lan,
  dnsmasq+odhcpd DISABLED (banana serves NO DHCP/DNS now), wan=eth1.
- changwang: this working machine; TFTP/NFS/DHCP server for odroid PXE;
  odroid now boots (DHCP fixed addr .40, NFS root /data/odroid).
- precision: lauri@precision, NetworkManager br0, MTU 9000.
- No box is currently flashed with the rework (760-29 as committed is the
  pending_work version, CI-green).
