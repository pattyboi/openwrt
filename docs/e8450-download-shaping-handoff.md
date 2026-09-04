# e8450: wifi-egress download shaping — handoff (2026-09-04, revised)

## STATUS UPDATE (same day, later session): original plan superseded

**The severe symptom this doc was written to fix is already resolved —
by a different mechanism than this doc proposed.** Deep-research pass
confirmed: `docs/netsys-qos-port-investigation.md` §36-38 (all dated
2026-09-04, committed to `e8450-deployed-minimal` at 08:40 — before this
handoff was even written) root-caused the download-direction bufferbloat
as `sqm-autorate-rust`'s missing `.min(base_rate)` clamp: the shaped
ceiling drifted to 68-69 Mbit while real sustained capacity is ~6-10
Mbit/s (router-side speedtest, §38.2), so excess traffic queued
**upstream of the router** where CAKE structurally cannot see or manage
it. Fixed with a one-line patch, verified live: post-fix, genuine
saturating download shows real bounded CAKE backlog and ping avg 26.9 ms
/ max 92.1 ms — down from pre-fix max 2153 ms. This has nothing to do
with PPE/WDMA/WED offload routing.

**This doc's original citation was a misreading.** §16.8's "download
remains a separate IFB/CAKE question because q7 cannot shape WAN
ingress" says the upload-queue shaper can't help ingress — it does NOT
say offloaded flows bypass CAKE. That claim was never actually tested
in this project prior to today's deep-research pass (below).

**What's still genuinely open, downgraded to low-priority:** all of
§31-38's validation traffic came from the wired build workstation
(192.168.1.6 — confirmed via `iperf3 -c`/`iw` grep across those
sections). None of it tested an actual wifi client. **Definitive
source evidence (corrected from an earlier draft of this doc — see
below):** `mtk_flow_set_output_device()` (`mtk_ppe_offload.c:281-384`)
calls `mtk_foe_entry_set_wdma()` for any flow whose output device
resolves to a WED-connected wifi interface, and that function
(`mtk_ppe.c:600-635`, v1/`default` case) sets `MTK_FOE_IB2_WDMA_WINFO` +
packs BSS/WCID/ring into `l2->vlan2` — it never touches `IB2_QID` or
sets `IB2_PSE_QOS`. Eth/wan-bound flows instead call
`mtk_foe_entry_set_queue()` (`mtk_ppe.c:637-653`), which sets exactly
those two fields — the ones `qdma-shaper`/`qdma_aqm` watch. These two
functions write mutually exclusive bitfields; a flow takes one path or
the other. **This means WLAN-bound PPE-offloaded flows never carry a
QDMA QID at all — confirmed at the bitfield level, not inferred from
enum/port-topology.** So whether the (now-correct) CAKE ceiling
actually protects a real wifi client's download, or whether that
traffic bypasses CAKE entirely the same way §13.4 proved for the
software TX selector, remains untested — but the mechanism by which it
*could* bypass is now solidly confirmed, independent of any A/B test.

## New finding: PSE per-port buffer thresholds (unexplored by §1-38)

**Correction to an earlier draft of this doc:** the original claim
here cited `PSE_WDMA0_PORT`/`PSE_WDMA1_PORT` (`enum mtk_pse_port`,
`mtk_eth_soc.h:904-922`) as the v1 WLAN-egress routing target. Reading
`mtk_flow_set_output_device()` fully shows this is wrong for MT7622:
those enum constants are used only in the `mtk_is_netsys_v2_or_greater()`
branch; **the v1/`else` branch hardcodes `pse_port = 3`**
(`mtk_ppe_offload.c:310-312`), committed via
`mtk_foe_entry_set_pse_port()` → `IB2_DEST_PORT`
(`mtk_ppe.c:441-451`). Whether that raw "3" aligns with this doc's
`PSE_OQ_TH`/`PSE_IQ_REV` register-pairing guess (built from the enum's
ordinal position) is genuinely unknown — the enum's numeric values may
not correspond 1:1 with v1 hardware's actual `DEST_PORT` numbering
outside the v2+ code path that defines them. **The bitfield evidence
above (set_wdma vs set_queue) is the reliable finding; the specific
register-pairing decode below is a hypothesis, not a fact, pending
live readback.**


## Why (benefit) — revised

- The production-impacting bufferbloat is fixed (§36-38). No further
  urgency on that front.
- What remains: confirm or rule out that wifi clients' PPE-offloaded
  downloads bypass CAKE-on-ifb4wan altogether (independent of ceiling
  correctness) — closes a real architectural gap in this project's own
  test coverage, cheaply, with tools already built.
- Side benefit already banked, unaffected by any of this: factory power
  raise moved weak clients out of the -73..-81 dBm retry/fallback band
  documented in wifi-cpu-and-stability-investigation.md (S23 measured
  -65 dBm at stock ceiling vs -61 at 30 dBm from its fixed spot).

## Why not shape the offloaded path in hardware — revised, register-confirmed

Deep-research pass read the actual kernel source (not just doc
narrative) for every candidate register block on the WLAN-egress path:

- **WED (`mtk_wed_regs.h`, both `1020a000`/`1020b000`, full 815-line
  header + live regmap dump via `/sys/kernel/debug/regmap/dummy-wed@…`):
  zero rate/shaper/leaky-bucket/WFQ/WRR/throttle fields anywhere.**
  It's a DMA/buffer-manager/interrupt engine (reset bits, TX/RX buffer
  pools with token IDs, ring descriptors, MIB counters, PCIe/WPDMA
  config). This is a stronger, source-level close of the question this
  doc's original §"gate A" left open — not "likely impossible", now
  **confirmed impossible** by exhaustive register enumeration.
- **There is no separate "WDMA" register block.** No `mtk_wdma.c` exists;
  "WDMA" is WED's own descriptor-format nomenclature
  (`struct mtk_wdma_desc`) for the rings it drives toward the wifi
  device — not a standalone shaping-capable block.
- **QDMA is already exhaustively covered** by this project's own §13-28:
  every plausible AQM/HQoS register hardware-tested; scheduler 1/`TX_SEL`
  confirmed wired-but-dead (§28, 2026-08-31, register-readback +
  15x-over-cap throughput proof); `HRED2`/`fc_th` also dead (§22.9-22.10);
  "no vendor-firmware secret to extract" (§28.5). Nothing new to find
  there.
- **Genuinely new ground: PSE (Packet Switch Engine).** See below.

PSE has its own, never-instrumented register range (`mtk_eth_soc.h:156-173`,
offsets 0x100-0x1ff — same `1b100000.ethernet` MMIO block as QDMA's
0x1800+ range, but a different sub-block; confirmed NOT covered by the
existing `qdma_regs` debugfs, which is hardcoded to the QDMA offset
range only):

```text
PSE_FQFC_CFG1/2   0x100/0x104   free-queue flow control (opaque, no field decode in this driver)
PSE_DROP_CFG      0x108         global drop config
PSE_PPE_DROP(x)   0x110+4x      per-PPE-instance drop config
PSE_IQ_REV(x)     0x140+4(x-1)  per-port INPUT queue reservation (pages), x=1..8, packed 2 ports/register
PSE_OQ_TH(x)      0x160+4(x-1)  per-port OUTPUT queue threshold (pages), same packing
```

Live init values decoded from `mtk_eth_soc.c:5450-5467` (pairing inferred
from register-write order matching the enum sequence — **not yet
verified by register readback, and per the correction above, v1's raw
`DEST_PORT=3` may not even correspond to this enum's ordinal position —
treat every port attribution below as a guess**): register
`PSE_OQ_TH(5) = 0x000f000f` — if the enum-ordinal guess holds, this
covers ports 8-9 (`PSE_WDMA0_PORT`/`PSE_WDMA1_PORT`) — both halves
decode to **15 pages**, matching `PSE_IQ_REV(5) = 0x000e000e` → **14
pages**. If instead v1's real WDMA port is "3" as the source literally
says, the relevant register would be `PSE_OQ_TH(2) = 0x001a000f`
(high 16 bits, odd port) → **26 pages**. `PSE_DROP_PORT` (port 7)
gets `0x1ff` = 511 pages regardless of pairing — an outlier, consistent
with being a sink port. **Only register readback (a debugfs patch) can
resolve which of these is correct.**


**What this is, and isn't:** a per-port shared-buffer occupancy
cap/backpressure threshold — closer to a hardware tail-drop depth limit
than a shaper. No rate control, no AQM sophistication, no ECN, no
per-flow fairness (CAKE has all four; this has none). Lowering
`PSE_OQ_TH` for the WDMA ports would bound worst-case *standing queue
depth* for WLAN-egress traffic at the hardware fabric level — a real,
physically-plausible lever, but:

- **not live-readable today** — no existing debugfs covers this offset
  range; a new patch (mirroring qos-01's approach) would be needed just
  to observe it, before any write is trusted;
- **field-packing/units are inferred from write-order pattern-matching,
  not a TRM or register readback** — exactly the kind of unverified claim
  this project's own methodology (§28's dual-scheduler test, §13's
  Gate A) has repeatedly shown is necessary to hardware-test before
  trusting;
- **shared fabric risk**: PSE serves every port (GDM/ethernet MACs, PPE,
  QDMA, WDMA, drop). A wrong write here risks indiscriminate packet loss
  across all WLAN traffic — beacons, management frames, other
  stations — not just the flows you meant to affect, unlike a QDMA
  per-queue write which is provably isolated (§16.7's soak-test
  acceptance criteria exist precisely because of this class of risk).

**Recommendation: do not act on this without the same gate discipline
applied to every other register in this project.** If pursued: (1) add a
read-only PSE debugfs patch mirroring qos-01, (2) verify the inferred
port-pairing/units via a controlled write+readback (analogous to §28's
scheduler-1 test — pick an idle/test-only port pairing if one exists,
not a live WDMA port, to first prove field semantics without touching
production traffic), (3) only then consider a live WDMA-port adjustment
with the same soak-test rigor as §16.7. This is exploratory and
low-priority given the headline symptom is already fixed — track
separately, do not block on it.

