# E8450 / MT7622 — Condensed Hardware & Software-Path Reference

Updated 2026-07-10 (SER quiesce first run — MCU-side failure, WED
exonerated) on `e8450-hw-driven`. Supersedes scattered notes; raw probes
in `.recall/router-probes/`.

## Hardware map (verified live)

| Block | Details | State |
|---|---|---|
| SoC | MT7622BV, 2x Cortex-A53 (part 0xd03) | — |
| CPU freq | 437–1350 MHz, `ondemand` governor | tunable |
| RAM | 512 MB DDR3 (489 MB usable, ~385 MB free) | ample |
| Crypto | **No EIP97** (no clock gate in SoC clk tree — verdict final). ARMv8 CE active: aes/pmull/sha1/sha2; `*-ce` kernel drivers loaded | best-available in use |
| Ethernet | mtk_eth `1b100000`, netsys **v1**, QDMA (16 TX queues live), 1 PDMA RX ring. No RSS/HWLRO hardware | PPE+PPPQ active |
| Switch | MT7530 (mdio-bus:1f), 5 PHYs, DSA "mtk" tag; lan1-4 + wan | — |
| PPE | 1 unit; debugfs `/sys/kernel/debug/ppe0/`; hw-NAT validated | active |
| WED | v1 x2 (`1020a000`/`1020b000`); dmesg: `mt7915e 0000:01:00.0: attaching wed device 0 version 1` **confirmed hardware-attached**; debugfs `/sys/kernel/debug/wed0/` (regidx/regval/txinfo) | **WORKING** (boot-load only) |
| Wi-Fi | wl0 = MT7622 WMAC (2.4G, mt7615e, phy0); wl1 = MT7915E PCIe `0000:01:00.0`, Gen2 x1 (5 GT/s, phy1) | both AP-capable |
| PCIe | port0 = mt7915; **port1 (`1a145000`) enabled but no device/slot** | port1 dead weight |
| USB | xHCI + 3-phy T-PHY up, usb1/usb2 root hubs — **no external port on E8450** | unused |
| Storage | SPI-NAND 128 MB UBI (bl2 + ubi), ECC engine `1100e000` | — |
| Thermal | `cpu-thermal` zone (60.4 °C under light real traffic), mt7615_phy0 60°C, mt7915_phy1 54°C, auxadc | headroom OK |
| TRNG | `1020f000.rng` (legacy MMIO mtk-rng) | active HWRNG; live-read and runtime-PM verified |
| Watchdog | `mtk-wdt 10212000` | **cannot recover AXI-fabric hangs** |
| Serial | ttyS0 console in DT — **no populated UART header** | pstore/ramoops instead |
| Recovery | u-boot: `pstore check` → boots recovery volume when crash dumps present; reset-button TFTP path exists | see rules below |
| IRQs | 31 IRQs set 0-1 affinity (both CPUs). NET_RX softirq skew improved from 5:1 to ~1.5:1 CPU0:CPU1 after enabling `packet_steering` (see Closed investigations). `tc` not installed (no iproute2-tc). |

## Software paths — status

