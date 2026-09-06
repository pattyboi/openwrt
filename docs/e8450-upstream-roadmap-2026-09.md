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
- 2.4 GHz vendor VHT20/QAM-256 support is implemented as a default-off
  `vht2g` opt-in across mac80211, mt76/MT7615, and wifi-scripts. The live
  experiment is recorded in
  [`e8450-vht2g-experiment.md`](e8450-vht2g-experiment.md).

- WED-v1 attaches as version 1; PPE hardware flow offload active; both
  radios operational. Known, accepted, unfixable-from-here limitation: a
  controlled full-chip SER/reset under active 5 GHz traffic can leave the
  MT7915 MCU firmware unresponsive (never acknowledges a recovery command);
  `mt7915-ser-watchdog` bounds the resulting outage to ~65 s via auto-reboot.
  Do not reopen this without UART/firmware access — confirmed twice,
  independently, not fixable from host driver source.

## Completed follow-up: 2.4 GHz vendor VHT20/QAM-256 — DONE (2026-09-04)

The default-off VHT20 path was built, flashed, and hardware-tested on the
live E8450. Radio0 was set to `VHT20` with `vht2g=1`; radio1 remained
`HE40`, and the MT7915 WED-v1 boot-only configuration was not changed.

The PS4 client negotiated `VHT-MCS 3`–`4` at 26–39 Mbps RX during the
test, with expected throughput reaching 53.2 Mbps in a later sample. All
seven 2.4 GHz clients returned after the reload and remained associated
through a 60-second soak. This proves VHT negotiation and client stability;
it does not claim a controlled throughput improvement because no dedicated
VHT iperf endpoint was available. See the full
[`e8450-vht2g-experiment.md`](e8450-vht2g-experiment.md) record.


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

## Task 2: mt76 upstream pin bump evaluation (`6d1c6a75` → current) — DONE (2026-09-06)

Corrects this task's own prior entry: the "unknown, likely 150-250+ total"
estimate below was wrong — it came from paginating the commits HTML page
instead of asking for an authoritative range. `GET
/repos/openwrt/mt76/compare/6d1c6a758a4c0a690ee56cb849387dfa262fdb17...master`
returns the exact count: **11 commits total**, `ahead_by: 11`, `behind_by: 0`.
That's the complete window; there was never a second page to pull.

All 11, triaged by hardware relevance (this board: MT7622 SoC, MT7615
2.4 GHz, MT7915 5 GHz — no mt7921/mt7925/mt7996/mt76x02 silicon):

- `0898393` — mt76 core: use ALTX queue for packets to disassociated
  stations. Generic TX-path (`tx.c`) + `mt7915/main.c`. **Already applied**
  as local patch `903-mt76-use-altx-queue-for-disassociated-stations.patch`
  (byte-identical backport, confirmed by diffing the patch body against the
  upstream commit).
- `be5ce79` — mt7615: don't tear down BSS/STA state for monitor vifs.
  Touches `mt7615/main.c`, scoped to monitor-vif teardown, which this
  deployment doesn't use in normal AP operation (no monitor vif is ever
  created). Confirmed low value — not ported.
- `a57185c` — mt7915: disable RX NAPI when removing the device. Touches
  `mt7915/init.c` + `mt7915/main.c`, only fires on the module-remove path,
  which this project's own hard-lock rules forbid at runtime (never PCI
  unbind/rebind or runtime-reload MT7915). Confirmed low value on this
  deployment — not ported.
- `62c038a`, `4d82c99` — mt7921/mt7925 suspend/resume lock-inversion fixes.
  Out of scope: neither chip is present on this board.
- `0789c43` — mt76x02 TX-status rate-index validation. Out of scope: this
  board has no mt76x02 silicon.
- `bfb044b`, `a6e5a07` — mt7925/mt7921 FIF_FCSFAIL handling. Out of scope.
- `5772439` — mt7925 MLO teardown. Out of scope.
- `bd49f06`, `d73f612` — mt7996 struct-layout and TWT fixes. Out of scope:
  this board has no mt7996 silicon.

