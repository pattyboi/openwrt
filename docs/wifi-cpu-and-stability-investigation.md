# Wi-Fi CPU overhead (2.4GHz) and 5GHz stability investigation

## Status

Two independent, narrowly-scoped follow-ups to the existing WED/QoS work:

1. CPU-overhead reduction on the MT7615/WMAC 2.4GHz path (which has no WED
   hardware DMA offload — see `docs/README.md`'s WED architecture note).
   Two low-risk changes: an IRQ-affinity rebalance (`files/etc/rc.local`)
   and an mt76 core DMA patch
   (`package/kernel/mt76/patches/902-mt76-dma-skip-empty-queue-tx-cleanup.patch`).
   Both **built, flashed, and confirmed live** on the E8450 (2026-09-04) —
   see the "Confirmed live"/"flashed" notes under each fix below and
   `docs/netsys-qos-port-investigation.md` §33 for the shared build/flash
   log. A dedicated saturating-*Wi-Fi*-load CPU-time profiling pass to
   quantify the savings remains open (§34 item 1 of that doc).
2. Software-tunable options for MT7915 5GHz *connection stability* (not
   throughput, and not the already-closed controlled-SER MCU-death issue —
   see `docs/e8450-ppe-validation.md` and `docs/wed-v1-opportunities.md`).
   One real, distinct instability mechanism identified (DFS channel 52's
   radar-triggered channel switch); several other candidates investigated
   and found low-value or architecturally unavailable. Nothing in this
   area was applied to the live wireless config — see "5GHz findings"
   below for why each candidate was or wasn't acted on.

Both scouts corrected an assumption in the original ask: **MT7622 is a
dual-core Cortex-A53 SoC (2 CPUs), not quad-core** — confirmed via
`arch/arm64/boot/dts/mediatek/mt7622.dtsi` (`cpu@0`/`cpu@1` only) and the
built `.config` (`CONFIG_NR_CPUS=2`, `CONFIG_SCHED_SMT` not set), and
independently corroborated by this repo's own
`docs/e8450-upstream-backport-roadmap.md`. This raises the stakes of the
IRQ-affinity finding below: there is no third or fourth core to fall back
on.

**Build-note:** the mt76 driver source actually used to build the shipped
`kmod-mt7615e`/`kmod-mt7915e` is
`build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_mt7622/mt76-2026.08.04~6d1c6a75/`
— a separate out-of-tree module build, not the stale, unpatched,
never-compiled copy that happens to also exist under
`linux-6.12.94/drivers/net/wireless/mediatek/mt76/` (a leftover from an
earlier build attempt, dated June vs. the real August 4 pin, missing the
already-applied `901` compat patch, and with no compiled `.o`/`.ko`
anywhere under it). Both the CPU-overhead scout and this document's
verification worked from the real, compiled copy; the June copy should be
ignored or removed if it causes confusion in future greps.

## 2.4GHz CPU overhead findings

### Applied: rebalance the WMAC IRQ off the shared core (1/2)

`files/etc/rc.local` pinned three device IRQs onto CPU1 and only one onto
CPU0, on a 2-CPU SoC with no `irqbalance` installed to correct it later
(confirmed absent from the kernel `.config`):

| IRQ | Before | After |
|---|---|---|
| Ethernet RX (`1b100000.ethernet`) | CPU0 | CPU0 (unchanged) |
| Ethernet TX (`1b100000.ethernet`) | CPU1 | CPU1 (unchanged) |
| MT7915 (5GHz) | CPU1 | CPU1 (unchanged) |
| MT7615/WMAC (2.4GHz) | CPU1 | **CPU0** |

Ethernet RX is mostly PPE-hardware-offloaded — an offloaded flow is
forwarded by the PPE silicon and never enters the software NAPI/IP-stack
RX path at all (see `docs/netsys-qos-port-investigation.md`), so CPU0's
actual per-packet software cost is low relative to what its IRQ count
alone would suggest. MT7615/WMAC has no such offload: every 2.4GHz
RX/TX-status/MCU interrupt costs real host CPU (this is the entire premise
of this investigation — see `docs/README.md`'s WED-attachment note that
2.4GHz "never get[s] WED's zero-CPU DMA bypass"). Before this change, that
real per-packet cost shared one core with MT7915's own host-side work
(MCU/status — its data path is WED-offloaded but not everything is) and
with all software-forwarded Ethernet TX (including the AQM eviction work
from `999-qos-06`/`999-qos-13`/`999-qos-15`), while the other core carried
only the comparatively idle offloaded RX path.

Moving WMAC to CPU0 puts the two IRQs with genuine per-packet software
cost (WMAC, ETH_TX) on separate cores instead of stacking three device
IRQs on one. This is provable as a real rebalancing by config/devicetree
inspection alone; the *magnitude* of the CPU-time improvement under real
2.4GHz load needs a live `mpstat`/`top` A/B, which was not available this
session.

**Confirmed live on the router** (read-only `/proc/interrupts`/`/proc/stat`/
`/proc/softirqs` pulls against 192.168.1.1, pre-patch state — this fix has
not been flashed yet, so these are the "before" numbers the rc.local
change targets): at 2 days 8 hours uptime, accumulated interrupt counts
were MT7915=11,956,689, ETH_TX=34,031,223, and WMAC=24,715,528 — all on
CPU1 (~70.7M total) — versus ETH_RX's 44,593,612 alone on CPU0 (~44.6M
total). More directly relevant than raw IRQ counts, `/proc/softirqs`'
`TASKLET` row (the actual software dispatch mechanism both mt7615 and
mt7915 use between their hardirq and NAPI stages) shows **95,611,675 on
CPU1 versus 19,371,701 on CPU0 — a 4.9x imbalance**, essentially all of it
attributable to the two Wi-Fi radios sharing CPU1 (Ethernet's NAPI does
not go through this tasklet path). Total per-CPU busy time (`/proc/stat`)
was closer at this snapshot — CPU1 ~7% busier than CPU0 in aggregate
jiffies — because the router's ambient household load is currently light
(`uptime` load average 0.02-0.11 at the time of the pull); the tasklet
imbalance is the leading indicator of what would matter once load rises
during a saturating burst, consistent with why this needs a live A/B
under real saturating traffic (not available this session) to quantify
the CPU-*time* delta, even though the dispatch-mechanism imbalance is
already directly measured and real.

