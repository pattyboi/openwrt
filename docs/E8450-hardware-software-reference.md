# E8450 / MT7622 — Condensed Hardware & Software-Path Reference

Updated 2026-07-12 (box recovered and reflashed with the repo build —
first-boot verification recorded below) on `e8450-hw-driven`. This is the
current interpretation of the recorded evidence; the 2026-07-09 live snapshot
below predates the recovery/reflash and is not a claim about the router's
present uptime or network address. Raw probes are in `.recall/router-probes/`
when that local evidence store is available.

Status labels in this document mean:

- **tree fact** — directly visible in the DTS, Kconfig, patch, or packaged
  script in this checkout;
- **live-validated** — observed on hardware in a dated probe; scope and test
  method are stated where they matter;
- **candidate** — compiled or reasoned about, but not hardware-validated.

## Hardware map (verified live)

| Block | Details | State |
|---|---|---|
| SoC | MT7622BV, 2x Cortex-A53 (part 0xd03) | — |
| CPU freq | 437–1350 MHz, `ondemand` governor | tunable |
| RAM | 512 MB DDR3 (489 MB usable, ~385 MB free) | ample |
| Crypto | **No EIP97** (no clock gate in SoC clk tree — verdict final). ARMv8 CE active: aes/pmull/sha1/sha2; `*-ce` kernel drivers loaded | best-available in use |
| Ethernet | mtk_eth `1b100000`, netsys **v1**, QDMA (16 TX queues live), 1 PDMA RX ring. No RSS/HWLRO hardware | PPE+PPPQ active |
| Switch | **MT7531** at MDIO address `0x1f`, 5 user PHY ports, DSA `mtk` tag; lan1-4 + wan | tree fact; forwarding path live-validated |
| PPE | 1 unit; debugfs `/sys/kernel/debug/ppe0/`; hw-NAT validated | active |
| WED | v1 x2 (`1020a000`/`1020b000`); dmesg: `mt7915e 0000:01:00.0: attaching wed device 0 version 1` **confirmed hardware-attached**; debugfs `/sys/kernel/debug/wed0/` (regidx/regval/txinfo) | **WORKING** (boot-load only) |
| Wi-Fi | wl0 = MT7622 WMAC (2.4G, mt7615e, phy0); wl1 = MT7915E PCIe `0000:01:00.0`, Gen2 x1 (5 GT/s, phy1) | both AP-capable |
| PCIe | port0 carries MT7915E; port1 node (`1a145000`) is enabled in the DTS but no endpoint/slot was observed | port1 unused in the recorded live probe; do not infer a hardware fault from absence of an endpoint |
| USB | xHCI + 3-phy T-PHY up, usb1/usb2 root hubs — **no external port on E8450** | unused |
| Storage | SPI-NAND 128 MB UBI (bl2 + ubi), ECC engine `1100e000` | — |
| Thermal | `cpu-thermal` zone (60.4 °C under light real traffic), mt7615_phy0 60°C, mt7915_phy1 54°C, auxadc | headroom OK |
| TRNG | `1020f000.rng` (legacy MMIO mtk-rng) | active HWRNG; live-read and runtime-PM verified |
| Watchdog | `mtk-wdt 10212000` | **cannot recover AXI-fabric hangs** |
| Serial | ttyS0 console in DT — **no populated UART header** | pstore/ramoops instead |
| Recovery | u-boot `pstore check` boots the recovery volume when crash dumps are present; reset-button/TFTP recovery is reported in the board workflow | recovery path is safety-critical; verify before destructive tests |
| IRQs | 31 IRQs set 0-1 affinity (both CPUs). NET_RX softirq skew improved from 5:1 to ~1.5:1 CPU0:CPU1 after enabling `packet_steering` (see Closed investigations). `tc` not installed (no iproute2-tc). |

## Software paths — status

