# Handoff — E8450 / MT7622 WED

Updated 2026-07-03 on branch `e8450-hw-driven`.

## State

The breadcrumb harness is in-tree and flashed. The current blocker is earlier:
`wed_enable=Y` plus PCI unbind/rebind hard-locks the SoC during bind. The
watchdog does not recover it. Cold power-cycle is required and clears DRAM
breadcrumbs and ramoops.

The follow-up attach tracer exists as an untracked patch:
`target/linux/mediatek/patches-6.12/999-zzzz-wed-attach-netconsole-trace.patch`.
Do not rely on the DRAM breadcrumb alone for this bind-time fault.

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

## Current state at handoff (2026-07-03 ~19:25 EDT, all verified live)

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
- Deadman test script: `docs/e8450-eth0-deadman.sh`. NOT yet run on the
  debug kernel — this is the very next action.

## What to do next (start here)

1. Deploy `docs/e8450-eth0-deadman.sh` to `/tmp/t2.sh` on the router; run
   `setsid /tmp/t2.sh </dev/null >/dev/null 2>&1 &`, disconnect, wait ~4 min.
   (Plain `nohup &` over ssh dies with dropbear — must be setsid.)
2. If the box comes back by itself (deadman `reboot -f` = warm reset,
   ramoops preserved), read `/sys/fs/pstore/console-ramoops-0`: khungtaskd
   will have dumped the stuck task's kernel stack — that is the root-cause
   stack. Also try `echo t > /proc/sysrq-trigger` before any reboot in live
   sessions now that sysrq works.
3. If the box stays dead even for `reboot -f`, the hang is bus-level, not a
   kernel deadlock — also decisive (then user must power-cycle again).
4. With the stack in hand, likely suspects: mtk_stop/mtk_open interaction
   with the PPE/PPPQ/flowtable offload patch stack. A/B candidates: remove
   the nft flowtable / disable offloads and retry; or test a stock image
   eth0 down/up to see if vanilla locks as well.
5. Resume the SER/quiesce A/B only after this is localized/fixed.

## Do not repeat

- Do not enable WED at boot.
- Do not assume the watchdog will recover the bind fault.
- Do not hardcode `wl0` / `phy0`; the live SER path is under `wl1`.
- Do not attempt netconsole capture again on this image; see verdict above.
