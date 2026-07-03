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

Current prime suspect: the first WED0 read-modify-write at offset `0x508`.

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

## What to do next

1. Flash the bisect image, verify the params exist.
2. Enumeration run (max=0), capture the full WED-AT list.
3. Step N upward toward the suspected first WED0 RMW at `0x508`; coordinate
   with a human for the one required cold power-cycle.
4. Resume the SER/quiesce A/B only after attach is localized or fixed.

## Do not repeat

- Do not enable WED at boot.
- Do not assume the watchdog will recover the bind fault.
- Do not hardcode `wl0` / `phy0`; the live SER path is under `wl1`.
- Do not attempt netconsole capture again on this image; see verdict above.
