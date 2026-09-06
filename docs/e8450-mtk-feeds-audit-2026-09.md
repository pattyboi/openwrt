
# mtk-openwrt-feeds 2026-09 audit

Scope: audit `mediatek/mtk-openwrt-feeds` (`25.12/files/target/linux/mediatek/patches-6.12`,
309 files — the actual vendor source this fork's own `999-*` series is drawn
from) and `immortalwrt/immortalwrt` (both `master` and the version-matched
`openwrt-25.12` branch) for anything new and useful to the Linksys E8450
(MT7622, NETSYSv1, WED-v1) that isn't already in this tree. Same methodology
as every other doc here: read the actual patch diff, then confirm applicability
against this fork's real built source (`build_dir/.../linux-6.12.103/...`) and
real chip-version gates — not the patch's own commit message.

## TL;DR

`immortalwrt/immortalwrt` produced nothing usable: its MT7622 coverage is
stock-upstream board support (no NETSYSv1 QoS/WED work of its own), and its
one candidate feature (`600-mac80211-allow-vht-on-2g.patch`, a blanket
no-opt-in VHT-on-2.4GHz hack) is inferior to this fork's own already-applied
`200-mac80211-introduce-support-for-vendor-QAM-256-in-2.4.patch` (Christian
Marangi's upstream-submitted, per-driver-opt-in version). The one config
difference found (`kmod-usb3` present upstream, absent here) traced to this
fork's own deliberate commit `905442e6` ("remove unused E8450 image
baggage") — not a regression.

`mtk-openwrt-feeds` produced five real, verified-applicable findings not yet
in this tree (§1-5 below) and two items worth a controlled test before
adopting (§6-7). Everything else checked (~20 additional patches read in
full) is gated to NETSYSv2/v3 (`mtk_is_netsys_v2_or_greater`/`v3_or_greater`,
`mtk_wed_is_v2`/`v3_or_greater`), targets a different chip family entirely,
already fixed in this tree's mainline-derived baseline, dead code for this
build's config, or already explicitly ported/superseded by this fork's own
work (confirmed via that work's own patch headers/comments referencing the
same feed).

## Real findings — applicable now, low risk

### 1. `999-ppe-13`: multicast PPE entries get the wrong CDMA CPU reason

**Verified live and unpatched** in this tree's built source:

```
build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_mt7622/linux-6.12.103/
  drivers/net/ethernet/mediatek/mtk_ppe.c:406-407
    if (is_multicast_ether_addr(dest_mac))
        val |= mtk_get_ib2_multicast_mask(eth);
```

Vendor's own description: "the CDMA may receive an incorrect PPE CPU reason
with a multicast packet, resulting in abnormal operation of the CDMA."
`mtk_foe_entry_prepare()`, no chip-version gate — a straight 3-line removal.
Every home LAN generates mDNS/SSDP/IGMP multicast traffic that traverses
this exact FOE-entry-prepare path under the bridged PPE offload this fork
already relies on (`999-ppe-90`). Highest-value, lowest-risk find of this
audit.

Source: `999-ppe-13-mtk_ppe-delete-ib2-mcast-bit-from-ppe-entry.patch`.

### 2. `999-eth-53`: MDIO busy-wait race gives false timeouts

`mtk_mdio_busy_wait()` polls `PHY_IAC_ACCESS` in a loop, checking
`time_after(jiffies, deadline)` *after* the register check. If the CPU is
preempted in that window and the PHY finishes during the preemption, the
function reports `-ETIMEDOUT` on a hardware access that actually succeeded.
Fix replaces the hand-rolled loop with `read_poll_timeout()`, which performs
a final register read before declaring a timeout. Generic, no chip gate,
21 lines, and this board's MT7531 switch is driven over exactly this
internal MDIO bus.

Source: `999-eth-53-mtk_eth_soc-fix-spurious-mdio-timeout.patch`.

### 3. `999-dsa-06`: MT7531 VLAN deletion doesn't override the FID

`mt7530_hw_vlan_del()`, when a VLAN entry still has member ports after one
port is removed, wrote the updated `VAWD1` register without also setting
`FID(FID_BRIDGED)`. A 2-line fix in `mt7530.c` — the exact DSA switch driver
this board's 4-port LAN/WAN switch uses. Real correctness bug in
bridge/VLAN table maintenance, not chip-version-gated.

Source: `999-dsa-06-fix-mt7531-vlan-del-to-override-fid.patch`.

### 4. `999-ppe-36`: PPE hardware-offload bypass via conntrack mark `0x99`

New primitive in `mtk_flow_offload_replace()`: if a flow's conntrack entry
has `ct->mark == 0x99`, the PPE refuses to hardware-bind it
(`return -EOPNOTSUPP`), keeping it on the software/CAKE path permanently.
No chip-version gate.

This is directly relevant to the open question in
[`e8450-download-shaping-handoff.md`](e8450-download-shaping-handoff.md):
whether a WiFi client's PPE-hardware-offloaded download bypasses CAKE
shaping. Today that question can only be answered indirectly (register
inference, `999-qos-06`'s reactive occupancy-driven eviction after the
fact). With this patch, `nft ... ct mark set 0x99` on a known test flow
gives a declarative, direct answer — and a permanent mitigation for flows
you already know you want shaped — instead of relying solely on the
reactive eviction machinery.

Source: `999-ppe-36-mtk_ppe-add-binding-bypass-by-ct-mark-0x99.patch`.

### 5. `613-netfilter-optional-tcp-window-check`

Adds `nf_conntrack_tcp_no_window_check` (vendor default: **on**), which
disables conntrack's TCP window-continuity check
(`tcp_in_window()` in `nf_conntrack_proto_tcp.c`). This is a standard
MediaTek fix for hardware-flow-offload boards: a flow that gets evicted
from PPE hardware back to software (exactly what this fork's
`999-qos-06` AQM eviction does) can have a TCP window state in conntrack
that's stale, because the hardware datapath never updated
`ct->proto.tcp.last_win` while the flow was offloaded — conntrack then
judges the first post-eviction packet invalid and drops/resets it.
Plausible direct interaction with this fork's own AQM eviction path.

**Tradeoff, stated explicitly per this project's own convention:**
disabling the window check removes one conntrack sanity check against
off-path TCP sequence/window injection or desync. This is the standard
router-vendor tradeoff (most MediaTek-based OpenWrt vendor builds ship
this enabled specifically for offload compatibility), but it should be
named, not silently accepted.

Source: `613-netfilter-optional-tcp-window-check.patch`.

## Worth a controlled A/B, not a blind port

### 6. `999-eth-17`: NAPI poll weight 64 → 256

`netif_napi_add()` (implicit default weight, `NAPI_POLL_WEIGHT` = 64) →
`netif_napi_add_weight(..., MTK_NAPI_WEIGHT)` with `MTK_NAPI_WEIGHT` = 256,
for TX NAPI, RX NAPI, RSS rings, and HW-LRO rings. No chip-version gate —
applies as-is to NETSYSv1. Real throughput lever: fewer softirq
enter/exit cycles per unit of traffic on this exact 2-core Cortex-A53 SoC.

**Tension worth naming**: this fork's entire AQM story
(`netsys-qos-port-investigation.md`) is about capping tail latency
(`grace_ms` tuned down to 1000 ms specifically for lower p95 latency). A
4x larger NAPI budget trades fewer poll-cycle transitions for more work
(and potentially more queuing latency) done per cycle. Test under the
existing saturating-load latency harness before adopting; do not assume
throughput-only benefit carries no latency cost on this board.

Source: `999-eth-17-mtk_eth_soc-change-napi-poll-weight-to-256.patch`.

**Update (2026-09-05): tested, adopted.** Ported as
`target/linux/mediatek/patches-6.12/999-eth-17-mtk_eth_soc-change-napi-poll-weight-to-256.patch`,
adapted for this fork's non-RSS/HWLRO `mtk_probe()` (two
`netif_napi_add()` calls, not a `rx_napi[]` array). Built, flashed live
(`r33087-10b027e38a`), clean boot. A/B'd against the pre-flash baseline
with `scripts/e8450/saturating-load-harness.sh` (3 reps each side,
same session, same real household-traffic conditions):

