# Handoff — E8450/MT7622 WED bring-up (for next agent / Codex)

_Written 2026-07-03. Branch `e8450-hw-driven`, HEAD `1684fa50d1`. All work committed and pushed; tree clean._

## TL;DR
The only open thread is **the WED v1 SER breadcrumb harness**. It is **committed, pushed, and
the sysupgrade image is built** — but **NOT yet flashed to hardware or tested**. Pick up by
flashing and running the experimental protocol in `docs/WED-breadcrumb-harness-design.md`.

Everything else on this branch (PPPQ QoS, PPE hw-NAT, TCP-ACK via builtin conntrack, DSCP-qos
stack ppe-12+ppe-17, eth-07 napi fix) is DONE and HW-validated. See
`docs/E8450-MT7622-project-summary.md` (master reference) and `docs/PHASE3-patch-verdicts.md`.

## Hard constraints (unchanged)
- **No UART/serial console.** Diagnose only over SSH (root@192.168.1.1) or via data that
  survives a reboot (ramoops/pstore). `wed_enable` hard-faults the box; watchdog (mtk-wdt, 31s)
  force-reboots. Single rootfs — recovery is power-cycle only. Never arm WED at boot time.
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

## Immediate next steps
1. **Flash** `bin/targets/mediatek/mt7622/openwrt-mediatek-mt7622-linksys_e8450-ubi-squashfs-sysupgrade.itb`
   (mirror in `~/staging/latest-image/`) via `sysupgrade` over SSH.
2. Follow the **experimental protocol** in `docs/WED-breadcrumb-harness-design.md`:
   - Confirm `wed-breadcrumb@42fef000` reserved region is live and no-map.
   - Arm `wed_debug_breadcrumb=1`, attach WED manually (wed-toggle helper →
     `/sys/module/mt7915e/parameters/wed_enable` + PCI unbind/rebind), trigger SER, let it hang,
     power-cycle, read back last checkpoint from dmesg. → identifies the exact hanging MMIO.
   - Do **not** hardcode `phy0` / `wl0` for SER. Discover the live path with
     `find /sys/kernel/debug/ieee80211 -path '*/mt76/sys_recovery'`.
   - **A/B** with `wed_v1_txbm_quiesce=1` to test whether the TX-BM pause prevents the wedge.
3. Record findings; if the quiesce works, promote it out of debug-gating into a real fix patch.

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
