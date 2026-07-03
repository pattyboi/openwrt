# Handoff — E8450/MT7622 WED bring-up (for next agent / Codex)

_Updated 2026-07-03. Branch `e8450-hw-driven`._

## TL;DR
The WED attach fault is now reproduced: with `wed_enable=Y`, PCI unbind
completes and rebind hard-locks the SoC. The watchdog does not recover it, and
the required cold power-cycle erases all DRAM breadcrumbs. The original SER
harness is flashed, but the new attach/netconsole tracer is built and **not yet
flashed**. Resume only after netconsole smoke-test reception works.

Everything else on this branch (PPPQ QoS, PPE hw-NAT, TCP-ACK via builtin conntrack, DSCP-qos
stack ppe-12+ppe-17, eth-07 napi fix) is DONE and HW-validated. See
`docs/E8450-MT7622-project-summary.md` (master reference) and `docs/PHASE3-patch-verdicts.md`.

## Hard constraints (unchanged)
- **No UART/serial console.** Diagnose over SSH (root@192.168.1.1) or live
  netconsole. `wed_enable` hard-faults the box and the 31-second MTK watchdog
  does not recover it. Cold power-cycle is required and erases ramoops and the
  raw DRAM breadcrumb. Never arm WED at boot time.
- SoC: MT7622, **WED v1**. Wi-Fi: MT7915E (Wi-Fi 6, PCIe 0000:01:00.0).

## What the harness does (commit 1684fa50d1)
`target/linux/mediatek/patches-6.12/999-zzz-wed-breadcrumb-harness.patch`:
- Instruments the WED v1 SER teardown path (`mtk_wed_stop` / `reset_dma` / `dma_enable` /
  `fe_reset`) with checkpoints written to a dedicated no-map DRAM region
  **`wed-breadcrumb@42fef000`** immediately before each candidate MMIO. The ioremap (Device
  memory) store reaches DRAM before the next possibly-hanging access, so the **last checkpoint
  survives the watchdog reset** and is read back to dmesg on the next boot → localizes the hang.
- **DUT candidate fix** `wed_v1_txbm_quiesce`: asserts `MTK_WED_TX_BM_CTRL_PAUSE` in
  `mtk_wed_stop()` on v1 to freeze the TX buffer-manager token state before the WLAN MCU runs
  SER reconcile — hypothesised fix for the MCU wedge (ref mt76 issue #754).
- Both behind runtime module params under `/sys/module/mtk_eth/parameters/`
  (`wed_debug_breadcrumb`, `wed_v1_txbm_quiesce`) — nothing runs unless explicitly armed AND
  WED is attached manually post-SSH. Deterministic SER is triggered via the existing mt76
  `sys_recovery` debugfs knob (no custom trigger patch).
- Live router verification on **2026-07-03** confirmed: `wed-breadcrumb@42fef000` exists in
  reserved-memory, params are really under `/sys/module/mtk_eth/parameters/`, and the current
  mt76 SER trigger path is `/sys/kernel/debug/ieee80211/wl1/mt76/sys_recovery`. Raw probe logs:
  `.recall/router-probes/2026-07-03-breadcrumb-audit/`.

## Current hardware/syscon profile

- MT7915E is PCI `0000:01:00.0`, Gen2 x1, 32-bit DMA, BAR0 at
  `0x20000000..0x200fffff`. PCIe port 0, HIF0, and ETHSYS remain powered.
- WED0/WED1 are syscons at `0x1020a000`/`0x1020b000`; WDMA0 is
  `0x1b102800`; PCIe mirror is `0x10000400`; HIFSYS is `0x1af00000`.
- Initial WED attach touches WED and WDMA before directly touching the MT7915
  BAR. The first suspect is WED0 offset `0x508`.
- `999-zzzz-wed-attach-netconsole-trace.patch` now traces `wed_m32`, WDMA,
  WPDMA, mirror, and HIFSYS accesses with a common sequence number.

## Immediate next steps

1. Prove netconsole reception with a harmless `/dev/kmsg` marker. Router TX
   counters advance, but the build host listener has not received it yet.
2. Flash the improved image only after capture works:
   `b03d574d8e91de1a9a10086899fd841a7fe929543283013577f873db720b1eee`.
3. Arm `wed_debug_breadcrumb=1`, enable netconsole, then perform the known
   `wed_enable=Y` PCI unbind/rebind reproduction. The last `WED-AT` packet
   identifies the non-returning syscon/MMIO operation.
4. Only after attach succeeds should the SER/quiesce A/B protocol resume.

## Build/config rules (from CLAUDE.md — enforce)
- Never edit `.config` directly: `./scripts/config --enable/--disable`; then `make olddefconfig`.
- `make kernel_menuconfig` for kernel-only config; `make -j$(nproc)`.
- Patches in `target/linux/mediatek/patches-6.12/` are diffs vs vanilla; patched source only
  materializes in `build_dir/target-aarch64_*/linux-mediatek_mt7622-*/linux-6.12.*/` after build.

## Do-not-repeat (settled)
- PPE hot-path opts from CLAUDE.md (DSA cache / eligibility / IPv4-only) are **moot on mainline**
  — already O(1), setup-time not hot-path, IPV6=y. Don't re-attempt.
- DSCP-qos class is effectively **done** at ppe-12+ppe-17 (flashed, live). ppe-23 is dead on
  netsysv1; ppe-27 needs ppe-26 extracted first. Skip unless VLAN-PCP egress QoS is a real need.