**Update (2026-09-04): flashed and confirmed live.** Built into a real
image and flashed to the E8450 (see
`docs/netsys-qos-port-investigation.md` §33 for the full build/flash
log). One real gotcha: `sysupgrade -c`'s config preservation restored
the *old* `/etc/rc.local` over the new image's file (it treats
`etc/rc.local` as a preserved config path), so the fix silently didn't
take effect on first boot - `/proc/irq/141/smp_affinity` still read `2`
post-flash. Fixed by pushing the corrected file over SSH and
re-sourcing it live; now confirmed by direct measurement (two
`/proc/interrupts` samples 20 seconds apart) that new WMAC interrupts
land exclusively on CPU0 (+3,560 on CPU0, +0 on CPU1 in that window).
Since the fix now lives in the router's actual `/etc/rc.local`, future
`sysupgrade -c` runs will correctly preserve *this* version - the gotcha
only bites the file's first change. A dedicated saturating-load
`mpstat`/`perf` A/B to quantify the CPU-*time* delta (as opposed to the
now-confirmed dispatch-mechanism/interrupt-routing fix) remains open;
see `docs/netsys-qos-port-investigation.md` §34 item 1 for the same gap
on the qos-15 side.

### Applied: skip lock+MMIO read in mt76's tx_cleanup for an already-empty queue

`mt76_dma_tx_cleanup(dev, q, false)` (`dma.c`, shared by every mt76
driver) unconditionally took `q->cleanup_lock` and did an uncached MMIO
register read (`mt76_dma_read_dma_idx()` → `readl()`) *before* the
while-loop even checked `q->queued`. On an already-empty queue this cost
is pure overhead — the loop's own condition (`q->queued > 0 && ...`) means
it does zero work regardless of what the MMIO read returns.

