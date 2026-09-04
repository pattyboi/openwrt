# E8450 upstream/vendor roadmap — 2026-09

Scope: Linksys E8450/Belkin RT3200, MT7622BV, NETSYSv1, one PPE, integrated
MT7615 2.4 GHz radio, PCIe MT7915 5 GHz radio, WED-v1.

This supersedes `e8450-upstream-backport-roadmap.md` (closed 2026-09-04) and
`wed-v1-opportunities.md` (closed 2026-09-04). Read those two only for
process history; every item worth carrying forward is repeated here.

## Baseline as of 2026-09-04

- Kernel `6.12.103` (bumped from `6.12.94` same session; see Task 1),
  live/flashed build `r33079-30e121775c`, hardware-verified booted and
  reachable on the router.
- mt76 source pin: `openwrt/mt76` master `6d1c6a75` (`6d1c6a758a4c0a690ee56cb849387dfa262fdb17`,
  2026-08-04).
- Local kernel/target patches (`target/linux/mediatek/patches-6.12/`):
  MTK ECC clock-enable fix (`913`; `911`/`912` dropped 2026-09-04, now
  duplicates of upstream — see Task 1), WED-v1 RX prefetch/descriptor
  reset + diagnostics (`914`-`917`), WED WDMA gating during SER
  (`999-wed-13`), WED ring-desync fix (`999-wed-14`), PPE preserved-
  cache-line lock (`999-ppe-14`), the `qos-01`..`qos-17` QDMA/AQM/PSE-
  debugfs series (tracked separately, see
  `netsys-qos-port-investigation.md`), MT7622 RX ring doubling
  (`999-eth-91`), the local NAPI-before-register-netdev panic fix
  (`999-eth-07`, rebased 2026-09-04 for 6.12.103's named-IRQ rename —
  see Task 1), and assorted PPE/nftables/xxhash patches predating this
  roadmap.
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

## Task 1: Linux kernel point-release bump `6.12.94` → `6.12.103` — DONE (2026-09-04)

The live pin is nine stable point releases behind (`6.12.103` is current
upstream as of this session). Point releases are pre-reviewed backports —
lower risk than a mainline pin bump, and the standard way OpenWrt consumes
this class of fix. Audited every driver subsystem this board actually uses
against the real range (`git.kernel.org` linux-stable, `id=v6.12.94..v6.12.103`,
one query per driver path this board's config enables) instead of trusting
the changelog summary.

**Must drop on bump — exact duplicates of local hand-backports:**

- `912-mtk-ecc-stop-on-idle-timeout.patch` — upstream `16f7ec8d5dc1` landed
  in 6.12-stable as `623059b19c66` (2026-08-03). Byte-identical diff.
- `911-pcie-mediatek-fix-fts-num-l0.patch` — upstream `282305d7e9c0` landed
  in 6.12-stable as `1a292d551b02` (2026-07-24). Byte-identical diff.

**New, real, relevant fixes not yet in this tree:**

`drivers/pci/controller/pcie-mediatek.c` (our exact MT7915 PCIe host
controller) — one dependent series, 6 commits:

- `ce52e494a755` — fixes an IRQ domain leak when a PCIe port fails to
  enable (`Cc: stable@vger.kernel.org # 5.10`; `Fixes:` tag names the
  MT7622 support commit directly).
- `1ed324b45c78` — fixes MSI message address computation: the driver used
  `virt_to_phys()` on an ioremapped register base, which is architecturally
  wrong. The fix's own comment: "MT2712/MT7622 only support 32-bit MSI
  addresses" — a real correctness bug in MSI IRQ delivery on our exact SoC.
- `ca1a8df853f7` — trivial buffer-size fix, `Stable-dep-of` prerequisite for
  the MSI fix above.
- `bbc21aa10f83`, `ba45c91a8c74`, `09b0115a86f9`, `a44c473ba778` — refactors
  in the same code region (quirks bitmap, MSI parent-domain API, TPVPERL
  delay macro, `dev_fwnode()`). Part of the same dependent series; not
  independently cherry-pickable.

`drivers/net/ethernet/mediatek/mtk_ppe.c` (our exact PPE):

- `5466a4e2d22f` — fixes an rhashtable leak in `mtk_ppe_init()`'s error
  paths (`dmam_alloc_coherent`/`devm_kzalloc` failure skip the existing
  cleanup label). Probe-time only, minimal leak, but a real correctness fix
  in code this fork has heavily modified (cache-lock, etc.).

`drivers/net/dsa/mt7530.c` + `mt7530-mdio.c` (our exact MT7531 switch —
genuinely new territory; the switch driver was never previously audited by
this project):

- `96e0f5184af6` — MT7531 indirect PHY-register polling silently returns 0
  (success) on a failed bus read instead of propagating the error, so a bus
  glitch hands phylib garbage PHY register data. Fixed by switching to
  `regmap_read_poll_timeout()`, which does propagate read errors.
- `93d46870c544` — the MDIO regmap backend truncates `bus->read()`'s
  negative errno into a `u16`, turning e.g. `-ETIMEDOUT` into `0xff92` and
  treating it as valid register data — which then gets read-modify-written
  back to the switch on the next write. Same author/series as the above
  (Daniel Golle, 2026-07-28); both are real reliability fixes for the exact
  switch chip on this board (`mediatek,mt7531`).

**Confirmed applicable but behavior-neutral for this SoC:**

- `mtk_eth_soc`'s named-IRQ support (`407503ba0533` + 2 dependents) is
  MT7988-oriented; it falls back to the existing index-based IRQ lookup
  unchanged for boards without named IRQs in DT (ours). Safe, no behavior
  change here.
- `mtk_wed`'s `wed_amsdu_show()` index fix is WED **3.0**-only (AMSDU
  offload, MT7988-family) — doesn't touch the WED-v1 path this board uses.
  Harmless either way.

