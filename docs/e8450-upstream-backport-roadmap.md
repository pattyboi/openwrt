# E8450 upstream backport roadmap

Scope: Linksys E8450/Belkin RT3200, MT7622BV, NETSYSv1, one PPE, integrated MT7615 2.4 GHz radio, PCIe MT7915 5 GHz radio, WED-v1.

## Status update (2026-08-31) — read this first

Everything below this section is the original chronological roadmap;
preserved as-is for process history, but several of its open items and
"current" facts are now stale. Current status:

- **mt76 pin bumped again**, past this doc's `2026-06-23` point, to
  `openwrt/mt76` master `6d1c6a75` (2026-08-04). The "Alternative, broader
  track" idea in Priority 2 (evaluate current HEAD, remove upstreamed local
  patches instead of duplicating) is done: **local patches `901`-`910` were
  deleted** (confirmed upstream via each patch's own `Upstream commit:`
  header, cross-checked against `openwrt/mt76` source) and replaced with
  three new, narrower compat patches (`373`/`374` in mac80211, a new local
  `901` in mt76) found by actually attempting the build, not guessed
  upfront. Full writeup: `docs/e8450-ppe-validation.md`, "mt76 upstream pin
  bump — executed".
- **Priority 1 acceptance criteria now have definitive answers**, not
  pending: `999-wed-14` (found and fixed after this doc was written) root-
  causes and fixes the "5 GHz traffic survives controlled SER" ring-desync
  failure mode. But full recovery under active traffic is now **confirmed
  not fixable from this host's source** - the MT7915 MCU firmware itself
  never acknowledges a command during full-reset recovery, independently
  confirmed by both a recovered prior investigation and this session's own
  testing. AWG/roam/WAN-renumber gates below remain genuinely open (need
  operator-driven physical tests), but the SER gate is closed as "won't
  fix without UART/firmware access", not "pending".
- `999-wed-13` (Priority 1, Candidate B) had a real bug this doc doesn't
  mention: it used the vendor's NETSYSv2+ PSE port formula unmodified,
  which computes the wrong register on NETSYSv1 - it compiled and ran but
  never actually gated WDMA ingress. Fixed in place.
- QoS/AQM (Priority-adjacent, tracked separately) is now at `qos-13`; see
  `docs/netsys-qos-port-investigation.md` for the byte-accurate,
  flow-aware occupancy AQM and the confirmed-dead dual-scheduler/HW-ATF
  findings.


## Original pre-backport baseline

- Kernel: `6.12.94`.
- mt76 source pin: `2026.03.19~39c960c3`; local Wi-Fi package release `r3`.
- Software and hardware flow offload: enabled (`1/1`).
- MT7915 WED: enabled; boot log reports `attaching wed device 0 version 1`.
- PPE: active `BND` entries with nonzero counters observed.
- MT7615 2.4 GHz currently carries the associated stations; MT7915 5 GHz had no associated station during the live poll.
- CPU temperature: approximately `60.7 C`; memory headroom is ample.
- One `mtk_soc_eth` TX queue 3 watchdog timeout occurred during the current boot, followed by WAN link renegotiation. No PPE/WED/MCU error was logged. Treat this as a diagnostic lead, not a confirmed root cause.

## Current deployed milestone — PPE cache-lock image

- Image: `openwrt-mediatek-mt7622-linksys_e8450-ubi-squashfs-sysupgrade.itb`.
- Image SHA-256: `d02eef873f80362dcac8175653caeb222c0c3f4f87659cbf0cb3f01199fc9b95`.
- Kernel: `6.12.94`; target: `mediatek/mt7622`; rootfs: SquashFS/UBI.
- mt76 packages: `2026.06.23~2dd6e4c8-r4`.
- Active test changes: PPE preserved-cache-line lock, WED-v1 WDMA gating during SER, MT7915 PLE/RIOC L1-SER detection, WED-v1 RX recovery and queue diagnostics (`914-917`), PCIe FTS fix, NAND ECC error handling, mt76 patches `901-910`, and mac80211 AQL compatibility.
- Live configuration: software and hardware flow offload both `1`; WED enabled; WAN up.
- The test client `192.168.1.6` routes Internet traffic through `192.168.1.1`. Its existing AWG UDP flow is visible in PPE as the long-lived `:51821` NAT flow.
- Post-flash smoke testing retained SSH/tunnel reachability, 0% router-ping
  loss, equal WED TX CIDX/DIDX, zero calculated queue occupancy, and no new
  PPE/WED/SER/watchdog/oops errors.