Net result: the mt76 driver pin (`6d1c6a75`, 2026-08-04) has nothing left to
pull for this hardware. The one generic core fix is already in via `903`;
the two mt7615/mt7915-touching fixes are real but scoped to code paths this
deployment doesn't exercise. **No pin bump needed** — do not reopen without
a new upstream commit actually touching mt7615/mt7915/generic mt76 core.

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

## Task 8: mtk-openwrt-feeds/immortalwrt 2026-09 audit — apply real findings — DONE (2026-09-06)

Full investigation, every patch adaptation, every live-test result, and
the AQM/CAKE verification: [`e8450-mtk-feeds-audit-2026-09.md`](e8450-mtk-feeds-audit-2026-09.md).
`immortalwrt/immortalwrt` produced no action items (stock-upstream MT7622
coverage only). `mtk-openwrt-feeds` produced five verified-applicable
findings and two A/B candidates; all seven now have a final disposition.

- [x] `999-ppe-13`/`999-eth-53`/`999-dsa-06` (multicast PPE CDMA reason,
  MDIO busy-wait race, MT7531 VLAN FID) — ported, build-verified,
  flashed and smoke-tested clean (`r33090-48c2d25d89`); no dedicated
  multicast/MDIO/VLAN-cycling functional test yet, no incident
  observed either way.
- [x] `999-ppe-93` (PPE hardware-offload bypass via `ct mark 0x99`,
  vendor `999-ppe-36`) — ported, flashed, live-tested: mechanism
  confirmed (a marked flow never reaches `ppe0/entries`), and a
  controlled A/B disproved an initial concern that it regressed
  `999-qos-06`'s AQM eviction rate (it didn't — the low `BND` count was
  real light household load, reproduced identically with the patches
  absent). Runtime toggle: `scripts/e8450/ppe-offload-bypass.sh`.
- [x] AQM/CAKE interaction directly re-verified against this new
  conntrack control (2026-09-06): a controlled marked/unmarked
  download comparison shows CAKE actively queueing the flow in both
  cases with no behavioral difference, and `qdma_aqm` kept triggering
  normally throughout (no regression). Closes the wired-client side of
  the open download-shaping question; the WLAN-specific side stays
  open pending a physical 5 GHz client — see
  [`e8450-download-shaping-handoff.md`](e8450-download-shaping-handoff.md).
- [x] `613-netfilter-optional-tcp-window-check` — decided **not
  adopted** (2026-09-06): live evidence found no measurable
  conntrack-invalid signal across 60 real AQM eviction events in a
  60-second window, so the named tradeoff (weakens a conntrack sanity
  check) isn't currently justified.
- [x] `999-eth-17` (NAPI poll weight 64→256) — ported, flashed
  (`r33087-10b027e38a`), hardware A/B tested against the saturating-load
  harness: no latency regression, +36% upload throughput. **Adopted.**
- [ ] `999-wdt-01` (watchdog timeout overflow clamp): no action needed
  unless a future config requests a non-default watchdog timeout.

## Task 9: mac80211 backports pin bump audit (`v6.18.26` → `v7.2`) — DONE, no further ports (2026-09-06)

The mt76 driver pin (Task 2) is exhausted for this hardware. The other real
lever for "further mac80211 improvements" is the `mac80211` package itself
(`package/kernel/mac80211/Makefile`, `PKG_VERSION:=6.18.26`) — the actual
`net/mac80211`/`net/wireless` core, pulled from `openwrt/backports`. Per
that project's own README, a `backports-vX.Y.Z` release is generated
straight from Linux kernel tag `vX.Y.Z`'s `net/mac80211`+`net/wireless`
trees. Our pin (`backports-v6.18.26`, published 2026-05-02) is three
releases behind the current `backports-v7.2` (published 2026-08-21) —
roughly 4-5 months of upstream `net/mac80211` development, not a small gap.