| Path | Mechanism | Status |
|---|---|---|
| Routed v4 fwd | PPE hw-NAT (BND entries) | live-validated under recorded routed traffic |
| WAN→WLAN fwd | PPE → WDMA → **WED v1** → mt7915 | validated (counters + MIB) |
| Bridged LAN↔WLAN | nft bridging offload (`999-ppe-90/91/89`) | built, boots; helper/procedure added, E2E bind proof still pending |
| QoS | PPPQ per-port queues + TCP-ACK priority (conntrack builtin) + DSCP learning (ppe-12/17) | PPPQ/TCP-ACK path live-validated; DSCP behavior remains narrower and should be tested with bound transit flows |
| Mark-based QoS | `skb->mark` 1..N-1 → QDMA queue (`999-eth-27`) | **live-validated only for router-originated traffic** (2026-07-10): BQL per-queue inflight showed unmarked→tx-4, mark 5→tx-5, mark 11→tx-11, and out-of-range mark 200→tx-4 fallback. Transit traffic that becomes PPE-bound bypasses this software TX selector; validate that separately before claiming a forwarding benefit. |
| SW flowtable hash | seeded xxh32 tuple hash (`999-ppe-92`) | flashed; bind verified |
| Inet/nft set hashes | upstream `jhash_1word()` / `jhash_3words()` / `jhash()` | experimental UMASH replacements removed 2026-07-10: no measured speedup, 64-bit collision claim lost after `u32` truncation, unsafe generic arm64 PMULL gate, and no differential test vectors. Reconsider only behind the benchmark/correctness gates in `docs/umash-port-task.md` — successor audit done 2026-07-11 (rapidhash selected, Komihash/XXH3 rejected) and the microbench candidate matrix is fixed there (§Next-phase microbenchmark). |
| IRQ/RPS spread | `network.globals.packet_steering=2` + static hardirq pinning via `files/etc/rc.local` (eth0 RX IRQ→CPU0, eth0 TX IRQ→CPU1, mt7915e/mt7615e IRQs→CPU1) | **live-validated in one 2026-07-09 probe**: NET_RX improved from ~5:1 to ~1.5:1 under ~100 Mbps WAN traffic. NET_TX remained ~7.9:1 and is not evidence of a forwarding bottleneck because PPE-bound traffic bypasses the software TX path. |
| SER recovery | `wl1 mt76 sys_recovery`; `wed_v1_txbm_quiesce` A/B harness in tree | one quiesce=1 run reached WED start-entry without a SoC/TX-BM lock, but the MT7915 MCU died (`0x13ed` timeout) and Wi-Fi required a power cycle. This does not prove the patches fix SER; quiesce=0 control and a clean repeated run remain required. |
| Debug | WED-AT tracer + `wed_attach_max_access` gate; eth stop/open stage harness; ramoops console+pmsg; sysrq + hung-task detector | all dormant, params default-off |

## Operating rules (hard-won — do not violate)

Hard-locks 1–5 (mt7915e/WED boot-only load, modules.d argv, pstore/panic
recovery, power-replug/setsid, WAN-vantage verification) live in the
project `CLAUDE.md` — that file is the single source of truth, kept there
so it's cheap insurance re-read every message. Don't fork a second copy
here. Supplementary detail not in CLAUDE.md:

1. Netconsole is broken on this stack (netpoll drops pre-ndo; beads bug).
2. LAN SSH: root@192.168.1.1 — root password is EMPTY since the 2026-07-12
   recovery/reflash (set one before exposing WAN). The WAN details recorded
   with the 2026-07-09 snapshot (71.61.93.132/23 etc.) are historical; WAN
   is now plain DHCP upstream and the config carried over from the official
   25.12.5 recovery install, not our previous tuned config.
3. Don't grep dmesg for `-i oops` — matches "ramoops"; use `BUG:|Call trace`.

## 2026-07-12 reflash — first-boot verification (most recent live evidence)

The box had been recovered to official OpenWrt 25.12.5 (r33051-f5dae5ece4,
kernel 6.12.94), then reflashed with the repo build over the SSH sysupgrade
path (`scripts/flashing/flash.sh`, artifact set sha256-verified; image =
the 2026-07-11 21:42 rebuild that passed the post-stale-targetinfo
`.manifest` gate). sysupgrade signature check passed; config carried over
(official-25.12.5 fresh defaults). Verified live over SSH ~30 s after the
reboot:

- Build identity: OpenWrt 25.12.4 **r32933-4ccb782af7**, kernel **6.12.87**,
  board `linksys,e8450-ubi` — exact match to `bin/targets/.../version.buildinfo`,
  and the kernel banner shows it was compiled on this build host
  (`root@DietPi`, GCC 14.3.0 r32933).
