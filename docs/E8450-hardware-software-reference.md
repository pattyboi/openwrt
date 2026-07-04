# E8450 / MT7622 — Condensed Hardware & Software-Path Reference

Updated 2026-07-05 on `e8450-hw-driven`. Supersedes scattered notes; raw
probes in `.recall/router-probes/` (latest full survey:
`2026-07-05-hw-survey/survey-raw.txt`).

## Hardware map (verified live)

| Block | Details | State |
|---|---|---|
| SoC | MT7622BV, 2x Cortex-A53 (part 0xd03) | — |
| CPU freq | 437–1350 MHz, `ondemand` governor | tunable |
| RAM | 512 MB DDR3 (489 MB usable, ~385 MB free) | ample |
| Crypto | **No EIP97** (no clock gate in SoC clk tree — verdict final). ARMv8 CE active: aes/pmull/sha1/sha2; `*-ce` kernel drivers loaded | best-available in use |
| Ethernet | mtk_eth `1b100000`, netsys **v1**, QDMA (16 TX queues live), 1 PDMA RX ring. No RSS/HWLRO hardware | PPE+PPPQ active |
| Switch | MT7530 (mdio-bus:1f), 5 PHYs, DSA "mtk" tag; lan1-4 + wan | — |
| PPE | 1 unit (`ppe0` debugfs), hw-NAT validated | active |
| WED | v1 x2 (`1020a000`/`1020b000`); mt7915 attaches **wed0** | **WORKING** (boot-load only) |
| Wi-Fi | wl0 = MT7622 WMAC (2.4G, mt7615e); wl1 = MT7915E PCIe `0000:01:00.0`, Gen2 x1 (5 GT/s) | both AP-capable |
| PCIe | port0 = mt7915; **port1 (`1a145000`) enabled but no device/slot** | port1 dead weight |
| USB | xHCI + 3-phy T-PHY up, usb1/usb2 root hubs — **no external port on E8450** | unused |
| Storage | SPI-NAND 128 MB UBI (bl2 + ubi), ECC engine `1100e000` | — |
| Thermal | `cpu-thermal` zone (~58 °C idle-ish), auxadc | headroom OK |
| TRNG | `1020f000.rng` (mtk) | working (runtime-PM hardened patch in tree) |
| Watchdog | `mtk-wdt 10212000` | **cannot recover AXI-fabric hangs** |
| Serial | ttyS0 console in DT — **no populated UART header** | pstore/ramoops instead |
| Recovery | u-boot: `pstore check` → boots recovery volume when crash dumps present; reset-button TFTP path exists | see rules below |
| IRQs | ALL network IRQs (eth0 x2, wifi) on **CPU0**; CPU1 idle | tuning target |

## Software paths — status

| Path | Mechanism | Status |
|---|---|---|
| Routed v4 fwd | PPE hw-NAT (BND entries) | validated |
| WAN→WLAN fwd | PPE → WDMA → **WED v1** → mt7915 | validated (counters + MIB) |
| Bridged LAN↔WLAN | nft bridging offload (`999-ppe-90/91/89`) | built, boots; E2E bind test pending (needs 2 LAN clients) |
| QoS | PPPQ per-port queues + TCP-ACK prio (conntrack builtin) + DSCP learning (ppe-12/17) | validated |
| Mark-based QoS | `skb->mark` 1..N-1 → QDMA queue (`999-eth-27`) | built; functional test pending |
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
   r8169 NIC is untrustworthy.
8. Don't grep dmesg for `-i oops` — matches "ramoops"; use `BUG:|Call trace`.

## Closed investigations (do not reopen)

- EIP97/crypto SDK patches: no silicon. RSS/HWLRO: netsys v2/v3 caps only.
- pcie-01..04 SDK: gen3 controller only (MT7622 = gen2 driver).
- WED filogic patch series: v1 mainline works; revisit wed-03/13/14/16 only
  if SER tests show WDMA hangs.
- eth0 stop/open "lock": was host-NIC misdiagnosis; path is fine.
- mtk_eth_set_dma_device close/reopen: exonerated.

## Next-direction candidates (ranked)

1. **IRQ/RPS spread across the 2 cores** — all net IRQs on CPU0 today;
   pin eth0 vs wifi IRQs apart + RPS mask for host-terminated traffic.
   Cheap, measurable.
2. **cpufreq governor A/B** — `ondemand` (437 MHz floor) vs `performance`
   for latency jitter under WED+PPE load.
3. **Bridged-offload E2E validation** (ppe-90) with two LAN clients, then
   the eth-27 mark→queue functional check.
4. **WED soak/perf** at real WAN speeds (current upstream hop is ~5 Mbps —
   inadequate for throughput numbers).
5. **SER / `wed_v1_txbm_quiesce` A/B** — the original harness plan, now
   unblocked.
6. Optional upstream reports: runtime-bind WED AXI lock, mt7915e rebind
   AXI lock, mt76 SER-during-probe NULL deref (evidence in
   `.recall/router-probes/2026-07-04-firstbind-wed-lock/`).
7. Housekeeping: real SSIDs/PSKs (currently open "OpenWrt"), persistent
   flow-offload via firewall4 instead of the runtime bench nft table.
