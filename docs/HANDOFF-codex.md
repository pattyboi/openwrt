# Handoff — E8450 / MT7622 WED

Updated 2026-07-04 (evening) on branch `e8450-hw-driven`.

## 2026-07-04 PM — ROOT-CAUSE CLASS FOUND; UPSTREAM BUG CONFIRMED

Full verified trigger matrix (sound methodology: deadman + independent
wifi vantage + ramoops):

| operation                     | wed_enable | result |
|-------------------------------|-----------|--------|
| first bind (normal boot)      | N         | fine   |
| first bind (insmod)           | 1         | LOCKS  |
| PCI unbind/rebind             | N         | LOCKS  |
| PCI unbind/rebind             | Y         | LOCKS  |

Key findings, in order:

1. `wed_enable=N` PCI unbind/rebind hard-locks — WED-independent. The
   mt7915e rebind itself is fatal on MT7622 (PCIe MMIO against a
   resetting/stale card wedges the AXI fabric; watchdog and `reboot -f`
   both defeated).
2. First-bind with `wed_enable=1` (via `insmod` — NOTE: OpenWrt
   `modprobe` is kmodloader and SILENTLY IGNORES command-line params)
   also hard-locks, ~100ms into steady-state WED IRQ/ring servicing.
3. **A fast power-replug preserves ramoops** — DRAM survives a 1-2s
   outage. Two full WED-AT traces captured this way:
   `.recall/router-probes/2026-07-04-firstbind-wed-lock/`.
   Run 1 died at seq=754 `W WED0+0x204 (MTK_WED_INT_MASK)=0x2c018003`;
   run 2 at seq=643 `W 0x418 (MTK_WED_RX1_CTRL2)=0x10`. The death point
   WANDERS -> asynchronous killer: the mt7915 firmware bootstrap resets
   the card bus interface while WED holds outstanding transactions; the
   WED block wedges; the next WED register access hangs the AXI bus.
4. WMAC-awake (wl0 AP up) does NOT prevent it. ASPM already off
   (performance policy). Kernel-side runtime PM inactive.
5. **VANILLA locks too**: an image with ALL 999 patches removed
   (unpatched OpenWrt 25.12.4 / kernel 6.12.87) hard-locks identically
   on first-bind `wed_enable=1`. The patch stack is exonerated — this is
   an upstream/stock bug, on the very board WED v1 was developed on,
   strongly suggesting a kernel regression (E8450 users ran WED on
   5.15/6.1/6.6-era kernels).

Next avenues:
1. Establish the regression window: boot official OpenWrt 24.10 (k6.6)
   or 23.05 (k5.15) on the E8450 and run the same first-bind WED test.
2. Search upstream (lore, linux-mediatek) and OpenWrt git for mtk_wed /
   mt7622 WED fixes newer than 6.12.87 — candidates to backport.
3. The two ramoops traces are report-quality evidence for upstream.
4. The `wed_enable=N` rebind lock is a separate reportable bug
   (mediatek PCIe controller MMIO-vs-resetting-card AXI hang).

## 2026-07-04 REVERSALS — READ THIS FIRST, it supersedes much of the below

All results re-verified with self-reporting methodology (kmsg markers +
deadman `reboot -f` + ramoops readback + independent wifi vantage: ping the
router WAN at 192.168.3.15 from the house network). Never trust plain
reachability from the build laptop: its r8169 NIC logged continuous PCIe
RxErr bus errors on 2026-07-03 and its link flapping caused false "router
dead" verdicts.

1. The mtk_eth stop/open lock was a MISDIAGNOSIS. ~52 eth0 down/up cycles
   on 2026-07-04 never locked: all 17 stage-gated runs (stop 1-9, open 1-8),
   bare runs, runs under bound-PPE offloaded load, a 20-cycle hammer, a
   cold-boot replica, and runs with forced lan1 link flaps. mtk_stop /
   mtk_open / dev_close_many+dev_open are all fine.
2. The WED bind hard-lock IS REAL. A full ungated attach (`wed_enable=Y`,
   PCI unbind/rebind) hard-locked the SoC first try on a rebuilt image;
   deadman `reboot -f` was defeated; both vantage points dead. Bus-level.
3. The skip-gate result stands: `wed_attach_max_access=0` (every traced
   WED/WDMA/WPDMA/mirror/HIFSYS access skipped, attach force-failed) ALSO
   hard-locks. Re-verified 2026-07-04.