- Our tree's fingerprints present: `wed-breadcrumb@42fef000` reserved-mem
  node in dmesg; `mt7915e` loaded at boot via `/etc/modules.d/mt7915e`
  (hard-lock rule 1 respected — no runtime load); MT7915 WM/WA firmware
  20240429 loaded, WED attach path intact.
- Not a stripped image: 157 packages installed via `apk` (25.12 uses apk,
  `opkg` reports 0 — that is expected, not a regression); `/sbin/wifi` and
  `/usr/sbin/pppd` present; `radio0` up.
- `/sys/fs/pstore/` empty — clean boot into the main volume, not the
  u-boot `pstore check` recovery volume (hard-lock rule 3 satisfied).

Caveat: this verifies boot + driver bring-up only. Offload-path claims
(PPE bind, WED counters, PPPQ) in the table above were validated on earlier
probes and have not been re-run on this boot.

### Same day, later: system-Clang kernel build + boot verification

The GCC image above was then superseded by a `SYSTEM_CLANG=1` build
(host Debian clang 19.1.7 / LLD 19.1.7, `KERNEL_LTO=none`, userspace
still GCC), flashed the same way and verified live at ~1 min uptime:

- `/proc/version`: `Linux version 6.12.87 (root@DietPi) (Debian clang
  version 19.1.7 (3+b1), Debian LLD 19.1.7)` — the running kernel is
  clang-compiled and LLD-linked.
- Same checklist as the GCC boot, all green: r32933 revision match,
  `wed-breadcrumb` node, mt7915e probed at boot via modules.d (WM/WA
  firmware loaded), PPE debugfs (`/sys/kernel/debug/ppe0/`) present,
  157 apk packages, both radios up, zero `BUG:|Call trace` in dmesg.
- pstore held only `console-ramoops-0` from the previous GCC boot,
  ending in a clean `reboot: Restarting system` (no `dmesg-*` records,
  so no u-boot `pstore check` recovery risk); saved nothing, removed it.

The clang build initially FAILED and the failure was a real bug: stock
OpenWrt patch `package/kernel/mac80211/patches/subsys/350-mac80211-
allow-scanning-while-on-radar-channel.patch` hoists an
`ieee80211_can_leave_ch(sdata, req, …)` check in
`ieee80211_start_roc_work()` above the point where `req` is read from
`local->scan_req`, so the check consumes an uninitialized pointer that
`ieee80211_is_radar_required()` dereferences whenever a link has
`radar_required` set (ROC request while operating a DFS channel). GCC
14.3 compiled it silently — every earlier GCC image carries this UB —
clang's `-Werror,-Wuninitialized` rejected it. Fixed by local patch
`subsys/351-mac80211-fix-uninitialized-scan-req-use-in-start_roc.patch`
(hoists the `wiphy_dereference()`, drops the now-dead later assignment).
Candidate for upstreaming to OpenWrt.

### Net-infrastructure audit and IRQ/steering tuning re-fix (2026-07-12)