**Confirmed by direct tarball diff** (downloaded both
`backports-6.18.26.tar.zst` and `backports-7.2.tar.zst`, diffed
`net/mac80211/` directly — not inferred from kernel.org commit logs):
58 of ~64 files in `net/mac80211/` changed. Several are large:
`cfg.c` (1535 diff lines), `rx.c` (1424), `util.c` (753), `iface.c` (595),
`sta_info.c` (632), `tx.c` (532), `vht.c` (486). New files: `ap.c`, `nan.c`,
`uhr.c`. This is a much bigger surface than the mt76 driver audit (11
commits, 15 files) — it needs the same per-hunk discipline as Task 1, not a
blind bump, and is not something to rush through in one pass.

**Whole files confirmed dead weight for this hardware** (feature areas this
deployment never exercises — plain dual-band AP, no mesh point, no IBSS/OCB,
no S1G sub-1GHz radio, no NAN, no EHT/WiFi-7/MLO client): `mesh.c`,
`mesh_hwmp.c`, `mesh_pathtbl.c`, `mesh_plink.c`, `mesh_sync.c`, `s1g.c`,
`nan.c`, `ibss.c`, `ocb.c`, `eht.c`, `tdls.c`, `tests/*`. Skip these
entirely in the per-hunk pass below.