Combining 1+3: the locking ingredient is in what the (even fully-gated)
attach does that plain eth0 cycles do not:
- the PCI unbind/rebind of mt7915e itself (NOTE: "rebind with wed_enable=N
  is safe" was never verified with sound methodology — test it FIRST)
- `mtk_eth_set_dma_device(eth, hw->dev)`: unlike plain cycles, this CHANGES
  eth->dma_dev to the WED platform device before the reopen
- `mtk_wed_tx_buffer_alloc` (DMA allocs against the WED device)
- the detach-restore swap back to eth->dev

Next steps: (a) PCI unbind/rebind with `wed_enable=N` under the sound
methodology; if it locks, the fault is mt76 re-probe/PCIe, not WED at all.
(b) If it survives, add a `wed_attach_stop_stage` gate for the STRUCTURAL
attach steps (before/after set_dma_device, before tx_buffer_alloc, skip
detach-restore) and bisect. The eth stage harness patch (999-zzzzz) is
currently set aside in the session scratchpad but committed at 1db6653;
the flashed image is the A-replica (perf-opt, WED gate only, no debug).

## State

The breadcrumb harness is in-tree and flashed. The WED attach-MMIO theory is
dead: `wed_attach_max_access=0` still hard-locks the box, and a plain detached
`ip link set eth0 down; sleep 3; ip link set eth0 up` locks identically with
no WED/PCI/mt7915 involvement. A deadman run on the debug image also proved
`reboot -f` does not recover it, which strongly points at a bus-level lock or
deeper FE hang in the `mtk_eth` stop/open cycle.

The active probe patches are now:
- `target/linux/mediatek/patches-6.12/999-zzzz-wed-attach-netconsole-trace.patch`
- `target/linux/mediatek/patches-6.12/999-zzzzz-mtk_eth-stop-open-bisect.patch`

## Hardware facts verified live

- Router: Linksys E8450 (UBI), OpenWrt 25.12.4 `r32933-4ccb782af7`,
  kernel `6.12.87`
- MT7915E: PCI `0000:01:00.0`, driver `mt7915e`, `enable=1`
- WED devices:
  - `/sys/bus/platform/devices/1020a000.wed`
  - `/sys/bus/platform/devices/1020b000.wed`
- WED debugfs:
  - `/sys/kernel/debug/wed0`
  - `/sys/kernel/debug/wed1`
  - both reported `regidx=0`, `regval=0x76220001`
- Reserved memory:
  - `ramoops@42ff0000`
  - `wed-breadcrumb@42fef000`
- Params:
  - `/sys/module/mtk_eth/parameters/wed_debug_breadcrumb`
  - `/sys/module/mtk_eth/parameters/wed_v1_txbm_quiesce`
  - `/sys/module/mt7915e/parameters/wed_enable`
- SER trigger:
  - `/sys/kernel/debug/ieee80211/wl1/mt76/sys_recovery`
- `devmem` is absent; use `dmesg` / pstore for read-back

Raw probe logs: `.recall/router-probes/2026-07-03-breadcrumb-audit/`.

## Attach path learned from probing

The failing bind sequence begins before direct MT7915 BAR traffic:

1. WED0: clear WPDMA TX/RX driver bits
2. WED0: clear WDMA RX driver bit
3. WED0: clear WED TX/RX DMA bits
4. WDMA0: first DMA-state read-modify-write
5. PCIe mirror update
6. WED reset/init and WPDMA base programming
7. HIFSYS coherent-agent update

~~Current prime suspect: the first WED0 read-modify-write at offset `0x508`.~~

## DISPROVEN by the 2026-07-03 bisect run — MMIO is not the fault

With the skip gate armed (`wed_debug_breadcrumb=1`, `wed_attach_max_access=0`
— every traced WED/WDMA/WPDMA/PCIe-mirror/HIFSYS access skipped, attach
force-failed), the PCI rebind STILL hard-locked the box. Therefore the bind
fault is NOT in the traced attach MMIO, including the 0x508 RMW.

What still executed in that run:

1. `dma_set_mask_and_coherent` (no HW)
2. `mtk_eth_set_dma_device(eth, hw->dev)` — the mt7622 eth node is
   `dma-coherent`, so this runs and does `dev_close_many()` + `dev_open()`
   on ALL mtk netdevs (full eth0 close/reopen under RTNL, with PPE/PPPQ/
   flowtable state live)
3. `mtk_wed_tx_buffer_alloc` (DMA allocs only)
4. forced-fail -> `__mtk_wed_detach` -> `mtk_eth_set_dma_device(eth,
   eth->dev)` — a SECOND full close/reopen

New prime suspect: the mtk_eth netdev close/reopen cycle triggered by the
DMA-device swap (2 and 4), interacting with the offload state. This also
explains why the watchdog never fires (a kernel hang under RTNL keeps
interrupts alive) and why stock mainline faults too.

## Netconsole verdict (2026-07-03)

Netconsole is NOT usable on this image: modprobe succeeds on br-lan, lan1 and
eth0 targets, the console layer demonstrably works (all markers reach the
ramoops console and dmesg), but zero frames ever reach the wire. lan1's DSA
software TX stats never increment, so the drop is inside netpoll before
ndo_start_xmit. Source audit of write_msg/__netpoll_send_skb/find_skb and
kernel config (NETPOLL=y, NET_POLL_CONTROLLER=y, DSA hooks present) found no
explanation; black-box diagnosis is exhausted. Tracked as a beads bug.

## Replacement: attach-access bisect (wed_attach_max_access)

`999-zzzz-wed-attach-netconsole-trace.patch` now also gates the traced MMIO:
with `wed_debug_breadcrumb=1` and `wed_attach_max_access=N` (>= 0), traced
accesses with sequence number > N are skipped (reads return 0) and the attach
is forced to fail cleanly (mt76 falls back to non-WED). The WED-AT lines land
in dmesg and are read over SSH after each surviving run.

Protocol:
1. `wed_attach_max_access=0` run: every access skipped -> box survives,
   dmesg holds the complete ordered attach access list (offsets + values).
2. Raise N stepwise (or binary-search): each run executes the real access
   prefix 1..N. The first N that hard-locks names the faulting access.
   Only that final crossing costs a cold power-cycle.
3. Between surviving runs, unbind/rebind is enough; warm reboot if in doubt.

## Baseline result (2026-07-03, later same day): WED FULLY EXONERATED

The baseline ran: a detached `ip link set eth0 down; sleep 3; ip link set
eth0 up` (setsid; note plain `nohup &` is killed by dropbear on disconnect)
killed the box identically — no ARP, no recovery, no watchdog rescue, and
NO WED/PCI/mt7915 involvement at all.

Because the image has `PANIC_ON_OOPS=y`, `PANIC_TIMEOUT=1` and OpenWrt sets
`kernel.panic=3`, an oops would have auto-rebooted the box within seconds.
It did not come back, so this is NOT a crash: it is either a permanent
deadlock in the mtk_eth stop/open path (which keeps feeding the watchdog)
or a hardware bus lock.

The WED connection is now understood: `mtk_wed_attach` calls
`mtk_eth_set_dma_device` (the mt7622 eth node is `dma-coherent`), which does
`dev_close_many()` + `dev_open()` on eth0 — the same stop/open cycle — and
the detach path does it a second time.

## Current state at handoff (2026-07-03 evening EDT, all verified live)

- Router: UP on the debug + size-optimized image, freshly flashed and
  verified over SSH:
  - `wed_attach_max_access` / `wed_debug_breadcrumb` / `wed_v1_txbm_quiesce`
    present under `/sys/module/mtk_eth/parameters/`
  - `kernel.sysrq=1`, `/proc/sysrq-trigger` exists (MAGIC_SYSRQ works)
  - `hung_task_timeout_secs=120` (DETECT_HUNG_TASK active; the deadman
    script lowers it to 30)
  - image shrank 13.5M -> 11.9M with `CC_OPTIMIZE_FOR_SIZE`
- The three OpenWrt buildroot symbols live in `.config` (NOT committed —
  re-add if .config is regenerated): `CONFIG_KERNEL_MAGIC_SYSRQ=y`,
  `CONFIG_KERNEL_DETECT_HUNG_TASK=y`, `CONFIG_KERNEL_CC_OPTIMIZE_FOR_SIZE=y`.
  Note: setting `CONFIG_CC_OPTIMIZE_FOR_SIZE` in the target config-6.12 does
  NOT work — the `KERNEL_*` buildroot symbol overrides it (commit 9fb16f8).
- Deadman test script: `docs/e8450-eth0-deadman.sh`. It was run on the debug
  kernel and the router stayed unreachable well past the script's forced
  `reboot -f` window. That means the fault survives a warm reboot request and
  is not just a recoverable hung task.

## What to do next (start here)

1. Build and flash the new `mtk_eth` stage-bisect patch set.
2. On the router, arm:
   - `echo 1 > /sys/module/mtk_eth/parameters/eth_debug_breadcrumb`
   - `echo N > /sys/module/mtk_eth/parameters/eth_stop_max_stage`
   - `echo M > /sys/module/mtk_eth/parameters/eth_open_max_stage`
3. Run the bare reproducer first:
   - `setsid sh -c 'ip link set eth0 down; sleep 3; ip link set eth0 up' </dev/null >/dev/null 2>&1 &`
   - plain `nohup &` over dropbear is unreliable; use `setsid`
4. Start with conservative gates so the SoC survives, then raise them:
   - `eth_stop_max_stage=0` means no stop stages execute
   - `eth_open_max_stage=0` means no open stages execute
   - increase one side at a time until the first lock identifies the crossing
     stage
5. Use the `ETH-BI ...` and `ETH-DMA-SWAP ...` `pr_emerg` lines from `dmesg`
   after surviving runs to see whether the lock is in stop, open, or the
   caller around them.
6. After the crossing stage is known, reduce the patch to a finer-grained
   harness around that stage only. Resume the SER/quiesce A/B only after this
   stop/open fault is localized or fixed.

## Do not repeat

- Do not enable WED at boot.
- Do not assume the watchdog will recover the bind fault.
- Do not hardcode `wl0` / `phy0`; the live SER path is under `wl1`.
- Do not attempt netconsole capture again on this image; see verdict above.