## Mechanism (if Phase 0 finds a real gap)

Only pursue this if Phase 0 (below) actually finds wifi-bound offloaded
downloads bypassing CAKE — do not implement pre-emptively now that the
headline symptom is fixed by the autorate patch.

- Keep hw offload for eth/wan traffic (upload q7 shaping keeps working).
- Exclude wlan egress from the flowtable: nft rule matching
  `oifname wl0-ap0` / `oifname wl1-ap0` must NOT `flow add @ft`.
- Non-offloaded wifi-bound downloads then traverse the existing SQM path
  (layer_cake on ifb4wan per `files/etc/config/sqm`), now correctly
  ceilinged by the §38 autorate fix.
- CPU cost at ~6-10 Mbit/s real sustained capacity (§38.2, not the ~75
  Mbps contracted line) is trivially below the ~900 Mbps software-
  forwarding capacity measured on this box.

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

### Phase 0 — close the real open question (do first, cheap, decisive)
Controlled A/B mirroring §36's own methodology, but with an actual wifi
client (the S23, at its now-measured fixed spot) instead of the wired
workstation every prior test used:
- saturating download **to the S23** (not the router, not 192.168.1.6)
  with `flow_offloading_hw=1` (current default) — watch
  `/sys/kernel/debug/ppe0/entries` for the flow's presence/QID and
  `tc -s qdisc show dev ifb4wan` backlog concurrently, plus ping p50/p95/
  p99/max from a wired client;
- repeat with `flow_offloading_hw=0` (flows forced to CPU/CAKE path) —
  same measurements;
- compare: if CAKE backlog and PPE-entry presence differ meaningfully
  between the two runs for the *same* wifi-bound flow, offload bypass is
  real and Phase 1 is justified. If not, the autorate fix already covers
  wifi clients and this whole thread closes here.
Success metric: a yes/no answer with hardware telemetry, not inference —
matching this project's own evidentiary standard throughout §1-38.

### Phase 1 — selective offload rule (only if Phase 0 confirms a gap)
nftables: add flowtable offload rules that exclude wlan egress
(`oifname != "wl0-ap0"` and `!= "wl1-ap0"` on the `flow add @ft` rules —
confirm exact syntax on the running nft/6.12 stack), keep everything else
unchanged. Verify: wifi-bound downloads stop creating PPE entries while
eth downloads still do; CPU during a wifi download stays sane; no
regression to upload q7 shaping.

### Phase 2 — A/B validation (only if Phase 1 was built)
Mode A: CAKE, offload off (control). Mode B: offload on (current
default). Mode D: selective offload (eth offloaded, wifi downloads →
CAKE). Throughput, p50/p95/p99/max, loss/ECN, CPU, PPE/WED queues;
second wired client for fairness. Success: D matches or beats A for wifi
clients while eth stays offloaded.

### PSE exploratory track (independent, low-priority, own gate sequence)
See "New finding: PSE per-port buffer thresholds" above. Not gated on
Phase 0-2; track separately since it targets standing-queue depth, not
rate — a different, complementary problem to any offload-bypass finding.

## Risks / unknowns

- Phase 0's premise itself is unconfirmed — do not skip straight to
  Phase 1's implementation on the strength of the architectural argument
  alone (the set_wdma/set_queue bitfield split proves it's
  architecturally possible for CAKE to see zero WLAN-bound traffic, not
  that it actually does in practice).
- Flowtable oif-exclusion (if built) must be verified EFFECTIVE with PPE
  on 6.12 — config alone is not proof; check PPE entry creation on a
  live flow.
- NAS→wifi LAN flows must not be swept in (flowtable scope is
  wan-forwarded; confirm no lan→lan offload exists in current config).
- CAKE per-host fairness cannot fix medium-level airtime waste by a far
  low-MCS station (no HW airtime fairness) — power raise mitigates, does
  not eliminate.
- PSE track: field-packing inferred from write-order, not verified by
  readback — treat as a hypothesis, not a fact, until tested per the
  gate sequence above.

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

- docs/netsys-qos-port-investigation.md — §13 (Gate A/QDMA register
  source), §28 (scheduler-1 decisive negative), §36-38 (bufferbloat root
  cause + fix, **read this before assuming any WLAN-offload problem
  exists**)
- docs/wifi-cpu-and-stability-investigation.md (weak-signal/retry record)
- docs/wed-v1-opportunities.md, docs/e8450-ppe-validation.md
- .recall/router-probes/2026-09-04-factory-dump/ (map, dumps, A/B logs)
- scripts/e8450/eeprom.sh
- `files/etc/config/{firewall,sqm,sqm-autorate}`, `files/etc/nftables.d/`
- kernel source (this box's build tree):
  `build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_mt7622/linux-6.12.94/drivers/net/ethernet/mediatek/`
  (`mtk_wed_regs.h`, `mtk_eth_soc.h` PSE definitions)
- commit history: 939ee75e68..9aac9ce12b on e8450-deployed-minimal
  (probe record ca104806ac, tool+map 9aac9ce12b)