| | sent (Mbit) | avg (ms) | p50 | p95 | p99 | max | loss |
|---|---:|---:|---:|---:|---:|---:|---:|
| baseline | 3.29 | 34.5 | 30.9 | 48.0 | 104.2* | 164.9* | 0.35% |
| post-`eth-17` | 4.47 | 32.9 | 31.4 | 45.3 | 49.7 | 55.3 | 0.35% |

(*baseline p99/max dominated by one rep-3 outlier — a single real-
traffic spike not reproduced elsewhere.) No latency regression (p50
flat within noise, p95/p99 slightly lower once the outlier is set
aside, identical 0.35% loss both sides), throughput +36%. Small sample
(3×~19s reps/side) — real signal is "no regression, mild throughput
gain," not a large effect size. Full detail:
`e8450-upstream-roadmap-2026-09.md` Task 8.

### 7. `999-wdt-01`: watchdog timeout register overflow clamp

`mtk_wdt_set_timeout()` computes `WDT_LENGTH_TIMEOUT(timeout << 6)` with no
clamp against the hardware's representable range. `mtk_wdt.c` sets
`min_timeout` and `max_hw_heartbeat_ms` on the `watchdog_device`, but never
sets `max_timeout` — so the kernel watchdog core has no upper bound to
reject an oversized `WDIOC_SETTIMEOUT` request before it reaches this
driver's register write, which could then silently overflow to a much
shorter real hardware timeout than requested.