This is not a rare case on the 2.4GHz path specifically: `mt7615/mac.c`'s
`mt7615_mac_tx_free()` — called on *every* TX-status notify event, which
arrives multiplexed on the same RX ring as data frames — unconditionally
calls `mt76_queue_tx_cleanup(..., false)` **five times** on the
`is_mt7615()==false` branch this board's integrated MT7622-WMAC silicon
takes (once for the PSD queue, once per WMM AC). `mt7915/mac.c`'s
equivalent handler only makes **two** such calls (PSD+BE) — the MT7622
WMAC's 5-call fan-out is the family outlier, and it's the radio with no
WED offload to begin with.

`902-mt76-dma-skip-empty-queue-tx-cleanup.patch` adds
`if (!flush && !q->queued) return;` before the lock, deliberately
excluding the `flush=true` teardown/reset path (its post-loop
`mt76_dma_sync_idx()`/`mt76_dma_kick_queue()` calls must still run even
when nothing was queued — verified by reading every `flush=true` call
site in the tree, all of which are stop/reset paths, never a hot
per-packet path). Behavior-preserving by inspection: an empty queue has
nothing to reap regardless of the hardware index. Because this is the
shared core DMA path, every mt76 driver that calls `tx_cleanup` from a hot
`flush=false` context benefits (mt7615, mt7603, mt76x02, mt7915's MCU
cleanup, mt7921, mt7925) — not just this board's 2.4GHz radio, though it
is hit hardest here.

**Confirmed live on the router:** `wl0`'s (2.4GHz) `mt76/xmit-queues`
debugfs, sampled twice a few seconds apart while **8 stations were
actively associated** (`iw dev wl0-ap0 station dump`, signal range -40 to
-75 dBm, real household traffic — not an idle radio): all 5 hardware
queues read `hw-queued = 0` in both samples, even though each queue's
`head` counter visibly advanced between samples (e.g. queue 2:
345&nbsp;→&nbsp;414, queue 4: 30&nbsp;→&nbsp;46 — real, ongoing TX, not a
quiescent radio). This is a direct, live confirmation of the fix's core
premise: with 8 real clients generating traffic, the hardware queues
still spend enough time empty that `mt7615_mac_tx_free()`'s five
per-notify-event cleanup calls routinely find nothing queued — exactly
the case `902` now short-circuits before the lock/MMIO read.

**Verification performed:** `dma.o` compiles clean under this package's
own `-Werror` build (out-of-tree module build against the configured
6.12.94 kernel, real `aarch64_cortex-a53_musl` cross-toolchain), and the
patch applies with zero fuzz against the pristine
`dl/mt76-2026.08.04~6d1c6a75.tar.zst` extraction. A full module *link*
was not attempted — that requires the OpenWrt `mac80211`-backports
include environment (a separate `mac80211-regular/backports-6.18.26`
package tree; a bare `make M=...` invocation against just the kernel's
own bundled `net/mac80211` headers fails on an unrelated file,
`tx.c`'s use of `ieee80211_txq_aql_pending()`, confirming this is a build-
environment gap in my ad hoc invocation, not a defect this patch
introduced). **Flashed (2026-09-04) and running without regression**:
built into the same image as §33's AQM patches, currently live on the
E8450 (see `docs/netsys-qos-port-investigation.md` §33 for the full
build/flash log). No dmesg errors, `mt7615e`/`mt7915e` both loaded and
functioning (9 real 2.4GHz stations reconnected, 5GHz completed its DFS
CAC cleanly), and the router passed a saturating-load latency test
(§33.4) with no anomalies. This confirms the module loads and runs
correctly with the fix; it does **not** by itself isolate the CPU-time
savings the fix targets - a dedicated `mpstat`/`perf` A/B under
saturating *2.4GHz* traffic specifically (§33.4's test saturated the WAN
queue via a wired iperf3 upload, not the WMAC radio) remains the
concrete next step to quantify this fix's own savings, same gap as
qos-15's (`docs/netsys-qos-port-investigation.md` §34 item 1).

