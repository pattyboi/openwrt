# E8450 upstream/vendor roadmap — 2026-09

Scope: Linksys E8450/Belkin RT3200, MT7622BV, NETSYSv1, one PPE, integrated
MT7615 2.4 GHz radio, PCIe MT7915 5 GHz radio, WED-v1.

This supersedes `e8450-upstream-backport-roadmap.md` (closed 2026-09-04) and
`wed-v1-opportunities.md` (closed 2026-09-04). Read those two only for
process history; every item worth carrying forward is repeated here.

## Baseline as of 2026-09-04

- Kernel `6.12.94`; live/flashed build `r33075-4dfd876771`, confirmed booted
  and reachable on the router.
- mt76 source pin: `openwrt/mt76` master `6d1c6a75` (`6d1c6a758a4c0a690ee56cb849387dfa262fdb17`,
  2026-08-04).
- Local kernel/target patches (`target/linux/mediatek/patches-6.12/`):
  PCIe FTS `FIELD_PREP` fix (`911`), MTK ECC idle-timeout + clock-enable
  fixes (`912`/`913`), WED-v1 RX prefetch/descriptor reset + diagnostics
  (`914`-`917`), WED WDMA gating during SER (`999-wed-13`), WED ring-desync
  fix (`999-wed-14`), PPE preserved-cache-line lock (`999-ppe-14`), the
  `qos-01`..`qos-17` QDMA/AQM/PSE-debugfs series (tracked separately, see
  `netsys-qos-port-investigation.md`), MT7622 RX ring doubling (`999-eth-91`),
  and assorted PPE/nftables/xxhash patches predating this roadmap.
- Local mt76 package patches (`package/kernel/mt76/patches/`): `901`
  (connac header compat), `902` (skip empty-queue TX cleanup). Ten prior
  hand-backports (`903`-`910`) were deleted in the August refresh — upstream
  now carries them natively.
- Local mac80211 compat patches (`package/kernel/mac80211/patches/subsys/`):
  `372` (AQL pending API), `373` (STA airtime-weight op), `374` (parameterize
  min-action-size macro), plus upstream MLO patches `370`/`371`/`376`
  unrelated to this fork's work.
- WED-v1 attaches as version 1; PPE hardware flow offload active; both
  radios operational. Known, accepted, unfixable-from-here limitation: a
  controlled full-chip SER/reset under active 5 GHz traffic can leave the
  MT7915 MCU firmware unresponsive (never acknowledges a recovery command);
  `mt7915-ser-watchdog` bounds the resulting outage to ~65 s via auto-reboot.
  Do not reopen this without UART/firmware access — confirmed twice,
  independently, not fixable from host driver source.

## Task 1: mt76 upstream pin bump evaluation (`6d1c6a75` → current)

One month since the last bump — due for a look, following the same
methodology Priority 2 of the old roadmap already established: evaluate
current HEAD, remove local patches already upstreamed instead of
duplicating, require a full build + Wi-Fi regression pass before accepting.

Today's session pulled the first ~40 commits of the `2026-08-04`→`2026-09-04`
window (out of an unknown, likely 150-250+, total — GitHub reported far more
than one page). Sample composition: the large majority target chip families
this router doesn't have (**mt7996, mt7925, mt7921, mt76x02**) — consistent
with this fork's established finding that upstream mt76 churn skews toward
newer silicon. Candidates actually relevant to this board's mt7615/mt7915
hardware, found so far:

- `be5ce79` — mt7615: don't tear down BSS/STA state for monitor vifs.
  Touches the 2.4 GHz driver, but scoped to monitor-vif teardown, which this
  deployment doesn't use in normal AP operation. Likely low value.
- `a57185c` — mt7915: disable RX NAPI when removing the device. Touches the
  5 GHz driver, but only fires on the module-remove path, which the
  project's own hard-lock rules forbid at runtime (never PCI unbind/rebind
  or runtime-reload MT7915). Likely low value on this deployment.
- `0898393` — mt76 core: use ALTX queue for packets to disassociated
  stations. Generic TX-path change, not chip-specific; plausibly relevant,
  needs a closer read before a verdict.

Remaining work:

- [ ] Pull the rest of the commit window (only a first partial page was
  fetched this session).
- [ ] Filter to mt7615/mt7915/generic-mt76-core commits only; discard
  mt7996/mt7925/mt7921/mt76x02/mt7986+-only changes as out of scope for this
  hardware, matching the existing "Explicitly excluded" precedent.
- [ ] Cross-check the filtered list against `901`/`902` for redundancy or
  conflict.
- [ ] If a bump is warranted: rebuild, then require the same full Wi-Fi
  regression pass (routed/bridged offload, 5 GHz association, SER survival
  behavior) used for every prior pin move — do not assume a source bump is
  behavior-neutral.

## Task 2: WED-20 — shorten WED busy-poll timeout during SER