| Path | Mechanism | Status |
|---|---|---|
| Routed v4 fwd | PPE hw-NAT (BND entries) | validated |
| WAN→WLAN fwd | PPE → WDMA → **WED v1** → mt7915 | validated (counters + MIB) |
| Bridged LAN↔WLAN | nft bridging offload (`999-ppe-90/91/89`) | built, boots; helper/procedure added, E2E bind proof still pending |
| QoS | PPPQ per-port queues + TCP-ACK prio (conntrack builtin) + DSCP learning (ppe-12/17) | validated |
| Mark-based QoS | `skb->mark` 1..N-1 → QDMA queue (`999-eth-27`) | **validated live** (2026-07-10): BQL per-queue inflight during router-originated iperf3 — unmarked→tx-4 (DSA+3 path), mark 5→tx-5, mark 11→tx-11, mark 200 (≥16, out of range)→tx-4 fallback. Method: temp `nft` table `inet marktest` (route hook output, `meta mark set N`) + `/sys/class/net/eth0/queues/tx-*/byte_queue_limits/inflight` sampling (no tc/ftrace in image; feed kmods don't match self-built kernel). |
| SW flowtable hash | seeded xxh32 tuple hash (`999-ppe-92`) | flashed; bind verified |
| Inet/nft set hashes | upstream `jhash_1word()` / `jhash_3words()` / `jhash()` | experimental UMASH replacements removed 2026-07-10: no measured speedup, 64-bit collision claim lost after `u32` truncation, unsafe generic arm64 PMULL gate, and no differential test vectors. Reconsider only behind the benchmark/correctness gates in `docs/umash-port-task.md` — successor audit done 2026-07-11 (rapidhash selected, Komihash/XXH3 rejected) and the microbench candidate matrix is fixed there (§Next-phase microbenchmark). |
| IRQ/RPS spread | `network.globals.packet_steering=2` + static hardirq pinning via `files/etc/rc.local` (eth0 RX IRQ→CPU0, eth0 TX IRQ→CPU1, mt7915e/mt7615e IRQs→CPU1) | **validated live** (2026-07-09): NET_RX softirq CPU0 10.8M / CPU1 7.1M (~1.5:1), vs. 5:1 pre-steering. NET_TX skew (~7.9:1) is real but not fixable this way — see Next-direction #6 (closed). |
| SER recovery | `wl1 mt76 sys_recovery`; `wed_v1_txbm_quiesce` A/B harness in tree | quiesce leg run 2026-07-10: **no SoC lock, no TX-BM hang** (breadcrumb reached start-entry ph=4 id=40), but mt7915 MCU died (msg 0x13ed timeout) → mt76 restart loop, wifi down until power cycle. Failure is MCU-side, not WED. Baseline quiesce=0 leg pending. See `docs/WED-breadcrumb-harness-design.md` §First SER quiesce run |
| Debug | WED-AT tracer + `wed_attach_max_access` gate; eth stop/open stage harness; ramoops console+pmsg; sysrq + hung-task detector | all dormant, params default-off |

## Operating rules (hard-won — do not violate)

Hard-locks 1–5 (mt7915e/WED boot-only load, modules.d argv, pstore/panic
recovery, power-replug/setsid, WAN-vantage verification) live in the
project `CLAUDE.md` — that file is the single source of truth, kept there
so it's cheap insurance re-read every message. Don't fork a second copy
here. Supplementary detail not in CLAUDE.md:

1. Netconsole is broken on this stack (netpoll drops pre-ndo; beads bug).
2. LAN SSH: root@192.168.1.1. WAN IP (live): 71.61.93.132/23 via DHCP, GW
   71.61.92.1, dual-stack (IPv6 delegated 2601:547:cb00:3afa::/64). DNS
   pinned to 1.1.1.1/1.0.0.1 (peerdns=0).
3. Don't grep dmesg for `-i oops` — matches "ramoops"; use `BUG:|Call trace`.

## Live state snapshot (2026-07-09 probe — 4d11h30m uptime)

```
Build : OpenWrt 25.12.4 r32933-4ccb782af7, kernel 6.12.87
CPU   : 2x Cortex-A53 @ 1137 MHz (ondemand, mid-scale under ~100Mbps live load)
RAM   : 501 MB total, 68 MB used, 385 MB free
Temp  : CPU 56.6°C (down from 60.4°C — better core balance, see below)
WAN   : DHCP 71.61.93.132/23, GW 71.61.92.1, up, ~100Mbps active w/ live clients
LAN   : 192.168.1.0/24, 4 DHCP leases at probe time
Wifi  : wireless.default_radio0 "OpenWrt2" / default_radio1 "OpenWrt5",
        encryption=sae-mixed on both (changed from open; SSID names are
        still OpenWrt defaults, NOT renamed — don't assume otherwise)
Offld : flow_offloading=1, flow_offloading_hw=1
PPE   : conntrack 48 entries / 31744 max
Traffic (cumulative, eth0): RX 307.25 GB / TX 234.10 GB over 4.48 days
softirqs: NET_RX CPU0 10.85M / CPU1 7.07M (~1.5:1); NET_TX CPU0 236K / CPU1 30K (~7.9:1)
dmesg : no BUG:/Call trace/Oops across the full 4.5-day uptime
```

## Closed investigations (do not reopen)

- xxhash audit (2026-07-05): only viable site was the flowtable tuple hash
  (done, 999-ppe-92). PPE bucket hash is silicon-fixed; RX jhash_1word is
  faster than xxh32 at 4 bytes; conntrack siphash and nft set hashes are
  keyed for DoS resistance — never swap those.
- TRNG/HWRNG backport audit (2026-07-04): MT7622 uses the legacy MMIO
  `mtk-rng` through the `mediatek,mt7623-rng` fallback. Live hardware has
  `1020f000.rng` selected, initializes the CRNG before userspace, returns
  data, and autosuspends afterward. Linux 6.12.87 already contains upstream
  `522a242` (check `devm_pm_runtime_enable()` errors); local patch 999 adds
  upstream device context plus `pm_runtime_resume_and_get()` error handling.
  Do not backport `99d9edf` alone: 6.12 PM helpers do not mark last-busy
  internally. Upstream 2026 SMCC support (`066d65a`) targets MT7981/MT7986/
  MT7987/MT7988 secure-firmware access and is not applicable to MT7622.

- Packet steering validation (2026-07-09): `network.globals.packet_steering`
  manually set to `2` on the live (preserved-config) router; confirmed via
  `/proc/softirqs` under real ~100Mbps WAN traffic. NET_RX skew improved
  from 5:1 to ~1.5:1 CPU0:CPU1. NET_TX stayed skewed ~7.9:1 (steering
  doesn't touch TX queue affinity — see Next-direction #6, closed
  not-actionable). The router was also already running a static IRQ
  affinity script (`/etc/rc.local` — eth0 RX/TX split, wifi IRQs on
  CPU1) that had never been committed; now tracked as
  `files/etc/rc.local`.
- EIP97/crypto SDK patches: no silicon. RSS/HWLRO: netsys v2/v3 caps only.
- Eth DMA coherency (2026-07-10): already optimal — mt7622.dtsi eth node
  has `dma-coherent` + `cci-control-port = <&cci_control2>` (ACE port on
  the CCI-400), and mtk_eth_soc probe writes snoop-enable (0x3) to that
  port (mtk_eth_soc.c ~5615).  Streaming DMA does **no** per-packet
  cache maintenance on this box; PCIe (mt7915 DMA) is dma-coherent too.
  Nothing to gain here.  Measured (2026-07-10, CCI-400 PMU): DMA reads
  served by CPU-cache snoops ≈ 9 K/15 s at GbE line rate — three orders
  below the l1d refill rate, confirming coherency traffic is negligible.
- Cache-line struct audit (2026-07-10): **closed after two flash cycles**
  — full record in `docs/cacheline-audit.md`.  Patch 01 (mtk_eth
  hot/cold split) + the `-O2` datapath patch and patch 02 (mtk_tx_ring
  writer split) are all live in `patches-6.12/`.  Cycle-2 verdict:
  patch 02 produced no measurable delta (l1d refills, CPU%, softirq%
  all flat at line rate); GbE with this much CPU headroom is not
  cache-limited, so residual reorg candidates are shelved unless a
  refill-bound workload appears.  Patches stay (zero cost, cleaner
  layout, static_asserts guard hw-format structs).  `CONFIG_ARM_CCI400_PMU`
  is now enabled in `config-6.12`; note the CCI PMU can't arbitrate
  intra-cluster false sharing (that's SCU territory) and a multiplexed
  CCI event group costs ~100 Mbps while counting.
- UMASH hash-port experiment (2026-07-10): **closed and removed**. The
  hand port and inet/nft call-site conversions were compile/boot tested but
  had no isolated performance measurement. More importantly, the converted
  tables consumed only the low 32 bits, so the advertised full-width UMASH
  collision bound did not describe their effective hash; the generic arm64
  Kconfig gate also did not guarantee PMULL. Keep the upstream jhash baseline.
  Any future replacement must pass the differential-vector, target microbench,
  and one-subsystem-per-image gates in `docs/umash-port-task.md`.
- Netsys v2/v3 backport audit (2026-07-10): surveyed upstream
  drivers/net/ethernet/mediatek v6.12..master for v1-applicable WED/PPPQ
  work — **nothing left to take**. 6.12-LTS already carries the QDMA
  scheduler fixes (1b661241 token-bucket + SPEED_1000, 6b02eb37 100M
  queue weight), PPE per-tag-layer MTU init, fill_forward_path RCU fix,
  TX-queue reset on DMA free; the wed memory-region rework is in-tree
  as 940–944. Only absences: mtk_ppe_init probe-error rhashtable leak
  fix + LLC VLAN tx fix — no WED/PPPQ relevance, will arrive via LTS.
  Everything else v2/v3-era is hardware-gated (WED RX/RRO/AMSDU, WO fw,
  SRAM rings, v3 rate format).
- pcie-01..04 SDK: gen3 controller only (MT7622 = gen2 driver).
- WED filogic patch series: v1 mainline works for steady-state. **Reopened
  for SER (2026-07-10)**: the SER quiesce run motivated a re-audit —
  wed-03 hunk 1 (WDMA RX CPU_IDX reset inversion, still broken in
  mainline master) and wed-13 (PSE→WDMA packet block during SER) are now
  backport candidates; wed-14 is v3-only, wed-16 medium/hold. Full audit:
  `docs/WED-breadcrumb-harness-design.md` §SER patch re-audit. Patch
  files recoverable via `git show eef2a51256:target/linux/mediatek/patches-6.12/999-wed-*.patch`
  (eth ones: `f994c928e7`).
- eth0 stop/open "lock": was host-NIC misdiagnosis; path is fine.
- mtk_eth_set_dma_device close/reopen: exonerated.

## Next-direction candidates (ranked)

1. **cpufreq governor A/B** — `ondemand` (437 MHz floor) vs `performance`
   for latency jitter under WED+PPE load.
2. **Bridged-offload E2E validation** (ppe-90) with two LAN clients —
   needs one wired + one Wi-Fi client on br-lan; procedure in
   `docs/e8450-bridged-offload-validation.md`. (The eth-27 mark→queue
   functional check that used to share this slot was **validated
   2026-07-10** — see Software paths table.)
3. **WED soak/perf** at real WAN speeds (current upstream hop is ~100 Mbps
   now — worth revisiting for real throughput numbers, was previously
   blocked at ~5 Mbps).
4. **SER / `wed_v1_txbm_quiesce` A/B** — quiesce leg done 2026-07-10:
   no SoC lock / no TX-BM FIFO hang; instead the mt7915 MCU wedged
   (0x13ed = FW_LOG_2_HOST timeout → `mt7915_mac_full_reset` 10×
   restart loop, wifi down until power cycle). Code trace + SER patch
   re-audit done (see harness doc): prime fix candidates are SDK
   wed-03 hunk 1 (WDMA RX CPU_IDX reset inversion — verified still
   broken in mainline master) and wed-13 (PSE→WDMA block during SER,
   needs v1 port-macro adaptation). **Both backports prepared
   2026-07-10** as `999-zzzzz-wed-ser-01/-02` (compile-validated,
   applied to build_dir, NOT hardware-validated). The unvalidated NAND
   100 MHz DTS experiment was reverted, so current images retain the
   default 50 MHz pad clock. Next steps: (a) 2×2 discriminator — WED
   attached/detached × quiesce=0/1, logging both params into dmesg at
   trigger time; (b) flash + retest SER with the backports. Full record:
   `docs/WED-breadcrumb-harness-design.md` §Code trace / §SER patch
   re-audit; evidence `docs/logs/wed-quiesce-ramoops-20260710.txt`.
5. Optional upstream reports: runtime-bind WED AXI lock, mt7915e rebind
   AXI lock, mt76 SER-during-probe NULL deref (evidence in
   `.recall/router-probes/2026-07-04-firstbind-wed-lock/`).
6. ~~NET_TX softirq skew~~ — **closed, not actionable** (2026-07-09): root
   is `mtk_eth_soc.c`'s custom `ndo_select_queue = mtk_select_queue`
   (the PPPQ/mark-based QoS queue picker, 999-eth-27), which overrides
   the stack's generic `netdev_pick_tx()` entirely — `xps_cpus` is
   inert on this NIC, confirmed by reading the driver. `/etc/rc.local`
   (now in `files/etc/rc.local`) already pins the TX-side hardirq to
   CPU1 correctly; the softirq skew is a different, uncorrelated thing
   — `dev_queue_xmit()` fires on whatever CPU originates the send, which
   for this router is mostly local/control-plane traffic (hostapd,
   dnsmasq, dropbear), not the PPE-hardware-offloaded bulk WAN traffic
   that never touches Linux's TX softirq path at all. Volume confirms
   it: 266K TX softirq events vs. 17.9M RX over the same 4.5-day window
   — two orders of magnitude smaller, not worth chasing further via
   sysfs/rc.local. Would need a change inside `mtk_select_queue()`
   itself to move the needle, a different scope of change entirely.
7. Real PSKs — SSIDs/encryption were changed from open to `sae-mixed`
   (2026-07-09) but SSID names are still the OpenWrt defaults
   ("OpenWrt2"/"OpenWrt5"), not renamed.
