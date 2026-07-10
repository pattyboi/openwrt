# Cache line audit — MediaTek networking structs (MT7622 / E8450)

Date: 2026-07-10.  Methodology: net-next-6.8 networking struct
reorganization (Coco Li / Paolo Abeni) — group read-mostly fast-path
fields, isolate fast-path-written fields on their own cache lines,
push init/control fields to the tail.

Target: 2× Cortex-A53, 64 B cache lines, shared 256 KB L2, in-order
cores (no OoO to hide the ~. L2/coherency miss penalty).  Kernel
6.12.87, built `-Os` (`KERNEL_CC_OPTIMIZE_FOR_SIZE=y`).

## Status / deliverables

- **Patch 01 (ACTIVE)**: `target/linux/mediatek/patches-6.12/`
  `999-zzzzzz-cacheline-01-mtk_eth-hot-cold-split.patch` — struct
  mtk_eth hot/cold split + static_assert guards + hardware-format
  asserts in mtk_ppe.h.  Compile-verified, pahole-verified, built into
  the image pending flash.
- **Patch 02 (STAGED)**: `target/linux/mediatek/patches-staged/`
  `999-zzzzzz-cacheline-02-mtk_tx_ring-writer-split.patch` — struct
  mtk_tx_ring writer split.  Compile- and pahole-verified, then
  reverted from the tree.  For flash cycle 2, `mv` it into
  `patches-6.12/` and rebuild.  NOTE: it must live in a separate
  directory, not as `.patch.disabled` — `scripts/patch-kernel.sh`
  applies `${patchdir}/*` (every file, any suffix), so a "disabled"
  suffix does not disable anything.
- `configs/e8450-ubi.config`: added `CONFIG_KERNEL_PERF_EVENTS=y` and
  `CONFIG_PACKAGE_perf=y` — the previous kernel had **no perf support**,
  so the Phase-5 measurements below were impossible until now.
- NOT flashed.  One struct per flash cycle.

## Phase 1 — pahole layout survey

pahole works on the existing build (`DEBUG_INFO=y`); note
`DEBUG_INFO_REDUCED=y` makes foreign-CU embedded types (spinlock_t,
napi_struct, rhashtable, struct dim, xdp_rxq_info) display as size 0
with phantom "holes" — offsets and total sizes are still exact.
`mtk_wed_entry` does not exist in this kernel (15 of 16 requested
structs found).

| struct | size | lines | verdict |
|---|---|---|---|
| mtk_foe_entry | 128 | 2 | HW DMA format — do not touch. MT7622 uses 80 B (V1) entries in the HW table |
| mtk_foe_bridge / _ipv4 / _ipv6 | 52/72/88 | — | HW DMA formats — do not touch |
| mtk_ppe | 32992 | 516 | dominated by `foe_check_time[16384]`; single-CPU writer; low priority |
| mtk_eth | 3072 | 48 | **worst offender — fixed by patch 01** |
| mtk_mac | 152 | 3 | read-only in datapath (`ppe_idx`); fine |
| mtk_tx_dma / mtk_rx_dma | 16 | ¼ | HW descriptor formats — do not touch |
| mtk_tx_ring | 80 | 2 | **cross-CPU writer mix — fixed by patch 02** |
| mtk_rx_ring | 128 | 2 | single-CPU (RX NAPI) reader+writer; no coherency issue |
| mtk_wed_device | 9192 | 144 | read-mostly at runtime on WED v1; no change |
| mtk_wed_ring | 40 | 1 | read-mostly; no change |
| mtk_wed_buf | 16 | ¼ | fine |

Full pahole dumps: regenerate any time with
`pahole build_dir/.../linux-6.12.87/vmlinux -C <name>` (or on the
driver `.o` files for structs the reduced vmlinux DWARF misses, e.g.
`mtk_flow_entry`, `mtk_tx_buf`).

## Phase 2 — access patterns and false sharing

Function names in the original brief that do not exist in this tree:
`mtk_ppe_flow_add` (the write path is `mtk_foe_entry_commit` /
`__mtk_foe_entry_commit`), `mtk_wed_tx_poll` / `mtk_wed_rx_poll`
(WED v1 has no software poll path — the datapath is the hardware WDMA
plus mt76-side inline ops; `mtk_wed.c` is control/attach/reset only).
Analysis below covers the code that actually runs per packet.

### Concurrency topology (MT7622, no MTK_SHARED_INT)

- irq[1] → `tx_napi`, irq[2] → `rx_napi`: independently steerable, so
  TX completion and RX polling run concurrently on both A53 cores.