- The final image booted both radios; WED attached as version 1 and the 5 GHz
  AP completed DFS CAC successfully. No 5 GHz station associated during the
  final smoke window, so 5 GHz traffic and controlled SER validation remain
  pending.
- Twenty routed IPv4 and twenty routed IPv6 HTTPS flows completed. One hundred
  bridged ICMP packets to an active 2.4 GHz station completed with 0% loss.
- The final configuration matches the live package set: mt76
  `2026.06.23~2dd6e4c8-r4`, `qdma-shaper`, `sqm-scripts`, CAKE, and `tc-tiny`;
  Rust autorate is excluded. A guard prevents a retained Rust service from
  crash-looping when its binary is absent.
- The cache-lock, long-duration flow churn, throughput comparison,
  WAN-renumber, Wi-Fi-roam, and controlled-SER gates remain open.

## Hardware capability audit — remote probe

### Cryptography and entropy

- MT7622 CPU reports ARMv8 `aes`, `pmull`, `sha1`, and `sha2` extensions.
- `/proc/crypto` selects ARM64 accelerated implementations: `aes-arm64`,
  AES-CE modes, `ghash`, `sha256-arm64`, and `sha512-arm64`; self-tests pass.
- The MT7622 TRNG is already active through `mtk_rng` at `1020f000.rng`.
  `rng_current=1020f000.rng`, quality `900`, `/dev/hwrng` exists, and
  `urngd` is running.
- No MT7622 EIP97/HACC crypto node or driver is present. EIP97 nodes in this
  tree belong to MT7981/MT7986/MT7988-family devices; porting one would not
  connect to this board's silicon.
- WireGuard/AWG is terminated by the test client, not the router. The router
  is forwarding/NATing the encrypted UDP flow, so adding router-side
  ChaCha20/Poly1305 acceleration would not improve the current path.
- If WireGuard is ever terminated on the router, enable the AArch64
  ChaCha20/Poly1305 NEON packages and benchmark them separately. They are not
  currently selected and are not needed for this deployment.

### PCIe and MT7915

- MT7915 is active at PCIe `5.0 GT/s x1`; root port and endpoint are enabled
  and runtime-active. ASPM L1.1/L1.2 are disabled and endpoint power control
  is forced `on`; leave power tuning unchanged while WED/SER is under test.