Vendor patch [`999-wed-20`](https://raw.githubusercontent.com/mediatek/mtk-openwrt-feeds/main/25.12/files/target/linux/mediatek/patches-6.12/999-wed-20-refactor-check-wed-module-busy-time.patch)
changes `mtk_wed_poll_busy()` from a 1.5 s maximum wait to 100 ms. The
vendor rationale: heavy bidirectional traffic can leave L1 SER waiting
several seconds and disconnect stations. It's global — a WED-v1 operation
that legitimately needs more than 100 ms would be reported as failed
prematurely — so it needs real traffic testing, not a blind port. This is
the one remaining real WED vendor-SDK candidate; everything else in that
series is either implemented, hardware-gated out, or (WED-16) provably
moot.

- [ ] A/B WED-20 under heavy bidirectional 5 GHz traffic.
- [ ] Reject if it increases false busy/reset failures.

## Task 3: Power-save buffering validation

The hardware-managed TIM/PS buffering series (`9a46d8d21d2a`, `9e613fb007f5`,
`f8b59ca3be7b`) has shipped since the June refresh but was never validated
against an actual sleeping client — no PS-capable 5 GHz station has been
deliberately tested.

- [ ] Associate a sleeping/power-saving client to 5 GHz.
- [ ] Verify TIM/beacon behavior, downlink delivery, wake-up latency, and no
  starvation of other stations.
- [ ] Test with multiple stations and with one nonresponsive sleeping
  station.

## Task 4: Remaining physical acceptance tests

Carried forward unchanged from the old roadmap's Priority 1 acceptance —
these need an operator physically present, not something a remote session
can drive:

- [ ] AWG UDP session survives idle/resume.
- [ ] AWG UDP session survives teardown/rebind.
- [ ] AWG UDP session survives a WAN renewal/renumber.
- [ ] AWG UDP session survives a Wi-Fi roam.

## Task 5 (optional, low priority): `schedutil` vs `ondemand` A/B

Runtime governor tuning experiment, not a source backport. Never run.
Current governor is `ondemand`. Worth a controlled A/B under CAKE + PPE
load if there's ever a CPU-bound symptom to chase; not otherwise urgent.

## Task 6 (deferred, long-term): kernel 6.18 migration

- [ ] Start a separate kernel migration branch to OpenWrt's current
  Mediatek kernel baseline (6.18):
  [target Makefile](https://raw.githubusercontent.com/openwrt/openwrt/master/target/linux/mediatek/Makefile),
  [MT7622 config](https://raw.githubusercontent.com/openwrt/openwrt/master/target/linux/mediatek/mt7622/config-6.18).
- [ ] Rebase custom PPE/QDMA/WED patches deliberately; do not hand-cherry-pick
  unrelated 6.18 APIs into the 6.12 production branch.
- [ ] Revalidate boot, NAND/UBI, WED attach, PPE offload, bridge flowtable,
  QDMA controls, Wi-Fi, and rollback.

## Explicitly excluded — do not reopen without new evidence

Carried forward from the prior roadmap, all still correct:

- MCU full-chip-reset firmware ACK failure: confirmed unfixable from host
  source by two independent investigations. Mitigated via
  `mt7915-ser-watchdog`. Needs UART/firmware access this project doesn't
  have.
- WED-16 (duplicate WDMA ring-init guard): its own trigger condition
  (ring double-init causing the MCU-death loop) is provably unmet — that
  loop is a firmware ACK failure, not a ring-init issue. Dropped.
- WED-v2/v3 reserved-buffer, TX-free `M_DONE`, RXDMAD_C/RRO, second-adie
  clock fix, MT7915 HW ATF, vendor roaming-handler series, WED port to the
  integrated 2.4 GHz radio, EIP97/HACC crypto: all hardware/silicon-gated —
  wrong WED version, wrong chip family, or no board-specific crypto node.
- New MT7915 firmware hunting: recent mt76 firmware updates target
  MT798x/MT799x; no useful newer MT7915 payload was identified.
- Cache-line struct reorganization: CLOSED 2026-07-10 (see the sibling
  staging repo's `docs/cacheline-audit.md`) — do not reopen without a
  measured perf bottleneck (`flow_offloading=0/0`, CPU slow path, perf
  counters showing cache refills or CPU time actually limiting).
- MT7622 RX/TX DMA ring depth as a latency lever: the QDMA TX ring is
  shared across all 16 hardware queues, not a per-direction knob; shrinking
  it to help the slow WAN leg would also cap LAN-side burst headroom.
  There's no current measured bottleneck — the software AQM
  (`netsys-qos-port-investigation.md`) already demonstrably bounds latency
  at real WAN speeds (92 ms max under saturating load). Revisit only after
  profiling the AQM's own CPU/lock cost (that doc's §34 items 1-2), not
  before.

## Per-image test checklist

Reusable template for every candidate image, not a one-time task:

- [ ] Save current image and configuration rollback path.
- [ ] Record kernel, package versions, WED parameter, PPE bindings,
  temperatures, and link states.
- [ ] Boot image; verify both radios initialize and WED reports version 1.
- [ ] Associate a 5 GHz client so the WED path is exercised.
- [ ] Run routed IPv4/IPv6 throughput and latency tests.
- [ ] Run bridged wired-to-5 GHz traffic and verify offload counters.
- [ ] Run 2.4 GHz multi-client fairness and power-save tests.
- [ ] Exercise long-lived UDP/AWG idle/resume, teardown/rebind, WAN
  renewal/renumber, and Wi-Fi roam.
- [ ] Monitor `logread` for PPE, WED, MCU, SER, timeout, reset, BUG, and
  oops messages.
- [ ] Record TX watchdog events, PPE `BND` counters, WED `txinfo`, memory,
  temperature, and CPU load.
- [ ] Keep candidate only if it improves or preserves behavior without a
  new recovery risk.

Operational restriction (unchanged): never PCI unbind/rebind MT7915 and
never runtime-reload MT7915 with WED enabled. Keep a known-good rollback
image and clear pstore evidence only after saving it.