- `mtk_start_xmit` runs on whichever core the stack transmits from.
- PPE-offloaded flows bypass the CPU entirely (matters for Phase 5).

### struct mtk_eth (before patch 01)

- Cache line 0 held `base` (read on **every** register access),
  `dma_dev`, `netdev[0]` **and** three spinlocks: `page_lock` (taken
  per xmit), `tx_irq_lock`/`rx_irq_lock` (taken per interrupt
  mask/unmask, i.e. every NAPI cycle).  Every lock write invalidated
  the line holding the register base on the other core.  Classic
  false sharing.
- Cache line 38 (offset 2432) held `state` (test_bit(MTK_RESETTING)
  read per packet) and `soc` (read many times per packet: caps,
  reg_map, rx.dma_l4_valid…) next to `rx_events` (written in hard
  irq) and `rx_packets`/`rx_bytes` (written per RX poll).
- Cache line 40: tail of `rx_dim` (written by RX NAPI) shared with
  `tx_events/tx_packets/tx_bytes` (written by TX NAPI) — RX core and
  TX core write the same line.
- `rx_napi` head (its heavily-written `state` word) shared a line
  with the tail of `tx_napi`.

### struct mtk_tx_ring (before patch 02)

All 12 fields packed into line 0 (+16 B spill):

- xmit reads `dma`, `phys`, `dma_size`, `thresh` (const), reads+writes
  `next_free`, reads `last_free`, `atomic_sub`s `free_count`.
- TX completion (other core) writes `last_free`, `last_free_ptr`,
  `atomic_inc`s `free_count`, reads the const geometry fields.

Result: the const geometry, the xmit-owned pointer, and the
completion-owned pointers all bounce on one line, ~2 coherency misses
per packet on the in-order A53.  `last_free`/`free_count` are *true*
sharing (unavoidable); the fix is confining the bounce to one line.

### Hot paths with no actionable struct issue

- `mtk_poll_rx` / struct mtk_rx_ring: `calc_idx` is written per packet
  but only ever by the RX NAPI core that also reads the neighbouring
  const fields — same-core dirtying, no coherency traffic.  The ring
  array is already 64 B-aligned via `xdp_q`.
- `__mtk_ppe_check_skb` / struct mtk_ppe: `foe_check_time[16384]`
  (32 KB, written per unbound packet) is written and read only by the
  RX core.  It does share its first line with `mib_phys` (offset 64),
  but that field is only read on stats reads.  Not worth churn.
- struct mtk_flow_entry (216 B, 4 lines): the hlist walk in
  `__mtk_ppe_check_skb` touches the node (line 0) then `data`
  (lines 0–2); the existing local patch
  `999-zz-mtk_ppe-prefetch-flow-lookup.patch` already prefetches
  `entry->data`, which addresses the walk-latency issue better than a
  repack would.
- struct mtk_wed_device: config written at attach; per-packet WED v1
  work is done by hardware and by mt76 reading `wlan.*` constants.
  Read-mostly ⇒ shared (S-state) lines in both L1s, no invalidations.

### Hardware-format structs (constraint honoured)

`mtk_foe_entry` + substructs are the in-memory format the PPE walks
(`MTK_PPE_TB_BASE`); `mtk_tx_dma`/`mtk_rx_dma` are DMA descriptors.
Never reorder.  Patch 01 adds `static_assert`s pinning
`sizeof(struct mtk_foe_entry)` and the `ib2` offsets so an accidental
edit fails at compile time.  Note: MT7622 V1 entries are **80 B**, so
consecutive FOE entries straddle cache lines by hardware design —
nothing software can do.

## Phase 3 — reorganizations (before/after)

### Patch 01 — struct mtk_eth

Before (pahole, condensed):

```
0    dev, dma_dev, base, sram_base, page_lock(32), tx_irq_lock(36),
     rx_irq_lock(40), dummy_dev, netdev[0]          <= line 0
...
2432 state, soc(2440), dim_lock, rx_events, rx_packets, rx_bytes,
     rx_dim head                                    <= line 38
2560 rx_dim tail | tx_events(2584), tx_packets, tx_bytes  <= line 40
/* size: 3072, cachelines: 48 */
```

After:

```
0    dev, dma_dev, base, sram_base, dummy_dev, netdev[3], mac[3],
     soc, ppe[3], dsa_meta[7], prog, state, ip_align, hwlro,
     qos_toggle                       <= read-mostly, lines 0–3
256  page_lock        __aligned(64)   <= xmit-written line
320  tx_irq_lock, tx_events, tx_packets, tx_bytes, tx_dim
576  rx_irq_lock, rx_events, rx_packets, rx_bytes, rx_dim  (own lines)
704  tx_ring          __aligned(64)
1472 tx_napi          __aligned(64)
1920 rx_napi          __aligned(64)
2304 cold tail: irq[], regmaps, clks, pending_work, dim_lock,
     flow_table, reset
/* size: 3328, cachelines: 52 */
```

