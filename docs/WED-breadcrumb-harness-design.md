# WED v1 Breadcrumb Harness

Target: Linksys E8450 / MT7622 + MT7915E, no UART, single UBI rootfs, watchdog
31 s.

Purpose: make WED failures observable and make the v1 TX-BM quiesce hypothesis
runtime-testable.

## Scope

- `999-zzz-wed-breadcrumb-harness.patch`
  - adds a small reserved-memory breadcrumb region at `wed-breadcrumb@42fef000`
  - writes phase/id/arg checkpoints immediately before risky WED MMIO
  - replays the last checkpoint to `dmesg` on the next boot
  - exposes runtime params under `/sys/module/mtk_eth/parameters/`:
    `wed_debug_breadcrumb`, `wed_v1_txbm_quiesce`
- `999-zzz-mt7622-ramoops-console-capture.patch`
  - expands ramoops use so the replay survives reboot in `console-ramoops-0`

The harness is inert unless WED is manually armed after SSH is up.

## Verified runtime facts (2026-07-03)

- Router: Linksys E8450 (UBI), OpenWrt 25.12.4 `r32933-4ccb782af7`,
  kernel `6.12.87`
- `pstore` is mounted and `/dev/pmsg0` exists
- Live reserved-memory nodes:
  - `ramoops@42ff0000`
  - `wed-breadcrumb@42fef000` with `no-map`
- Live params:
  - `/sys/module/mtk_eth/parameters/wed_debug_breadcrumb`
  - `/sys/module/mtk_eth/parameters/wed_v1_txbm_quiesce`
  - `/sys/module/mt7915e/parameters/wed_enable`
- Live WED debugfs:
  - `/sys/kernel/debug/wed0`
  - `/sys/kernel/debug/wed1`
- Live SER trigger:
  - `/sys/kernel/debug/ieee80211/wl1/mt76/sys_recovery`
  - do not hardcode `wl0` / `phy0`
- `devmem` is not installed on the image; rely on `dmesg` and
  `/sys/fs/pstore/console-ramoops-0`

Raw probes are under `.recall/router-probes/2026-07-03-breadcrumb-audit/`.

## Checkpoint map

Phases:
- `1`: stop
- `3`: reset DMA
- `4`: start
- `5`: FE reset

Important IDs:
- `10..12`: stop path and optional v1 TX-BM pause
- `30..37`: reset-DMA path, including the token FIFO drain loop
- `50..55`: FE reset / ethsys side

Interpretation:
- last `33` usually means the hang is inside the TX-BM token-FIFO read loop
- last `53` or `54` points at the FE/ethsys reset side
- no phase-3 progress after stop points back toward the MCU/SER wait side

## Current limitation

The initial `wed_enable=Y` PCI rebind fault hard-locks the SoC before the
watchdog resets it. Recovery requires a cold power-cycle, which clears both
ramoops and the breadcrumb region. That means the breadcrumb harness is still
useful for warm-reset/SER cases, but not for the current attach-time hard lock.

Netconsole was the original plan for that case, but it is broken on this
image: netpoll TX silently drops every frame before ndo_start_xmit (verified
2026-07-03; console layer itself works — markers reach ramoops/dmesg). See
the beads bug for the full diagnosis.

Instead, `999-zzzz-wed-attach-netconsole-trace.patch` now gates the traced
MMIO: with `wed_debug_breadcrumb=1` and `wed_attach_max_access=N`, traced
accesses beyond sequence N are skipped (reads return 0) and attach fails
cleanly. `N=0` enumerates the whole attach access list with the SoC
surviving (read dmesg over SSH); stepping N upward executes the real access
prefix until the first hard-locking access is identified — one cold
power-cycle total.

## Current attach trace result

The bind sequence reaches these blocks in order:

1. WED0: clear WPDMA TX/RX driver bits
2. WED0: clear WDMA RX driver bit
3. WED0: clear WED TX/RX DMA bits
4. WDMA0: first read-modify-write of DMA state
5. PCIe mirror: clear port-0 mirror
6. WED reset/init and MT7915 WPDMA base programming
7. HIFSYS: clear PCIe0 coherent-DMA-agent mapping

Current prime suspect: the first WED0 access at offset `0x508`.

## Minimal protocol

1. Prove capture first:
   - pstore mounted
   - dmesg readable over SSH (netconsole is broken; do not rely on it)
2. For SER testing:
   - set `wed_debug_breadcrumb=1`
   - set `wed_v1_txbm_quiesce=0` or `1`
   - trigger deterministic SER with `sys_recovery`
   - compare the last replayed checkpoint after reboot
3. For attach-time fault localization (bisect):
   - `echo 1 > /sys/module/mtk_eth/parameters/wed_debug_breadcrumb`
   - `echo N > /sys/module/mtk_eth/parameters/wed_attach_max_access`
   - `echo Y > /sys/module/mt7915e/parameters/wed_enable`, then PCI
     unbind/rebind of `0000:01:00.0`
   - surviving run: `dmesg | grep WED-AT` gives the executed/skipped list
   - locking run: the last executed seq (= N) names the faulting access
   - always reset `wed_attach_max_access=-1` and `wed_enable=N` afterwards

## Deliverables

- `999-zzz-wed-breadcrumb-harness.patch`: runtime-gated breadcrumb + quiesce DUT
- `999-zzz-mt7622-ramoops-console-capture.patch`: console/pmsg/ftrace capture
- `999-zzzz-wed-attach-netconsole-trace.patch`: attach-path MMIO trace +
  `wed_attach_max_access` skip gate (bind-fault bisect)