### Investigated and found not to be an issue, or not actionable

- **GRO**: already active on the Wi-Fi RX path for both radios
  (`mt76_rx_complete()` calls `napi_gro_receive()` unconditionally,
  shared code — not a 2.4GHz-specific gap, nothing to fix).
- **NAPI weight/budget and IRQ dispatch structure**: identical (kernel
  default weight 64, same hardirq→tasklet→`napi_schedule()` shape)
  between mt7615 and mt7915 — not a 2.4GHz differentiator.
- **Interrupt coalescing** (`MT_DELAY_INT_CFG`, explicitly zeroed in
  `mt7615_dma_init()`): a sibling older-chip register header suggests the
  underlying WPDMA HIF block generation *can* support delayed/batched
  interrupts, but `mt7615/regs.h` defines no bitfield layout for this
  chip and whether this specific silicon honors non-zero values isn't
  established by source inspection — would need a MediaTek register
  datasheet or a live hardware A/B (risk of hangs/latency regressions)
  before touching. Not attempted.
- **RPS/XPS**: compiled in (`CONFIG_RPS=y` etc.) but unconfigured. With
  only 2 real cores and mac80211/mt76 already doing most RX work
  (crypto, rate accounting, GRO) synchronously inside the NAPI poll
  itself, RPS's plausible benefit is limited to post-NAPI processing of
  non-PPE-offloaded flows — real but unproven without a live A/B; not
  applied.
- **DMA burst/multi-DMA size, module parameters**: already hardcoded at
  documented maximum values (`MT_WPDMA_GLO_CFG_DMA_BURST_SIZE=0x3`,
  `MULTI_DMA_EN=0x3`); no `module_param()` exists in mt7615 for
  interrupt coalescing, NAPI budget, or DMA burst size. No headroom found.
- **Upstream mt76 commit audit**: no local git history is vendored for
  the pinned mt76 snapshot (fetched as a tarball, matching
  `docs/e8450-upstream-backport-roadmap.md`'s own citation convention via
  GitHub URLs rather than local `git log`). A web search found only
  pre-2021 mt7615 CPU/interrupt commits, all long since merged before the
  current pin. No un-pulled upstream CPU-efficiency commit was found;
  reported as a negative result, not guessed.

## 5GHz stability findings

None of these were applied to `files/etc/config/wireless` — every item
below either has low expected value against the specific documented
symptom, requires RF-environment knowledge this session doesn't have, or
both. Presented for a decision, not applied unilaterally, consistent with
how this repo already treats similarly uncertain-value production changes
(e.g. `grace_ms` tuning in `docs/netsys-qos-port-investigation.md` §31.3).

### Real, distinct instability mechanism: DFS on channel 52

The 5GHz radio (`files/etc/config/wireless`, `radio1`) is fixed to
**channel 52**, which sits in the UNII-2A band and is marked
`NO-IR, DFS, AUTO-BW` in the regulatory database
(`package/firmware/wireless-regdb/patches/500-world-regd-5GHz.patch`).
`ieee80211h` (802.11h DFS/TPC) is unconditionally enabled by the wireless
config generator whenever a country code is set (which it is: `US`).
MT7915 runs firmware-driven radar detection
(`mt7915_dfs_init_radar_detector()`, called from `mt7915_start()`); on a
radar event the driver calls `ieee80211_radar_detected()`, which forces
mac80211's channel-switch machinery — briefly interrupting or
deauthenticating every 5GHz client. This is **architecturally distinct**
from the RSSI/rate-fallback mechanism the earlier WED investigation
already correlated with retries (`docs/wed-v1-opportunities.md`'s
smoke-test sections): it's a hard, visible, radar-triggered event, not a
gradual signal-quality degradation.

