# E8450 / MT7622 — Condensed Hardware & Software-Path Reference

Updated 2026-07-05 (evening, live-router probe) on `e8450-hw-driven`.
Supersedes scattered notes; raw probes in `.recall/router-probes/`.

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
| IRQs | 31 IRQs set 0-1 affinity (both CPUs), 1 on CPU0 only, 1 on CPU1 only; but NET_RX softirq: CPU0 3.3M vs CPU1 618K (5:1 skew). `tc` not installed (no iproute2-tc). Wired clients via lan1 only today; lan2-4 NO-CARRIER | tuning target |

## Software paths — status

| Path | Mechanism | Status |
|---|---|---|
| Routed v4 fwd | PPE hw-NAT (BND entries) | validated |
| WAN→WLAN fwd | PPE → WDMA → **WED v1** → mt7915 | validated (counters + MIB) |
| Bridged LAN↔WLAN | nft bridging offload (`999-ppe-90/91/89`) | built, boots; helper/procedure added, E2E bind proof still pending |
| QoS | PPPQ per-port queues + TCP-ACK prio (conntrack builtin) + DSCP learning (ppe-12/17) | validated |
| Mark-based QoS | `skb->mark` 1..N-1 → QDMA queue (`999-eth-27`) | built; functional test pending |
| SW flowtable hash | seeded xxh32 tuple hash (`999-ppe-92`) | flashed; bind verified |
| IRQ/RPS spread | OpenWrt generic `packet_steering` first-boot default added; **preserved/upgraded configs do NOT get it** (uci-default skipped). Fresh-flash required to test. | needs live validation on fresh install |
| SER recovery | `wl1 mt76 sys_recovery`; `wed_v1_txbm_quiesce` A/B harness in tree | now testable (WED live) |
| Debug | WED-AT tracer + `wed_attach_max_access` gate; eth stop/open stage harness; ramoops console+pmsg; sysrq + hung-task detector | all dormant, params default-off |

## Operating rules (hard-won — do not violate)

1. WED on = `mt7915e wed_enable=1` in `/etc/modules.d/mt7915e` (listed in
   `/etc/sysupgrade.conf`) + boot. **Never** runtime-insmod mt7915e with
   WED, **never** PCI unbind/rebind it — both hard-lock the AXI fabric
   unrecoverably (all kernels; watchdog + `reboot -f` defeated).
2. kmodloader ignores `modprobe mod param=x` argv — params go in the
   modules.d file.
3. After any panic: save then `rm /sys/fs/pstore/dmesg-*`, else u-boot
   boots the recovery volume (tmpfs root, no wifi) every time.
4. Fast power-replug (1–2 s) preserves ramoops through a "cold" cycle.
5. `setsid` survives dropbear disconnect; `nohup &` does not.
6. Netconsole is broken on this stack (netpoll drops pre-ndo; beads bug).
7. Verify router life via WAN vantage (192.168.3.15) — the build laptop's
   r8169 NIC is untrustworthy. LAN SSH: root@192.168.1.1. WAN IP (live):
   71.61.93.132/23 via DHCP, GW 71.61.92.1, dual-stack (IPv6 delegated
   2601:547:cb00:3afa::/64). DNS pinned to 1.1.1.1/1.0.0.1 (peerdns=0).
8. Don't grep dmesg for `-i oops` — matches "ramoops"; use `BUG:|Call trace`.

## Live state snapshot (2026-07-05 probe — 11h39m uptime)

```
Build : OpenWrt 25.12.4 r32933-4ccb782af7, kernel 6.12.87 (GCC 14.3.0)
CPU   : 2x Cortex-A53 @ 1350 MHz (both at max at probe time)
RAM   : 501 MB total, 69 MB used, 384 MB free
Temp  : CPU 60.4°C / mt7615 60°C / mt7915 54°C (light real traffic)
WAN   : DHCP 71.61.93.132/23, GW 71.61.92.1, IPv6 /128 DHCPv6
LAN   : 192.168.1.0/24, 10 DHCP leases, lan1 wired up / lan2-4 empty
Wifi  : wl0 "OpenWrt2" ch1 2.4G 20MHz / wl1 "OpenWrt5" ch36 5G 40MHz (both open)
WED   : wed_enable=Y; dmesg confirms "attaching wed device 0 version 1"
Offld : flow_offloading_hw=1; nft flowtable ft with flags offload active
PPE   : ppe0 debugfs present; conntrack 42 entries / 31744 max
Traffic: eth0 RX 33.9 GB / TX 13.9 GB; wl1 RX 790 MB / TX 2.0 GB in 11h
tc    : NOT installed (iproute2-tc not in build)
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

- EIP97/crypto SDK patches: no silicon. RSS/HWLRO: netsys v2/v3 caps only.
- pcie-01..04 SDK: gen3 controller only (MT7622 = gen2 driver).
- WED filogic patch series: v1 mainline works; revisit wed-03/13/14/16 only
  if SER tests show WDMA hangs.
- eth0 stop/open "lock": was host-NIC misdiagnosis; path is fine.
- mtk_eth_set_dma_device close/reopen: exonerated.

## Next-direction candidates (ranked)

1. **Validate packet steering live** — first-boot default confirmed NOT applied
   to this preserved config (probe 2026-07-05). Requires fresh sysupgrade
   (--force-non-upgrade or no keep-settings) to test. Current box has
   NET_RX skew 5:1 CPU0:CPU1; after enabling, check `/proc/softirqs` for
   balance.
2. **cpufreq governor A/B** — `ondemand` (437 MHz floor) vs `performance`
   for latency jitter under WED+PPE load.
3. **Bridged-offload E2E validation** (ppe-90) with two LAN clients, then
   the eth-27 mark→queue functional check.
   See `docs/e8450-bridged-offload-validation.md`.
4. **WED soak/perf** at real WAN speeds (current upstream hop is ~5 Mbps —
   inadequate for throughput numbers).
5. **SER / `wed_v1_txbm_quiesce` A/B** — the original harness plan, now
   unblocked.
6. Optional upstream reports: runtime-bind WED AXI lock, mt7915e rebind
   AXI lock, mt76 SER-during-probe NULL deref (evidence in
   `.recall/router-probes/2026-07-04-firstbind-wed-lock/`).
7. Housekeeping: real SSIDs/PSKs (currently open "OpenWrt"). Fresh installs
   now also default firewall4 flow offload + hardware flow offload ON for
   E8450/RT3200 via `files/etc/uci-defaults/99-e8450-flow-offload`;
   upgraded/preserved configs keep their existing setting.
