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

## What to do next

1. Prove netconsole reception with a harmless marker before touching WED again.
2. Flash the improved image or commit the untracked attach-trace patch.
3. Reproduce the bind lock with netconsole armed.
4. Use the last `WED-AT` line to identify the exact non-returning access.
5. Resume the SER/quiesce A/B only after attach itself is observable or fixed.

## Do not repeat

- Do not enable WED at boot.
- Do not assume the watchdog will recover the bind fault.
- Do not hardcode `wl0` / `phy0`; the live SER path is under `wl1`.