A broad post-WED-investigation audit of live router config (network,
wireless, firewall, DHCP, CPU/thermal, conntrack) found the 2026-07-09
`packet_steering=2` + IRQ-pinning tuning had silently regressed: live
`NET_RX` skew measured **~24.9:1** (CPU0=5277, CPU1=212) — worse than
even the pre-tuning historical baseline (5:1). Root cause: `/etc/rc.local`
had reverted to the stock empty template and `network.globals.
packet_steering` read `'1'` instead of `'2'`. **This is a sysupgrade
config-carryover gotcha, not a build defect** — `files/etc/rc.local` in
this repo has always had the correct pinning script (eth0 RX IRQ→CPU0,
eth0 TX/mt7915e/mt7615e IRQs→CPU1); sysupgrade treats `/etc/rc.local` as
preserved user config (it's outside `/etc/config/`), so when this box was
recovered to stock OpenWrt 25.12.5 and then sysupgraded to our build on
2026-07-11, the *stock* empty `rc.local` silently rode along and shadowed
our build's version. **Expect this to recur on every future sysupgrade
unless the flashing procedure is changed to explicitly reapply
`files/etc/rc.local` and `packet_steering` post-flash** —
`docs/BUILDING.md`/`docs/FLASHING.md` should probably get a post-flash
checklist line for this.

Fix reapplied live 2026-07-12 (no rebuild needed — both are runtime
config): pushed `files/etc/rc.local` content to `/etc/rc.local` and ran
it (`smp_affinity` confirmed: eth0 RX=1/CPU0, eth0 TX=2/CPU1,
mt7915e=2/CPU1, mt7615e=2/CPU1); `uci set
network.globals.packet_steering='2'` + `uci commit network` +
`/etc/init.d/network reload` (confirmed `rps_cpus=2` on eth0's RX queue
afterward). Verified working: softirq deltas during a traffic burst
showed CPU0:+213/CPU1:+102 (~2:1, a large improvement over the ~24.9:1
pre-fix state; traffic here was a light wifi ping burst through
`wlan0`/`br-lan`, not the original ~100 Mbps WAN-transit test, so an
exact match to the historical 1.5:1 wasn't expected or required to
confirm the fix is active).

**LAN/WAN subnet collision — documented, not a bug to fix.** While
auditing, found the E8450's own default route
(`default via 192.168.1.1 dev wan`) collides with its own LAN address
(`192.168.1.1` on `br-lan`) whenever its WAN is plugged into another
router that also defaults to `192.168.1.0/24` (as happened this session,
WAN → Netgear). `ip route get 192.168.1.1` resolves to
`local ... dev lo` (the router's own address) rather than the real
upstream gateway — this is exactly the ambiguity that caused real
operational friction debugging *this session's own* SSH access from a
dual-homed Pi client (see `wed-mcu-death-terminal-signature` /
`e8450-router-access` memory for the policy-routing workaround). Tested
whether this actually breaks anything for real LAN clients: it does not
— fresh/uncached DNS lookups (`wikipedia.org`, not cached) and internet
ping both resolved correctly from a genuine LAN client despite the
collision; only router-self-originated traffic explicitly targeting
`192.168.1.1` (e.g. a shell tool run directly on the router) is affected,
and that's a narrow, low-impact case. Nothing to change in our config —
this is purely a byproduct of the current double-router test topology and
will disappear once the E8450's WAN is back on a real upstream (ISP
modem/ONT) or any router with a different LAN subnet. Documented here so
it isn't re-diagnosed from scratch next time this topology recurs.

## Last recorded live snapshot (2026-07-09 probe — 4d11h30m uptime, pre-recovery)

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

1. **Bridged-offload E2E validation** (ppe-90) with two LAN clients —
   needs one wired + one Wi-Fi client on br-lan; procedure in
   `docs/e8450-bridged-offload-validation.md`. (The eth-27 mark→queue
   functional check that used to share this slot was **validated
   2026-07-10** — see Software paths table.)
2. **WED soak/perf** at real WAN speeds (current upstream hop is ~100 Mbps
   now — worth revisiting for real throughput numbers, was previously
   blocked at ~5 Mbps).
3. ~~**SER / `wed_v1_txbm_quiesce` A/B**~~ — **CLOSED 2026-07-12, outside
   reasonable further gains, do not reopen.** 2×2 discriminator confirmed
   WED-path-dependent (not quiesce-gated); wed-03/wed-13/wed-16 backports
   all flashed + hardware-retested, none fix it; live register/ring trace
   then found the actual terminal signature — `mt7915_mac_full_reset()`
   exhausts its 10x retry budget (WM firmware's `fw_log_2_host` response
   never arrives, any attempt, every repro) and gives up
   (`chip full reset failed`), triggering mac80211's own WARN_ON teardown
   cascade (not a panic). `WED_TX_FREE_AGENT_EN` and the WED MCU response
   ring were both live-verified correctly armed throughout — ruled out as
   host-side causes. No firmware-side diagnostic path exists either
   (`fw_debug_wm`/`wa`/`bin` circularly depend on the same broken command;
   no UART on this board). This is now a WM-firmware-side question not
   diagnosable further from this host. Full record:
   `docs/WED-breadcrumb-harness-design.md` (§Terminal failure signature
   onward); memory `wed-mcu-death-terminal-signature`.
4. Optional upstream reports: runtime-bind WED AXI lock, mt7915e rebind
   AXI lock, mt76 SER-during-probe NULL deref (evidence in
   `.recall/router-probes/2026-07-04-firstbind-wed-lock/`).
5. ~~NET_TX softirq skew~~ — **closed, not actionable** (2026-07-09): root
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
6. Real PSKs — SSIDs/encryption were changed from open to `sae-mixed`
   (2026-07-09) but SSID names are still the OpenWrt defaults
   ("OpenWrt2"/"OpenWrt5"), not renamed.