**Confirmed out of scope, correctly excluded:**

- Every `net: airoha:` commit under `drivers/net/ethernet/mediatek/` — a
  different MediaTek-adjacent chip line (EN7581/AN7583) hosted in the same
  driver directory. Not this board.
- `mtk_wed: fix loading WO firmware for MT7986` — wrong SoC.

**Zero changes in this window** (checked, nothing to report): `drivers/mtd/nand/spi/`,
`spi-mtk-snfi.c`, `spi-mt65xx.c`, `spi-mtk-nor.c`, `mtk_wdt.c`,
`thermal/mediatek/auxadc_thermal.c`, `cpufreq/mediatek-cpufreq.c`,
`hw_random/mtk-rng.c`, `soc/mediatek/mtk-pmic-wrap.c`,
`pmdomain/mediatek/mtk-scpsys.c`, `net/pcs/pcs-mtk-lynxi.c`,
`phy/mediatek/phy-mtk-tphy.c`, `pwm/pwm-mediatek.c`,
`regulator/mt6380-regulator.c`, `pinctrl/mediatek/pinctrl-mt7622.c`.

**Executed and hardware-verified**, same session. Steps beyond the plan
below: two *other* local patches also needed a hand-rebase, unrelated to
the point-release audit above but exposed by it —

- `942-net-ethernet-mtk_wed-move-cpuboot-in-a-dedicated-dts.patch` (a
  pre-existing, non-E8450-specific 2023 mainline patch already in this
  fork's baseline): one hunk's context drifted because 6.12.103 added a
  new `mtk_wed_is_v3_or_greater()` branch in the same function
  (MT7988/MT7996-family code, inert on this v1 chip). Rebased by
  generating a fresh hunk from a real before/after diff rather than
  hand-computing line offsets — hand-computed offsets repeatedly
  undercounted GNU patch's per-hunk cumulative-offset tracking and
  needed 2 retries; diffing real applied output against real source
  got it right first time.
- `999-eth-07-mtk_eth_soc-fix-panic-issue-with-napi_enable.patch` (this
  fork's own NAPI-before-register-netdev panic fix): one hunk's context
  drifted because 6.12.103's own "named IRQs" commit renamed
  `eth->irq[0]` to `eth->irq[MTK_FE_IRQ_SHARED]` in the exact lines this
  hunk touches. Same real-diff rebase approach; split into 3 smaller
  hunks for a cleaner clean-fuzz match.

Completed steps:

- [x] Bumped the kernel hash/version pin from `6.12.94` to `6.12.103`
  (`target/linux/generic/kernel-6.12`).
- [x] Dropped local patches `911` and `912` — confirmed upstream now
  carries them (see findings above).
- [x] Dropped stale, already-upstreamed **generic** OpenWrt backport
  patches discovered along the way, not previously tracked in this doc
  because they're not E8450-specific: `backport-6.12/200-01`/`200-02`
  (`secs_to_jiffies` hoist + cast — 6.12.103 already carries both
  natively; leaving `200-01` in produced a genuine duplicate-macro
  redefinition), `620-...ppp-use-IFF_NO_QUEUE`, `621-...ppp-convert-to-percpu-netstats`,
  `625-...ppp-enable-TX-scatter-gather` (all three confirmed already
  native in 6.12.103 by direct source inspection before removal).
- [x] Rebased the two drifted local/baseline patches above using a
  real-diff-based method (apply prior hunks for real, hand-edit the
  target transformation on the real resulting file, diff, splice the
  generated hunk back in) — proved far more reliable than manually
  computing GNU patch's cumulative per-hunk line-offset arithmetic.
- [x] `target/linux/prepare` completes cleanly against 6.12.103 with
  every remaining local patch applying with at most a normal fuzz
  offset, zero rejects.
- [x] Full image build succeeded (`r33079-30e121775c`). One new
  kernel-side Kconfig prompt appeared (`DEBUG_NET_SMALL_RTNL`, new in
  6.12.103, default `N`) — answered by adding
  `# CONFIG_DEBUG_NET_SMALL_RTNL is not set` to
  `target/linux/generic/config-6.12`, matching the three sibling
  `DEBUG_NET*` options already explicitly disabled there.
- [x] Flashed to the live router with `sysupgrade -c` (config
  preserved). Hardware-verified on boot:
  - `uname -r` confirms `6.12.103`.
  - Zero panic/BUG/oops/SER/failure messages in `dmesg` (only benign
    substring false-positives: `ramoops` contains "oops",
    `1b100000.ethernet: error -ENXIO: IRQ fe1/fe2 not found` is the
    expected, harmless named-IRQ-not-present fallback path — the SoC
    correctly proceeded to legacy indexed IRQ lookup and ethernet works).
  - **MSI fix validated**: `/proc/interrupts` shows the `mt7915e` MSI
    line actively incrementing (585/9834 across the two CPUs) — this is
    the exact path `1ed324b45c78`'s `virt_to_phys()`→physical-address
    fix changed; a broken MSI address would show a stuck-at-zero or
    entirely absent interrupt line, not this.
  - WED still attaches as version 1; PCIe link up; both radios up with
    calibration/channel/txpower state fully preserved (ch6 2.4 GHz,
    ch157 5 GHz, 30 dBm both).
  - 8 stations associated (7×2.4 GHz + 1×5 GHz) with zero errors.
  - **PPE hardware-bound flow confirmed live**: the same long-lived
    `192.168.1.6:51821` AWG UDP flow tracked throughout this project's
    history shows up as a `BND` (hardware-bound) entry in
    `/sys/kernel/debug/ppe0/entries`, packet/byte counters actively
    advancing (3,643 packets / 1,216,940 bytes at check time), routed to
    the same 5 GHz WED-attached station. Flow offload remains `1/1`.
  - WAN reachable, 0% loss to `1.1.1.1`.

Original plan (superseded by the above, kept for reference):

## Task 2: mt76 upstream pin bump evaluation (`6d1c6a75` → current)

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

## Task 3: WED-20 — shorten WED busy-poll timeout during SER

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

## Task 4: Power-save buffering validation

The hardware-managed TIM/PS buffering series (`9a46d8d21d2a`, `9e613fb007f5`,
`f8b59ca3be7b`) has shipped since the June refresh but was never validated
against an actual sleeping client — no PS-capable 5 GHz station has been
deliberately tested.

- [ ] Associate a sleeping/power-saving client to 5 GHz.
- [ ] Verify TIM/beacon behavior, downlink delivery, wake-up latency, and no
  starvation of other stations.
- [ ] Test with multiple stations and with one nonresponsive sleeping
  station.

## Task 5: Remaining physical acceptance tests

Carried forward unchanged from the old roadmap's Priority 1 acceptance —
these need an operator physically present, not something a remote session
can drive:

- [ ] AWG UDP session survives idle/resume.
- [ ] AWG UDP session survives teardown/rebind.
- [ ] AWG UDP session survives a WAN renewal/renumber.
- [ ] AWG UDP session survives a Wi-Fi roam.

## Task 6 (optional, low priority): `schedutil` vs `ondemand` A/B

Runtime governor tuning experiment, not a source backport. Never run.
Current governor is `ondemand`. Worth a controlled A/B under CAKE + PPE
load if there's ever a CPU-bound symptom to chase; not otherwise urgent.

## Task 7 (deferred, long-term): kernel 6.18 migration

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
