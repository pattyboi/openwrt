# e8450: wifi-egress download shaping — handoff (2026-09-04)

## Status summary

The router now runs both radios at the US-legal ceiling (30 dBm) on freshly
surveyed clean channels (2.4G ch6 HT20, 5G ch157 HE40), with far-field
measured gains (+4 dB 5G at the S23's fixed spot). The remaining open QoS
problem is **download-direction bufferbloat to wifi clients**: PPE
offloading bypasses the ifb4wan CAKE, and the offloaded WAN→wifi path
(PPE → WDMA → WED) has no NETSYSv1 hardware shaper.

The plan below makes that gap closeable **without hardware**: exclude wlan
egress from the flowtable so wifi-bound downloads take the CPU path the
existing CAKE already governs. Feasible because ISP download (~75 Mbps) is
~10x below MT7622 software-forwarding capacity, so not offloading wifi
downloads costs no throughput and little CPU.

Next action: **Phase 0 baseline** (download bufferbloat to the S23 on
ch157 @ 30 dBm, current state), then Phase 1 selective-offload rule.

## Why (benefit)

- docs/netsys-qos-port-investigation.md §33-35: "real, large, reproducible
  download-direction latency problem"; §16.8 mode B shows PPE-offloaded
  traffic is unshaped (CAKE sees only software-path flows).
- `files/etc/config/firewall`: `flow_offloading=1` + `flow_offloading_hw=1`
  (global) → established download flows never reach the SQM qdisc.
- The affected population is mostly wifi clients (8x 2.4G stations + the
  S23 on 5G). Download AQM for that population is the last unsolved piece
  of the latency program.
- Side benefit already banked: factory power raise moved weak clients out
  of the -73..-81 dBm retry/fallback band documented in
  wifi-cpu-and-stability-investigation.md (S23 measured -65 dBm at stock
  ceiling vs -61 at 30 dBm from its fixed spot).

## Why not shape the offloaded path in hardware

- Offloaded WAN→wifi download = PPE → WDMA → WED v1 → mt7915 (validated in
  E8450-hardware-software-reference.md) — outside the QDMA TX queues
  (0-15) that qdma-shaper/q7 owns.
- NETSYSv1 has ONE functional scheduler; a second slot (TX_SEL=1) and
  hardware airtime fairness are wired but non-enforcing
  (netsys-qos-port-investigation.md top summary). Download shaping in the
  ImmortalWrt `luci-app-eqos-mtk` reference runs on 64-queue / 4-scheduler
  MT798x silicon (its §17) — not portable to MT7622.
- WDMA-side rate fields: not found in the QDMA audit; unknown = gate A
  from netsys-qos §7 stays open. Treat as likely-impossible; revisit only
  if Phase 2 (below) disappoints.

## Mechanism: selective offload

- Keep hw offload for eth/wan traffic (upload q7 shaping keeps working).
- Exclude wlan egress from the flowtable: nft rule matching
  `oifname wl0-ap0` / `oifname wl1-ap0` must NOT `flow add @ft`.
- Non-offloaded wifi-bound downloads then traverse the existing SQM path
  (layer_cake on ifb4wan per files/etc/config/sqm) — the proven §16.8
  mode-A CAKE control, restored for the wifi population with no qdisc work.
- CPU cost at ≤75 Mbps ≪ the ~900 Mbps software-forwarding capacity
  measured on this box (cacheline-audit / reference doc).

## Current box state (2026-09-04, verified)

- Stock-ish OpenWrt 25.12 (apk) kernel 6.12.94 (root@DietPi build
  2026-09-01); access `ssh root@192.168.1.1`, pw `Braxtonb112218!` (eth0
  direct, ARP 80:69:1a:1e:85:83). WAN-side: Netgear topology history — see
  e8450-router-access memory note; verify reachability first.
- Country US. radio0 ch6 HT20 txpower 30; radio1 ch157 HE40 txpower 30
  (uci). 8x 2.4G clients + S23 (d2:29:f6:28:f9:40) on 5G.
- **FACTORY VOLUME MODIFIED** (first time ever): both radio eeproms raised
  to legal max (2.4G chain targets 0x26→0x2A @0x58+c*6; 5G UNII-3 group-7
  0x26→0x2B @0x5352+c*12). Pristine backup on box:
  `/root/factory-pristine-20260904.bin` AND in repo
  `.recall/router-probes/2026-09-04-factory-dump/factory-ubi0_1.bin`
  (md5 b23391d1db51f9298547b1595c8aef44). Live image md5
  2b8a9e0dc98f3d02664102e4e778cb36 (`factory-24g-final.bin`).
- Tooling: `scripts/e8450/eeprom.sh` (view/check/set/apply; `apply stock`
  reverts; `apply max30` reproduces live). Full field map:
  `.recall/router-probes/2026-09-04-factory-dump/EEPROM-MAP.md` (includes
  per-device cal offsets flagged do-not-touch, power model
  `max_power = roundup((target+delta+12)/2)`, 0.5 dBm/byte).
- Channel survey dumps + RSSI A/B logs + S23 far-field results: same
  probe dir (README.md).
- eeprom.sh verified under busybox on the router and GNU od on the host;
  `apply` reproduces the flashed image byte-for-byte.

## The plan

### Phase 0 — baseline (do first)
Reproduce netsys-qos §33-35 download test with the S23 at its fixed spot,
current state (offloaded, unshaped for wifi downloads):
- saturating download to the S23 (wifi leg) while pinging from a WIRED
  client (192.168.1.6) to WAN + to the S23's IP;
- record p50/p95/p99/max RTT, loss, retry counts (`iw dev wl1-ap0 station
  dump`), PPE/WED queue state, CPU;
- also ping FROM the router to WAN for a clean reference.
Success metric: a defensible "current damage" number to A/B against.

### Phase 1 — selective offload rule
nftables: add flowtable offload rules that exclude wlan egress
(`oifname != "wl0-ap0"` and `!= "wl1-ap0"` on the `flow add @ft` rules —
confirm exact syntax on the running nft/6.12 stack), keep everything else
unchanged.
Verify on box: established wifi-bound downloads do NOT create PPE entries
(`ppe0` debugfs / flow count), while eth downloads still do; CPU during a
wifi download stays sane; no regression to upload q7 shaping.

### Phase 2 — A/B (acceptance-criteria pattern from §16.8)
- Mode A: CAKE, offload off (control, already characterized)
- Mode B: offload on, unshaped (current state, Phase 0 numbers)
- Mode D: selective offload (eth offloaded, wifi downloads → CAKE)
Throughput, p50/p95/p99/max, loss/ECN, CPU, PPE/WED queues; second wired
client for fairness. Success: D keeps wifi download near ISP rate with
latency/loss acceptably close to or better than A — i.e., the §33-35
download problem gone while eth stays offloaded.

### Phase 3 — only if D disappoints
WDMA register audit for rate-control fields (extend the netsys register-map
methodology; gate A in netsys-qos §7). Prior low. Also possible: per-station
fairness needs radio-side airtime (non-enforcing on this silicon) — CAKE
per-host fairness at the router queue is the software substitute; the power
raise already shrinks the low-MCS population.

## Risks / unknowns

- Flowtable oif-exclusion must be verified EFFECTIVE with PPE on 6.12 —
  config alone is not proof; check PPE entry creation on a live flow.
- NAS→wifi LAN flows must not be swept in (flowtable scope is
  wan-forwarded; confirm no lan→lan offload exists in current config).
- CAKE per-host fairness cannot fix medium-level airtime waste by a far
  low-MCS station (no HW airtime fairness) — power raise mitigates, does
  not eliminate.
- Wifi egress CAKE + WED/mt7915 TX interplay: host TX to wlan with WED
  enabled goes via the mt7915 driver path; verify no double-queue/drop
  behavior when the qdisc is attached to wl*-ap0.

## Operating rules (hard locks — CLAUDE.md is source of truth)

- NEVER runtime-load mt7915e; NEVER PCI unbind/rebind (AXI fabric lock).
  Eeprom reads happen at driver probe — any factory write REQUIRES reboot.
- After any panic: save then `rm /sys/fs/pstore/dmesg-*` or u-boot boots
  the recovery volume forever.
- Factory volume writes: backup first (`dd if=/dev/ubi0_1 of=/root/...`
  bs=126976 count=5), `ubiupdatevol /dev/ubi0_1 file`, reboot. Revert =
  pristine dump via same path.
- Verify router life from a second path (eth0 vs wifi) — IP/reachability
  has drifted before; check the e8450-router-access memory note.

## Cross-references

- docs/netsys-qos-port-investigation.md (§16 q7 shaper, §17 eqos review,
  §33-35 download problem, gates in §7)
- docs/wifi-cpu-and-stability-investigation.md (weak-signal/retry record)
- docs/wed-v1-opportunities.md, docs/e8450-ppe-validation.md
- .recall/router-probes/2026-09-04-factory-dump/ (map, dumps, A/B logs)
- scripts/e8450/eeprom.sh
- `files/etc/config/{firewall,sqm,sqm-autorate}`, `files/etc/nftables.d/`
- commit history: 939ee75e68..9aac9ce12b on e8450-deployed-minimal
  (probe record ca104806ac, tool+map 9aac9ce12b)