(rx group actually lands at 512 in the final object; exact dump in the
patch review below — regenerate with pahole -C mtk_eth on
mtk_eth_soc.o.)

### Patch 02 — struct mtk_tx_ring

Before: 80 B, everything on line 0 (+ spill).  After:

```
0    dma, buf, phys, dma_pdma, phys_pdma, dma_size, thresh  (const)
64   next_free                        <= xmit-written line
128  last_free, last_free_ptr, free_count, cpu_idx
     								  <= completion-written line
/* size: 192, cachelines: 3 */
```

`free_count` deliberately lives with `last_free`: xmit already reads
`last_free` every packet, so co-locating the shared atomic means xmit
touches exactly one shared-dirty line instead of two.

## Phase 4 — build-time guards (in the patches)

- `mtk_eth`: asserts that `page_lock`, `tx_irq_lock`, `rx_irq_lock`
  each start a cache line (`% SMP_CACHE_BYTES == 0`) and that the
  read-mostly group precedes the write groups.
- `mtk_tx_ring`: asserts `next_free` and `last_free` start their own
  cache lines.
- `mtk_ppe.h`: hardware-format asserts —
  `sizeof(struct mtk_foe_entry) == MTK_FOE_ENTRY_V3_SIZE(128)`,
  `offsetof(mtk_foe_ipv4.ib2) == 12`, `offsetof(mtk_foe_ipv6.ib2) ==
  52`, `offsetof(mtk_foe_bridge.ib2) == 16`.

## Phase 5 — measurement plan (for the flash tomorrow)

**Take the baseline BEFORE flashing** — but note the old kernel has no
perf support, so the baseline must be throughput/sirq-based:

1. Baseline on current kernel: router-terminated iperf3 (see below),
   record Mbps + `top` sirq%, 3× 30 s runs.
2. Flash patch-01 image (perf now included), repeat the same runs,
   **plus** perf counters:

```sh
# Pin the irqs apart so the cross-CPU story is deterministic:
grep -E 'ethernet' /proc/interrupts        # find tx/rx irq numbers
echo 1 > /proc/irq/<TX_IRQ>/smp_affinity   # CPU0
echo 2 > /proc/irq/<RX_IRQ>/smp_affinity   # CPU1

perf stat -a -e cache-misses,cache-references,\
L1-dcache-load-misses,L1-dcache-loads,l2d_cache_refill,l2d_cache \
sleep 10
```

3. Cache-to-cache traffic directly (Cortex-A53 events):
   `perf stat -a -e armv8_cortex_a53/l1d_cache_refill/,armv8_cortex_a53/l1d_cache/ sleep 10`.
   The dtb also exposes the **CCI-400 PMU** (`arm,cci-400-pmu,r1`) —
   snoop/coherency counters, ideal for seeing the false-sharing delta
   if the driver registers it.

**Traffic caveat**: PPE-offloaded WAN↔LAN flows never touch these
structs.  To exercise the reorganized code use one of:
- iperf3 server **on the router** (`opkg`/built-in) from a LAN host —
  slow-path rx/tx on both directions;
- temporarily `flow_offloading off` in firewall config;
- unbound-flow load: many short connections (first packets always take
  the CPU path through `mtk_ppe_check_skb`).

Success criterion: lower `l1d_cache_refill`-per-packet and/or higher
slow-path iperf3 Mbps at equal CPU.  If patch 01 verifies healthy,
enable patch 02 (`mv target/linux/mediatek/patches-staged/999-zzzzzz-
cacheline-02-*.patch target/linux/mediatek/patches-6.12/`), rebuild
(`make target/linux/clean && GOOGLE_CLANG=0 ./scripts/build-e8450.sh`),
flash cycle 2, re-measure.

## Ranked residual candidates (not implemented)

1. mtk_ppe: cacheline-align `foe_check_time` and pull `foe_flow` up
   next to `foe_table` — only if profiling shows check_skb hot.
2. mtk_flow_entry repack (`hash`/`type` next to `data`, kill 11 bytes
   of holes) — marginal; prefetch patch already covers the walk.
3. 64 B FOE entries: v1 hardware supposedly supports a 64 B table
   entry mode (MTK_PPE_TB_CFG entry-size field) which would make every
   entry exactly one cache line — needs hardware-doc confirmation
   before anyone tries it; IPv6 entry types do not fit in 64 B.