**Not confirmed live on this deployment**: `wdt_dev.timeout` defaults to
`WDT_MAX_TIMEOUT` (the hardware's own max) at probe time, and nothing in
`files/etc/config/system` requests a longer timeout, so the overflow path
is currently unreachable. Real defensive fix, dormant under current
config — flag for backport if a future config ever requests a custom
watchdog timeout, not urgent otherwise.

Source: `999-wdt-01-add-clamp-to-set-timeout.patch`.

## Checked and ruled out, with evidence

- **`999-wed-01`** (hwrro double-free in `mtk_wed_rx_reset`): dead code on
  this board. `dev->wlan.hw_rro` is only ever set `true` by `mt7996`
  (WiFi-7/WED3 driver) — grepped the pinned `mt76-2026.08.04~6d1c6a75`
  source tree directly, confirmed `mt7915` (this board's 5GHz chip) never
  sets it. `mtk_wed_hwrro_free_buffer()` returns at its first guard
  (`if (!dev->wlan.hw_rro) return;`) both times it's called here, so the
  described double-free never executes.
- **`999-wed-03`** (WDMA RX hang on WED1 after SER): hunk 1's
  `if (dev->rx_wdma[i].desc) continue;` → `if (!dev->rx_wdma[i].desc)
  continue;` fix is **already correct** in this tree's built
  `mtk_wed.c:260` — inherited from the current mainline-derived baseline,
  not something this vendor patch needs to add. Hunk 2 (prefetch
  index/FIFO reset) sits inside `mtk_wed_reset_dma()`'s
  `if (mtk_wed_is_v3_or_greater(dev->hw))` branch — confirmed by the
  patch's own hunk context/indentation matching that branch in this
  tree's source — not reachable on WED-v1.
- **`999-wed-11`** (`mtk_ppe_drop_config`): the function itself opens with
  `if (mtk_is_netsys_v1(eth)) return;` — self-excluding for this exact
  chip generation.
- **`999-wed-14`** (feed), **`999-wed-19`**, **`999-wed-22`**: gated
  `mtk_wed_is_v3_or_greater`/`mtk_wed_is_v2`. Not reachable on WED-v1.
  (Note: this fork's own local `999-wed-14` is an unrelated, self-invented
  fix with a coincidentally identical patch number — not a port of the
  feed's `wed-14`.)
- **`999-wed-20`**: already tracked as this fork's own open Task 3
  (`e8450-upstream-roadmap-2026-09.md`) — same patch, same 1.5s→100ms
  `mtk_wed_poll_busy()` change, no new information from this pass.
- **`999-ppe-23`** (keep-DSCP toggle) and **`999-eth-26`** (PPPQ shaper
  refcnt): both gated `mtk_is_netsys_v3_or_greater`. Not reachable.
- **`999-eth-33`** (dynamic RX buffer sizing up to 9K): not chip-gated,
  but only changes behavior above the default 1500-byte MTU (jumbo
  frames); this deployment runs standard MTU. Not actionable unless jumbo
  frame support is wanted.
- **`999-eth-20`** (HQoS register save/restore across QDMA SER) and
  **`999-eth-27`** (skb-mark queue select): already evaluated and
  superseded by this fork's own work. `999-qos-07`'s header states
  "Port of MediaTek vendor patch eth-27 (mtk-openwrt-feeds)" verbatim.
  `999-qos-08`'s comment explicitly notes eth-20's register-snapshot
  approach is redundant with this fork's own
  `mtk_qdma_v1_apply_all()` re-derivation (`999-qos-03`) — only the AQM
  priming-baseline bug needed a separate fix, which `999-qos-08` already
  supplies.
- **`999-dsa-01`** (SGMII individual polarity control): the diff
  hardcodes a fixed `MTK_SGMII_FLAG_PN_SWAP_TX` flag in
  `mt7531_create_sgmii()`, not the DT-property mechanism
  (`mediatek,pnswap*`) its own commit message describes — patch content
  doesn't match its description. E8450's `mt7531` node in
  `mt7622-linksys-e8450.dtsi` uses a `fixed-link` CPU port, not an
  explicit SGMII PCS configuration reachable from this call path, and no
  polarity/link defect has ever been observed on this board. Skip
  without concrete hardware evidence of a link problem.
- **`999-ppe-18`** (`xt_FLOWOFFLOAD` memory leak): dead code path — this
  build's `.config` selects `kmod-nft-offload` only, not the legacy
  iptables `xt_FLOWOFFLOAD` target. Already covered in the code path that
  matters by this fork's own `999-ppe-91`
  (`nft_flow_offload`-fix-memory-leak-issue).
- **`999-ppe-45`** (source-MAC rewrite for 3-address station egress):
  station/mesh-uplink (`apcli`) only. This deployment is AP-only.

Not exhaustively reviewed this pass (lower-priority diagnostics/newer
hardware, filenames scanned but full diffs not read): `999-wed-08`
(929-line extended WED debugfs), `999-tphy-02`, `999-ppe-44` (hash debug
mode), `999-trng-01`. Revisit if a specific need arises.

## immortalwrt/immortalwrt — no action items

- `target/linux/mediatek/patches-6.12` (`openwrt-25.12` branch, 139 files)
  and `patches-6.18` (`master`, current): every filename is MT7988/MT7987/
  MT7623/MT7986 board-specific (bpi-r2/r3/r4, AS21xxx PHY, EIP97/EIP197,
  spi-nand vendor variants). Zero files touch `mtk_eth_soc.c`,
  `mtk_ppe.c`, `mtk_wed*.c`, or `mt7530*.c` — the exact drivers this fork
  has hand-patched.
- `package/kernel/mt76/patches`: one file, an MT7996 tx-power-from-fw fix.
  Wrong chip family (this board is MT7615/MT7915).
- `package/kernel/mac80211/patches/subsys`: 19 files, all already
  superset-covered by this fork's own set, except
  `600-mac80211-allow-vht-on-2g.patch` — a blanket, no-opt-in VHT-on-2.4GHz
  hack (`flags & (DISABLED|NO_80MHZ) & (band != 2GHZ)`, applies to every
  mt76 chip unconditionally). This fork's own
  `200-mac80211-introduce-support-for-vendor-QAM-256-in-2.4.patch`
  (Christian Marangi's actual upstream-submitted series, already applied)
  does the same thing correctly with a per-driver opt-in flag
  (`vendor_qam256_supported`) so unsupported chips don't get bogus
  capability advertisement. Already superior; nothing to pull.
- `target/linux/mediatek/image/mt7622.mk`: only diff for
  `linksys_e8450`/`linksys_e8450-ubi` is `kmod-usb3` in `DEVICE_PACKAGES`
  (present in both immortalwrt and stock upstream OpenWrt, absent here).
  Traced to this fork's own commit `905442e6` ("config: remove unused
  E8450 image baggage", 2026-09-04), consistent with this project's own
  finding that "xHCI is present but has no attached USB device; no USB
  backport has a current payoff." Deliberate, not a regression — not
  recommending a revert.
- `base-files/etc/board.d/{01_leds,02_network,05_compat-version}`:
  byte-identical to this tree's for MT7622 (only extra entries are
  TP-Link boards this tree doesn't carry).

## Suggested next steps

- [ ] Backport and hardware-test `999-ppe-13`, `999-eth-53`, `999-dsa-06`
  together as one low-risk correctness batch (no interaction between
  them — different files/functions).
- [ ] Evaluate `999-ppe-36` against the open download-shaping question in
  `e8450-download-shaping-handoff.md`: mark the test client's known bulk
  flow with `ct mark set 0x99`, confirm it stays off PPE hardware
  offload, and check whether CAKE now sees and shapes it.
- [ ] Decide on `613-netfilter-optional-tcp-window-check` with the named
  tradeoff in mind; if adopted, verify it actually reduces or eliminates
  any drops/resets observed immediately after an AQM eviction event.
- [ ] A/B `999-eth-17` (NAPI weight 256) against the existing
  saturating-load latency harness before adopting — do not assume
  throughput-only benefit.
- [ ] `999-wdt-01`: no action needed unless a future config requests a
  custom (non-default) watchdog timeout.
