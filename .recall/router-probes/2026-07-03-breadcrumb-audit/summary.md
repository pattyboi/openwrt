2026-07-03 breadcrumb harness audit probe summary

- Host wired interface already had `192.168.1.10/24` on `enp1s0`; router reachable at `192.168.1.1`.
- Router identity: Linksys E8450 (UBI), OpenWrt 25.12.4 `r32933-4ccb782af7`, kernel `6.12.87`.
- `pstore` is mounted and `console-ramoops-0` exists.
- DT reserved-memory nodes verified live:
  - `ramoops@42ff0000`
  - `wed-breadcrumb@42fef000` with `no-map`
- Runtime params are exposed under `/sys/module/mtk_eth/parameters/`:
  - `wed_debug_breadcrumb=N`
  - `wed_v1_txbm_quiesce=N`
- `mt7915e` exposes `wed_enable` under `/sys/module/mt7915e/parameters/wed_enable`.
- Debugfs WED nodes exist: `/sys/kernel/debug/wed0`, `/sys/kernel/debug/wed1`.
- The live mt76 SER trigger path is `/sys/kernel/debug/ieee80211/wl1/mt76/sys_recovery`.
- `wl0` does not expose `sys_recovery` on this image; do not hardcode `wl0` / `phy0`.
- `/dev/pmsg0` exists.
- `devmem` is not installed on the current image, so breadcrumb readback should rely on
  `dmesg` / `console-ramoops-0` unless a separate reader is added.
- WED platform devices are present and bound:
  - `/sys/bus/platform/devices/1020a000.wed`
  - `/sys/bus/platform/devices/1020b000.wed`
- Debugfs WED nodes currently report `regval=0x76220001` at `regidx=0` for both `wed0` and `wed1`.
- The live Wi-Fi DT node `/sys/firmware/devicetree/base/pcie@1a143000/pcie@0,0/wifi@0,0`
  has `compatible="mediatek,mt76"` and no `mediatek,wed` property.
- The PCI device is `14c3:7915` on `0000:01:00.0`, driver `mt7915e`, with `enable=1`.
- Kernel symbols for the targeted functions are present on the flashed image:
  - `mtk_wed_stop`
  - `mtk_wed_reset_dma`
  - `mtk_wed_fe_reset`
  - `mtk_wed_fe_reset_complete`
  - `mtk_wed_add_hw`

Raw logs:
- `raw-audit.txt`
- `probe2.txt`