Background (concurrent, non-disruptive) CAC is **not available on this
board — and not because of a disableable policy flag.** Follow-up
question ("could background CAC simply be enabled, is the feature built
for the hardware?") was investigated to ground truth, not assumed:

1. **The DT flag isn't the real gate.** `target/linux/mediatek/dts/
   mt7622-linksys-e8450.dtsi` does set `mediatek,disable-radar-background`
   on the `wifi@0,0` node, and the driver only advertises
   `NL80211_EXT_FEATURE_RADAR_BACKGROUND` when that flag is absent
   (`mt7915/init.c`). But removing it would only change what capability
   bit `iw phy info` reports — not whether the feature actually works.
2. **Actually using it requires a second internal radio.** MT7915's
   `.set_radar_background` callback (`mt7915_set_radar_background()`,
   `mt7915/main.c`) designates a *second* `mt7915_phy` instance
   (`dev->rdd2_phy`) to continuously scan a different channel for radar
   while the primary phy keeps serving clients on its own channel — one
   radio can't tune to two channels at once. That second phy
   (`phy2`/`ext_phy`) is only ever allocated by `mt7915_alloc_ext_phy()`
   when `dev->dbdc_support` is true: MT7915 operating as a single chip
   internally split into two simultaneous radio contexts
   (Dual-Band-Dual-Concurrent).
3. **This board's MT7915 doesn't run DBDC.** The E8450's MT7915 PCIe
   card is a single-band 5GHz-only radio — 2.4GHz is served by the
   entirely separate SoC-internal MT7615/WMAC chip, not by this card in
   a second internal band context. So `dbdc_support` is false and `phy2`
   is never allocated, independent of any DT/UCI setting.
4. **Confirmed live on the router** (read-only checks against
   192.168.1.1, no state changed): exactly one 5GHz `wiphy` exists
   (`wl1`; `/sys/class/ieee80211/` lists only `wl0`/`wl1`, no third phy).
   The mt76 debugfs directory for `wl1` contains `dfs_hw_pattern` and
   `rdd_monitor` (created when `!dev->dbdc_support`, matching source) but
   no functioning background-radar path; `rdd_monitor` reads back an
   error rather than monitor state, consistent with `dev->rdd2_phy`
   never being set. The on-chip EEPROM's chip ID reads `0x7915` (base
   MT7915), and `mt7915_eeprom_has_background_radar()` returns `true`
   unconditionally for that exact chip ID — i.e. **the silicon itself
   isn't the limiter; the missing second radio/PHY on this board is.**

So the honest answer is no: this isn't a case of "the feature exists,
someone just turned it off." The capability requires hardware this card
doesn't have (a second internal radio path dedicated to scanning while
the primary keeps serving). Removing the DT flag would, at best, be a
no-op (advertise a capability bit that still can't be invoked because
`phy2` doesn't exist) — worth *not* doing given the downside if some
userspace tool tried to use it anyway: DFS/background-CAC is a
regulatory radar-avoidance mechanism (protecting weather and aviation
radar from Wi-Fi interference), and a capability bit that's advertised
but not actually backed by a working second detector is the wrong kind
of thing to leave ambiguous. Not attempted on the live router for this
reason, on top of it having no path to actually functioning.

**No code fix exists** — DFS itself is a legal/regulatory requirement on
this channel, not a bug, and background CAC is a hardware capability this
card doesn't have. The only lever is moving to a non-DFS 5GHz channel
(36-48 or 149-165), which sidesteps the whole radar-detection question
rather than trying to make it non-disruptive. Whether that's actually a
net win for *this* router's specific location (co-channel interference
from neighboring APs, walls, distance) **cannot be asserted without an
on-site RF survey** — this remains the one concrete, actionable lever in
this document, but the decision to use it depends on information only
available on-site.

### Investigated, low expected value, not applied

- **`rssi_reject_assoc_rssi`/`rssi_reject_assoc_timeout`** (real hostapd
  options, wired through both the legacy and active ucode config
  generators, currently unset/disabled): only rejects *new* association
  attempts below an RSSI threshold. It does nothing for a client that
  associates while strong and degrades mid-session to -73..-81 dBm —
  exactly the previously-documented failure mode. Safe to add (zero
  kernel-patch risk) but low expected value against the actual observed
  symptom without further A/B; not added.
- **802.11k/v (RRM neighbor reports, BSS Transition Management)**: real,
  wired UCI options, currently off. Their main value is steering a client
  toward a *different, stronger* AP — this deployment has exactly one
  5GHz radio, so there is no second AP to steer to. Not recommended for
  this topology.
- **Airtime fairness** (`airtime_mode`, mt76 advertises
  `NL80211_EXT_FEATURE_AIRTIME_FAIRNESS`, currently off): arbitrates
  bandwidth *between* multiple associated stations; does not change one
  client's own retry/rate-fallback behavior, so it would not address the
  single-client symptom already root-caused to weak per-chain RSSI. Not
  the right tool for this symptom. (Distinct from NETSYSv1's *hardware*
  QDMA scheduler, already confirmed dead/non-enforcing in
  `docs/netsys-qos-port-investigation.md` §28.5 — this is mt76's
  separate Wi-Fi-side software mechanism.)
- **Beacon interval / DTIM period / listen interval**: all at hostapd
  schema defaults (`beacon_int=100`, `dtim_period=2`), not misconfigured.
  Nothing in the prior smoke-test evidence points at beacon timing.
  Changing them is a safe, reversible UCI lever but has no a-priori
  reason to expect improvement; not applied.

### Investigated, confirmed unavailable (real negative results)

- **Rate-control aggressiveness**: MT7915 sets
  `IEEE80211_HW_HAS_RATE_CONTROL`, meaning mac80211's `minstrel_ht` is
  never invoked — rate selection is 100% closed MCU-firmware-side
  (`mt7915_mcu_add_rate_ctrl()`, whose own comment states the firmware
  algorithm overrides host-supplied rate hints). No module param,
  debugfs counter, or UCI option in this tree influences retry count or
  fallback aggressiveness at a given MCS. The only host override
  (`fixed_rate` via debugfs) *disables* adaptive fallback entirely — the
  opposite of what stability needs. Closed off as a real negative result,
  not a missing config.
- **Per-chain TX power balancing**: `mt7915_set_antenna()` only exposes a
  whole-chain enable/disable bitmask, not per-chain power weighting; the
  observed per-chain RSSI asymmetry is a receive-side propagation/antenna
  effect that AP-side TX power (even if adjustable per-chain, which it
  isn't) couldn't correct from the AP side anyway.
- **AMPDU aggregation cap**: unconditionally set to the HE maximum (256
  subframes) for every station regardless of measured link quality
  (`hw->max_tx_aggregation_subframes = IEEE80211_MAX_AMPDU_BUF_HE`,
  `mt7915/init.c`). This matches the theory that larger aggregates
  amplify loss at one retry-exhaustion event near the edge of range, but
  there's no UCI/module knob to reduce it — only a new kernel patch
  could, and that patch would be driver-wide (affects every station, not
  just weak-signal ones), with real throughput risk for strong-signal
  clients. Flagged as the deepest, most speculative lever investigated;
  **not attempted** without live A/B evidence that the shallower items
  above are insufficient first.
- **Vendor roaming-assistant patch**: searched this tree's own
  `target/linux/mediatek/patches-6.12/` (all `999-wed-*`/`999-eth-*`/
  `999-ppe-*`/`999-qos-*` patches are WED/PPE/Ethernet-QoS, none touch
  mt76 rate control or retry limits) and the public
  `mediatek/mtk-openwrt-feeds` project referenced elsewhere in this
  repo's docs. No MT7915-applicable min-RSSI-kick, retry-tuning, or
  roaming-assistant patch was found in either place. Real negative
  result, not an absence-of-evidence guess.

## What this doesn't cover

Everything already closed by prior investigation remains closed and was
not reopened here: the controlled-SER MT7915 MCU-death failure
(`docs/e8450-ppe-validation.md`, unfixable from host driver source,
auto-reboot watchdog already shipped), the WED-v1 ring-desync and PSE
port-mapping bugs (both fixed, `999-wed-13`/`999-wed-14`), and NETSYSv1's
confirmed-dead hardware AQM/second-scheduler capability
(`docs/netsys-qos-port-investigation.md` §28.5).