- The local source contained the upstream-fixed precedence bug
  `((x) & 0xff << 8)` in `PCIE_FTS_NUM_L0(x)`. The driver writes `0x50`, but
  the buggy expression evaluates to zero. Upstream
  [`282305d7e9c0`](https://github.com/torvalds/linux/commit/282305d7e9c0)
  replaces it with `FIELD_PREP`; included locally as
  `911-pcie-mediatek-fix-fts-num-l0.patch`.

### SPI-NAND and ECC

- Winbond SPI-NAND is `128 MiB`, with `1020/1020` good PEBs, zero bad or
  corrupted PEBs, maximum erase count `19`, and MTK ECC strength `4 bits per
  512 bytes`.
- The local ECC driver ignored ECC-idle timeout results and
  `clk_prepare_enable()` failure. Both upstream fixes are now included:
  [`16f7ec8d5dc1`](https://github.com/torvalds/linux/commit/16f7ec8d5dc1)
  as `912-mtk-ecc-stop-on-idle-timeout.patch`, and
  [`82d9a2b45b17`](https://github.com/torvalds/linux/commit/82d9a2b45b17)
  as `913-mtk-ecc-handle-clock-enable-failure.patch`.
  They are reliability backports, not throughput changes.

### CPU, thermal, USB, and storage

- `mtk-cpufreq` exposes `437.5 MHz` through `1.35 GHz`; current governor is
  `ondemand`, with the CPU at `1.2625 GHz` during the probe.
- CPU thermal zone was `59.2 C`; no thermal throttling evidence appeared.
- xHCI is present but has no attached USB device; no USB backport has a current
  payoff.
- `ubi0` has eight volumes, zero bad PEBs, and no ECC correction/error log
  entries. NAND ECC fixes remain worthwhile for future fault handling.

### Audit priority

1. [x] Backport PCIe FTS `FIELD_PREP` fix; kernel build passed and post-flash MT7915 PCIe link is active at `5.0 GT/s x1`. Long-duration link/WED validation remains pending.
2. [x] Backport both MTK ECC error-path fixes; kernel build passed and post-flash UBI attach is healthy (`1020` total/good PEBs, `0` bad). Repeated read/write/upgrade validation remains pending.
3. [ ] Optionally A/B `schedutil` versus `ondemand` under CAKE and PPE load;
   this is a runtime tuning experiment, not a source backport.

4. [ ] Do not pursue an EIP97/HACC port for MT7622 without a board-specific
   crypto hardware node and register documentation.

- The three patches are now included in the flashed image; the router rebooted
  successfully and returned to SSH. Runtime stress validation remains pending.

### Cacheline audit follow-up

- The original SDK/cacheline branch (`bece6d0357`) staged `mtk_eth`
  hot/cold splitting; `6b593414d3` closed cycle 2 after measuring the
  `mtk_tx_ring` writer split.
- Historical measurements at approximately 1 GbE showed no measurable
  benefit: TX L1D refills were effectively flat (`2.48` vs `2.53 M/s`),
  CPU/softirq percentages were unchanged, and throughput already had
  substantial headroom. The original audit therefore shelved further
  struct reorganization.
- The current branch is not at that audit's source state. Current `struct
  mtk_eth` is `3456` bytes because QDMA/PPE fields were added; the old
  `mtk_eth` hot/cold patch fails one hunk when applied to the current
  source and must not be copied unchanged.
- The current production test has hardware flow offload enabled, so
  offloaded packets bypass most CPU Ethernet/PPE fast paths. That makes a
  cacheline optimization less likely to matter, not more.
- Live cache topology: 64-byte lines, private L1 caches, shared L2 across
  CPUs 0-1; Ethernet IRQs are split across CPUs 0 and 1. The router has
  the `armv8_cortex_a53` perf event source but no `perf` userspace package
  and no CCI PMU event source in the current image.
- [ ] Do not reintroduce the old struct split until an A/B test with
  `flow_offloading=0/0`, CPU slow-path traffic, and perf counters shows
  cache refills or CPU time are limiting. The historical result is a
  strong no-go for a blind port.
- [ ] The old per-object `-O2` datapath patch remains a separate,
  potentially measurable experiment; it is not equivalent to the
  cacheline split and was not isolated in the historical cycle-1 result.

## Completed or already present

- [x] MediaTek PPE hardware flow offload validated.
- [x] MT76 fixes backported locally:
  - `901`: wake MT7915/MT7996 TX queues after SER with no active interfaces.
  - `902`: serialize MT7915 WCID-mask teardown.
  - `903`: correct MT7915 monitor RX-header translation register.
  - `904`: clamp unsupported MT7915 beamforming NSS.
  - `905`: avoid MT7615 NULL-station rate-path dereference.
- [x] PPE TCP/UDP aging fix: UDP/TCP aging `12/7 -> 30/30`.
- [x] Bridged flow offload path with bridge-netfilter integration.
- [x] QDMA/PPE shaping experiments and occupancy-driven CAKE eviction recorded separately in `docs/netsys-qos-port-investigation.md` and `docs/e8450-ppe-validation.md`.
- [x] Local source already contains PPE MTU initialization, EEE support, multi-queue TX reset, PSE reset removal, PPE ingress-device guard, and DSA metadata teardown protection. Do not duplicate those upstream changes.

## Priority 1: WED-v1 SER containment

### Candidate A — upstream MT7915 PLE/RIOC recovery

- [x] Backport [`af601a725f01`](https://github.com/openwrt/mt76/commit/af601a725f01). Implemented locally as `package/kernel/mt76/patches/906-mt7915-trigger-l1-ser-on-ple-hang.patch`; package build passed.
- Purpose: detect the MT7915 PLE MDP/RIOC hang and trigger one L1 SER per new error.
- Risk: SER/WED-v1 recovery has previously been capable of locking the AXI fabric.
- Validation: disposable image, 5 GHz client attached, monitor SER messages, WED state, PPE bindings, WAN reachability, and pstore after recovery.

### Candidate B — vendor WED WDMA gating

- [x] Backport [`999-wed-13`](https://raw.githubusercontent.com/mediatek/mtk-openwrt-feeds/main/25.12/files/target/linux/mediatek/patches-6.12/999-wed-13-net-ethernet-mtk_wed-add-WDMA-disable-flow-to-WiFi-L.patch). Implemented locally as `target/linux/mediatek/patches-6.12/999-wed-13-mtk_wed-disable-wdma-during-ser.patch`; kernel build passed.
- Purpose: disable the PSE WDMA port before `mtk_wed_reset_dma()` and re-enable it after WED startup, preventing incomplete packets entering PSE during Wi-Fi L1 SER.
- Applicability: specifically matches the E8450 WED-v1/PSE path.
- Validation: test separately from `af601`, then test the combined image.

Acceptance for Priority 1:

- [x] WED still attaches as version 1 after boot.
- [ ] 5 GHz traffic survives controlled L1 SER or a reproducible firmware recovery event.
- [ ] No PSE/PPE/WED lock, MCU timeout, AXI hang, or unexpected reboot.
- [ ] PPE/conntrack state remains synchronized in both directions.
- [ ] AWG UDP passes idle/resume, teardown/rebind, WAN-renumber, and Wi-Fi-roam tests.
- [ ] No recurrence of the TX watchdog timeout during the stress window.

Operational restriction: never PCI unbind/rebind MT7915 and never runtime-reload MT7915 with WED enabled. Keep a known-good rollback image and clear pstore evidence only after saving it.

Remaining WED-v1 candidates and hardware-gated exclusions are tracked in
`docs/wed-v1-opportunities.md`.

WED-v1 follow-up implementation status:

- [x] WED-03 rebased as `914-wed-v1-reset-rx-prefetch-after-ser.patch` and
  `916-wed-v1-reset-configured-rx-descriptors.patch`; target kernel build
  passed. Runtime SER/RX-hang validation remains pending.
- [x] Reduced WED-v1 diagnostics added as
  `915-wed-v1-debugfs-queue-state.patch`; it adds `wed0/v1_queue` with raw
  ring indices and calculated queue occupancy. Runtime observation remains
  pending.

- Current flashed WED candidate image:
  `fabf0c1976a216bac072bde359202a145461574c929ce7f65ff71c5a27fe25c7`.
- This image includes the corrected packed WED-WDMA RX CIDX/DIDX diagnostic
  decoding and has passed post-reboot WED/PCIe/NAND/offload smoke checks.
  The station had not re-associated yet during the immediate post-flash poll.

### 5 GHz smoke test before packed-RX diagnostic correction

- Station `d2:29:f6:28:f9:40` associated on `wl1-ap0`, authorized and
  authenticated. Signal averaged `-71 dBm`; rates were approximately
  `275.2/292.5 Mbit/s` RX/TX at 40 MHz HE NSS2.
- 100 ICMP packets to `192.168.1.220`: 100/100 received, 0% loss,
  `22.481 ms` average RTT, `374.352 ms` maximum RTT.
- The paired AWG PPE binding advanced from `1,148` to `3,613` packets and
  from `381,548` to `1,219,286` bytes during the traffic window.
- WED TX CIDX/DIDX stayed equal. Raw hardware WDMA RX low indices differed by
  one (`CIDX=0x21c`, `DIDX=0x21d`), consistent with no occupied RX entries.
- No new PPE, WED, SER, watchdog, timeout, BUG, or oops messages appeared.

### Close-range retry investigation

- The corrected image kept the station associated through sustained AWG
  traffic. Latest sample: `10,389` TX packets, `1,236` retries (`11.9%`),
  average signal `-69 dBm`.
- A 200-packet wired-to-5 GHz ICMP interval returned 0% loss, with
  `210.729 ms` average and `2,811.056 ms` maximum RTT.
- The interval ended at `13,031` TX packets and `1,481` retries (`10.4%`
  interval delta); signal averaged `-73 dBm`, with HE40/NSS2 rates of
  `275.2/325.0 Mbit/s`.
- Channel 52 busy time was only `0.68%`; all WED queues reported `QCNT=0`
  and no WED/SER/PPE/watchdog/timeout errors appeared.
- Current leading hypothesis after the weak-signal run was client/AP RF path
  or behavior, not WED queue blockage.
- [x] Strong-signal A/B completed with WG disabled and the client within
  approximately 5 feet of the router, with no wall.

### Isolated close-range no-WireGuard comparison

- Signal was `-44/-46 dBm`, HE40/NSS2, MCS11, with approximately
  `541.6/573.5 Mbit/s` TX/RX rates.
- During the isolated 200-packet interval, all packets returned and the
  cumulative retry change was only `2 / 1,642` TX packets (`0.12%`).
- The subsequent strong-signal interval added `31 / 2,646` retries (`1.17%`);
  station pings were `4.274 ms` average and `9.515 ms` maximum.
- Channel 52 remained lightly occupied and all WED queues reported `QCNT=0`.
  No WED, SER, PPE, watchdog, timeout, BUG, or oops messages appeared.
- This materially separates the high-retry result from WG/tunnel traffic:
  disabling WG and improving RSSI reduced retries from roughly `10-16%` to
  approximately `0.1-1.2%`. A non-DFS channel A/B remains optional.

## Priority 2: Refresh mt76 rather than accumulating cherry-picks

- [x] Build a controlled mt76 refresh from the OpenWrt June 23 pin. July 1 was rejected because it adds unrelated MT7986+ HW ATF code requiring a missing mac80211 callback.
  - OpenWrt update commit: [`a0c5a58123fd`](https://github.com/openwrt/openwrt/commit/a0c5a58123fd).
  - Source: `2dd6e4c8892f59b7943ee163afd6ced881bfb31b`.
  - Mirror hash: `9cd490cc08ccbcdd1476edfefd689d01ba5ef43a4a0cc7e23f13ac3a1e1522c5`.
- [x] Retain local `901-906`; all applied cleanly to the June source point.
- [x] Add the mac80211 compatibility backport `package/kernel/mac80211/patches/subsys/372-mac80211-add-aql-pending-api.patch` for the PS buffering API.
- [x] Rebuild and replace all MT7615/MT7915/common mt76 package artifacts.

Alternative, broader track:

- [ ] Evaluate current mt76 HEAD [`c5a3bd91aa73`](https://github.com/openwrt/mt76/commit/c5a3bd91aa73), 241 commits ahead of the local March pin.
- [ ] Remove local patches already included upstream instead of applying duplicates.
- [ ] Require a complete Wi-Fi regression pass; do not assume a source bump is behavior-neutral.

## Priority 3: Low-risk MT7915/mt76 correctness fixes

These patches are now included in the June mt76 refresh and built against kernel `6.12.94`; runtime validation remains pending.

- [x] [`a2c3c698e487`](https://github.com/openwrt/mt76/commit/a2c3c698e487): guard missing HE capability pointers before dereference. Local patch: `907-mt7915-guard-he-capability-lookups.patch`.
- [x] [`8f1dae620e09`](https://github.com/openwrt/mt76/commit/8f1dae620e09): unlink TWT flows when firmware rejects setup; prevents TWT list corruption. Local patch: `908-mt7915-unlink-rejected-twt-flow.patch`.
- [x] [`c52a151151c1`](https://github.com/openwrt/mt76/commit/c52a151151c1): unwind VIF/WCID/monitor state after failed interface creation. Local patch: `909-mt7915-unwind-interface-failure-state.patch`.
- [x] [`04017929f632`](https://github.com/openwrt/mt76/commit/04017929f632): fix out-of-bounds MMIO copy reads/writes. Local patch: `910-mt76-fix-mmio-copy-bounds.patch`.
- [x] [`748311faa56c`](https://github.com/openwrt/mt76/commit/748311faa56c): prevent MT7915 TX-retry counter underflow. Lower value with WED enabled because it affects the non-WED path; included by the June source refresh.

## Priority 4: Hardware-managed power-save buffering

Series:

1. [x] [`9a46d8d21d2a`](https://github.com/openwrt/mt76/commit/9a46d8d21d2a): generic HW-managed TIM/PS buffering; included by the June source refresh and completed with the local AQL API compatibility patch.
2. [x] [`9e613fb007f5`](https://github.com/openwrt/mt76/commit/9e613fb007f5): consume MT7915 MCU PS-sync events; included by the June source refresh.
3. [x] [`f8b59ca3be7b`](https://github.com/openwrt/mt76/commit/f8b59ca3be7b): avoid pinning an undrainable PS station in the scheduler; included by the June source refresh.

The June source refresh now handles `MCU_EXT_EVENT_PS_SYNC`; runtime validation remains pending. The series is relevant to sleeping 5 GHz MT7915 clients. It is not currently a 2.4 GHz fix; no upstream equivalent exists for the integrated MT7615 path.

Validation:

- [ ] Associate a sleeping/power-saving client to 5 GHz.
- [ ] Verify TIM/beacon behavior, downlink delivery, wake-up latency, and no starvation of other stations.
- [ ] Test with multiple stations and with one nonresponsive sleeping station.

## Priority 5: Conditional PPE cache protection

- [x] Stage vendor [`999-ppe-14`](https://raw.githubusercontent.com/mediatek/mtk-openwrt-feeds/main/25.12/files/target/linux/mediatek/patches-6.12/999-ppe-14-mtk_ppe-add-PPE-cache-preserved-line-lock.patch). Implemented locally as `target/linux/mediatek/patches-6.12/999-ppe-14-mtk_ppe-add-PPE-cache-preserved-line-lock.patch`; adapted diagnostics to this tree's existing `ppe->dirname`; kernel build passed. Runtime validation is underway.
- Purpose: reserve the PPE preserved cache line during cache invalidation; the implementation handles NETSYSv1 as well as newer generations.
- Risk: large vendor-only change to central PPE cache behavior with undocumented register semantics.
- Trigger: repeated PPE bind/unbind corruption, flow churn failure, or reset-induced cache anomalies.

### PPE cache-lock test image deployment

- [x] Full sysupgrade image assembled and signature checked.
- [x] Disposable image flashed with `sysupgrade -c`; router returned to SSH.
- Image includes kernel `6.12.94`, WED-v1 gating, PPE cache-line locking, mt76 `2026.06.23~2dd6e4c8-r4`, and local mt76 patches `901-910`.
- Initial live health: WED enabled and attached as version 1; flow offload remains `1/1`; PPE shows paired AWG IPv4 `BND` entries with advancing packet counters; memory available approximately `387 MiB`; CPU temperature `61.1 C`; no PPE/WED/SER/BUG/oops errors in the initial log scan.
- [ ] Runtime cache-lock acceptance: routed/bridged offload, flow churn, throughput, latency, and reset/SER behavior.

### Initial live flow test

- [x] Ran 30 short routed HTTPS flows from the test client through the router; router ping remained at 0% loss.
- [x] Ran a throttled concurrent routed-download exercise; the harness ended it at 60 seconds while transfers were still progressing. Treat as partial stress, not a pass/fail result.
- [x] After the exercise: router uptime remained continuous, WAN stayed up, WED TX CIDX/DIDX remained equal, and no new PPE/WED/SER/watchdog/oops errors appeared.
- [x] PPE retained an active AWG `BND` flow; its counters advanced from `3,051` to `4,867` packets during observation.

### Remote-only validation while away from the LAN

- [x] Confirmed the test client routes IPv4 through `192.168.1.1`; IPv6 has a
  router RA/default route and was exercised separately.
- [x] Completed 40 routed IPv4 HTTPS flows and 40 routed IPv6 HTTPS flows.
- [x] Router remained reachable during churn; repeated ICMP probes had 0%
  loss, and a post-test external HTTPS request succeeded.
- [x] Ran four concurrent throttled 10 MiB routed downloads. The harness
  stopped them at 90 seconds while transfers were progressing; this is a
  sustained-traffic health observation, not a completed throughput benchmark.
- [x] At one hour uptime, WAN remained up, WED TX CIDX/DIDX remained equal,
  and no new PPE/WED/SER/watchdog/oops/timeout messages appeared.
- [x] The AWG PPE binding remained paired and active; counters advanced to
  inbound `11,625` packets / `2,884,049` bytes and outbound `31,068` packets /
  `25,619,935` bytes.
- [ ] Long-duration cache churn and full routed/bridged throughput comparison.

Validation:

- [ ] Compare routed IPv4/IPv6 offload, bridge offload, NAT, flow churn, and PPE counters against baseline.
- [ ] Confirm no throughput, latency, or bind-rate regression.

## Priority 6: Long-term kernel track

- [ ] Start a separate kernel migration branch to OpenWrt's current Mediatek kernel baseline, currently 6.18: [target Makefile](https://raw.githubusercontent.com/openwrt/openwrt/master/target/linux/mediatek/Makefile), [MT7622 config](https://raw.githubusercontent.com/openwrt/openwrt/master/target/linux/mediatek/mt7622/config-6.18).
- [ ] Rebase custom PPE/QDMA/WED patches deliberately; do not hand-cherry-pick unrelated 6.18 APIs into the 6.12 production branch.
- [ ] Revalidate boot, NAND/UBI, WED attach, PPE offload, bridge flowtable, QDMA controls, Wi-Fi, and rollback.

## Explicitly excluded

- WED-v2 reserved-buffer change [`c0ef04232f9f`](https://github.com/torvalds/linux/commit/c0ef04232f9f): hardware is WED-v1.
- WED TX-free `M_DONE` change [`c73ffc4a2e84`](https://github.com/openwrt/mt76/commit/c73ffc4a2e84): behavior is for WED-v3.
- RXDMAD_C/RRO fixes: target newer MT7996-style RRO queues, not this MT7915 WED-v1 path.
- Second-adie MT7915 clock fix: MT7986-specific.
- MT7915 HW ATF: MT7986+-specific.
- Vendor roaming-handler series: unrelated to this router's WAN/WED problem.
- Porting WED to the integrated MT7622/MT7615 2.4 GHz radio: no upstream precedent; requires new WDMA rings, token accounting, attach/detach, and reset support with uncertain silicon capability.
- New MT7915 firmware hunting: recent mt76 firmware updates target MT798x/MT799x; no useful newer MT7915 payload was identified.

## Per-image test checklist

- [ ] Save current image and configuration rollback path.
- [ ] Record kernel, package versions, WED parameter, PPE bindings, temperatures, and link states.
- [ ] Boot image; verify both radios initialize and WED reports version 1.
- [ ] Associate a 5 GHz client so the WED path is exercised.
- [ ] Run routed IPv4/IPv6 throughput and latency tests.
- [ ] Run bridged wired-to-5 GHz traffic and verify offload counters.
- [ ] Run 2.4 GHz multi-client fairness and power-save tests.
- [ ] Exercise long-lived UDP/AWG idle/resume, teardown/rebind, WAN renewal/renumber, and Wi-Fi roam.
- [ ] Monitor `logread` for PPE, WED, MCU, SER, timeout, reset, BUG, and oops messages.
- [ ] Record TX watchdog events, PPE `BND` counters, WED `txinfo`, memory, temperature, and CPU load.
- [ ] Keep candidate only if it improves or preserves behavior without a new recovery risk.