**One fix already ported and build-verified this session** (small,
precisely scoped, directly closes a gap in this doc's own open Task 4):

- [x] `sta_ps_start()` in `rx.c` never called `sta_info_recalc_tim()` after
  recording newly-buffered TIDs — a station entering power save with
  already-buffered per-TXQ traffic never gets its TIM bit set unless some
  *later* frame arrives, so it can doze indefinitely on top of a non-empty
  queue. Upstream commit `a007a384c9eb` (landed 2026-07-21, after our
  2026-05-02 pin). Confirmed missing by diffing `sta_ps_start()` in both
  tarballs directly (not just the commit message). Ported as
  `package/kernel/mac80211/patches/subsys/377-mac80211-recalc-tim-on-ps-start.patch`.
  **Build-verified**: `make package/mac80211/{clean,prepare} V=s` applies
  it cleanly (`Hunk #1 succeeded at 1612 (offset -1 lines)`, zero rejects),
  and the resulting extracted source
  (`build_dir/.../mac80211-regular/backports-6.18.26/net/mac80211/rx.c`)
  was inspected directly and contains `sta_info_recalc_tim(sta);` at the
  end of `sta_ps_start()`. Not yet compiled into a full image or flashed —
  that step, plus the Task 4 sleeping-client regression test, is still
  open. This is exactly the class of bug Task 4's power-save validation
  was written to catch — a real, likely-live cause worth checking for
  during that test.

File-by-file pass, completed this session (real diffs, not commit-message
guesses — every finding below is from `diff -u` against both extracted
`backports-*.tar.zst` releases):

- [x] `agg-tx.c`/`agg-rx.c` — the `2f067f5a450e` "tid_tx use-after-free"
  candidate is real in the diff, but it's a bug the *new* S1G NDP-BlockAck
  feature introduces in itself (`tid_tx->ndp` read after
  `ieee80211_remove_tid_tx()` frees it) and fixes in the same breath. We
  don't carry the S1G/NDP-BA feature, so the bug it fixes doesn't exist in
  our tree. Both files are otherwise 100% S1G-NDP-BA plumbing + an
  `mgmt->u.action.u.addba_req` → `mgmt->u.action.addba_req` struct-flatten
  tied to a wider `ieee80211.h` change. **Not applicable, nothing to port.**
- [x] `rx.c` remainder — read in full (1424 diff lines). Three cross-cutting
  refactors account for nearly all of it: (1) `RX_DROP` → 40+ distinct
  `RX_DROP_U_*` reasons (new SKB-drop-reason tracing infra, mechanical
  rename with no behavior change), (2) the same `u.action.u.X` →
  `u.action.X` struct-flatten from agg-tx/rx.c, (3) S1G/NAN_DATA handling
  and `u64_stats_add()/u64_stats_inc()` per-CPU stat API conversion. None of
  these are separable single-hunk fixes — pulling any one requires the
  matching `ieee80211.h`/drop-reason-enum/`u64_stats_t` infra across the
  whole tree. The Zhao Li bounds-validation items flagged from the
  commit-log scan turned out to be inside this same renamed/refactored code,
  not standalone. **No further ports beyond the TIM fix already shipped.**
- [x] `cfg.c` (1535 diff lines) — grepped specifically for
  `aql|airtime|atf|weight`: zero matches. No AQL/ATF-touching changes at
  all, so **no conflict with local patches `372`-`374`, nothing to port**.
  Diff is NAN/NPCA/UHR config-plane growth, confirmed irrelevant.
- [x] `sta_info.c`/`.h`, `key.c`, `wpa.c`, `status.c`, `rate.c`,
  `rc80211_minstrel_ht.c`, `iface.c`, `main.c`, `util.c`, `chan.c`,
  `driver-ops.c`, `vht.c`, `he.c`, `ht.c` — all read (content diff, blank
  lines/copyright bumps stripped). Consistent pattern across every one:
  Wi-Fi Aware/NAN capability plumbing ("NDI station using NMI station
  capabilities" appears in `ht.c`/`vht.c`/`he.c`), a channel-context
  iterator rewrite (`chan.c`), an MU-MIMO-group `BSS_CHANGED_MU_GROUPS`
  refactor (`main.c`/`driver-ops.c`), and pervasive `kzalloc()`/`kmalloc()`
  → `kzalloc_obj()`/`kzalloc_flex()`/`kmalloc_obj()` conversions (new
  type-safe allocation macros introduced kernel-wide in this window). No
  isolable bug fix independent of that infra in any of these files.
  **Nothing safely portable.**
- [x] `net/wireless/` (cfg80211) — 29 files differ. Spot-checked the
  regulatory (`reg.c`) and scanning (`scan.c`) paths specifically since
  those are always-on for any AP: same `kzalloc_obj`/`kzalloc_flex`
  conversion throughout, S1G/NAN regulatory-domain branches, and one real
  MBSSID-element bounds-check hardening in `scan.c` — but it's written
  against the new `kzalloc_flex` allocator and sits next to
  `mbssid_elem`/`next_mbssid` variables implying more surrounding MBSSID
  parsing rework not visible in this hunk alone. Not a clean isolated pull.
  The 22 `wext-*.c` "changed" files are copyright-year bumps only (verified
  by diff-line count: 5 lines each, all comment). **Nothing safely
  portable.**

**Conclusion:** across the full `v6.18.26` → `v7.2` window, the
`sta_ps_start()` TIM fix (already shipped as patch `377`) is the only
change that is both applicable to this deployment and cleanly separable
from the surrounding NAN/S1G/MLO/UHR feature wave and its supporting
infra (`kzalloc_obj`/`kzalloc_flex`, `u64_stats_t`, drop-reason enums,
`u.action.u.X` struct flatten). Everything else would require adopting
that whole infra wave to get a handful of unverified secondary benefits
(MBSSID bounds hardening, MU-MIMO group correctness) — that's a full
backports pin bump decision (with the NAN/S1G/MLO/UHR surface this
deployment doesn't use coming along for the ride), not a "pull the
applicable fixes" pass. **Do not attempt further piecemeal ports from this
window; the next real move here is an explicit pin-bump decision, not more
cherry-picking.**

Still open, unchanged from before: build the full image with patch `377`
included and run the standard regression pass (routed/bridged offload,
5 GHz association, SER survival, power-save with a real sleeping client
per Task 4) before flashing. **Not flashed yet, per instruction.**

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
