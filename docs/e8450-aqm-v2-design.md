# E8450 AQM v2 — design (2026-09-06)

Status: **implemented, build-verified, flashed, and hardware-tested
(2026-09-06).** Phase C/A always-on; Phase B (`hold_ms`) confirmed
working live but shipped **opt-in, default off** pending a larger A/B
— see §10. Scopes the next AQM iteration now
that `999-ppe-93` (PPE hardware-offload bypass via `ct mark`) is live in
this tree. Every claim below is grounded in this fork's own patched source
(`target/linux/mediatek/patches-6.12/999-qos-*`, `999-ppe-93`) and the
generic (unpatched) kernel source in
`build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_mt7622/linux-6.12.103/`
(`net/netfilter/nf_flow_table_core.c`, `nf_flow_table_offload.c`,
`nf_conntrack_qos.c`) — line numbers cited are from that build tree at
kernel `6.12.103`, this fork's exact live pin.

Precedent for the v1 AQM design and its own measured results:
[`netsys-qos-port-investigation.md`](netsys-qos-port-investigation.md).
Precedent for the ct-mark primitive this design builds on:
[`e8450-mtk-feeds-audit-2026-09.md`](e8450-mtk-feeds-audit-2026-09.md) §4.

## 1. Problem statement — what v1 actually does today

`999-qos-06` (`mtk_qdma_aqm_work()` → `mtk_qdma_aqm_unbind_queue()`,
`mtk_eth_soc.c`), on trigger, calls `mtk_foe_entry_clear()` directly on
up to `batch` FOE entries qos-13's ranking picked. That function
(`mtk_ppe.c:855-861`) does exactly two things: writes
`MTK_FOE_STATE_INVALID` to the hardware slot, and sets
`entry->hash = 0xffff` on **this driver's own** `eth->flow_table` entry.
It does **not** touch anything in the generic kernel's `nf_flowtable`
(`net/netfilter/nf_flow_table_core.c`) — the `struct flow_offload` object
nftables' flowtable created for this connection is left completely
untouched: `NF_FLOW_HW` stays set, `IPS_OFFLOAD_BIT` stays set on the
conntrack entry, and `flow->timeout` keeps getting refreshed by
`flow_offload_refresh()` as long as `nf_flow_offload_stats()` polling
believes the flow is still active.

Two concrete consequences, verified by reading the generic flowtable
source, not inferred from the AQM patch alone:

1. **The driver's own `eth->flow_table` accrues zombie entries.** Compare
   `mtk_qdma_aqm_unbind_queue()`'s `mtk_foe_entry_clear()`-only call
   against the *proper* full teardown this exact driver already
   implements in `mtk_flow_offload_destroy()`
   (`mtk_ppe_offload.c:670-688`): hardware invalidate **plus**
   `rhashtable_remove_fast()` **plus** `kfree(entry)`. qos-06's evicted
   entries stay resident in `eth->flow_table` (skipped on later walks via
   the existing `entry->hash == 0xffff` guard, so they're inert, but
   they're never freed by qos-06 itself — only reclaimed whenever
   generic flowtable GC eventually calls back into
   `mtk_flow_offload_destroy()` for the same cookie).
2. **Re-offload timing after an eviction is governed by a generic,
   congestion-blind timer, not by the AQM.** `include/net/netfilter/nf_flow_table.h:191`:
   `#define NF_FLOW_TIMEOUT (30 * HZ)`. `nf_flow_table_core.c:446-453`:
   the flowtable's own `gc_work` runs every `HZ` (1 s) and only tears a
   flow down (`flow_offload_teardown()` → eventually
   `nf_flow_offload_del()` → the driver's `.destroy` callback) once
   `nf_flow_has_expired()` is true — i.e. once **30 s** of (apparent)
   inactivity has passed. Nothing about qos-06's own `grace_ms`
   (currently 1000 ms) or the live rate/drop trigger state feeds into
   that decision at all. Once the zombie flow finally gets torn down and
   a fresh packet arrives, a **new** `flow_offload_add()` is attempted,
   `mtk_flow_offload_replace()` runs again, and (absent `999-ppe-93`'s
   check) the flow is immediately hardware-offload-eligible again — with
   no relationship to whether the WAN queue is still congested.

This matches this project's own already-documented, previously-
unresolved gap: "hardware-queue latency blind spot during the AQM grace
window… no continuous depth control exists on this silicon" — the AQM
detects and reacts, but has no durable say over *how long* an evicted
flow stays off hardware.

## 2. What `999-ppe-93` adds, and what it doesn't fix by itself

`999-ppe-93` (`mtk_ppe_offload.c:426-427`) adds exactly one check to
`mtk_flow_offload_replace()`: `if (f->flow->ct->mark ==
MTK_PPE_EXCEPTION_TAG) return -EOPNOTSUPP;`. This is a **preventive**,
declarative "refuse future binds" primitive — the missing piece that
lets an eviction *stick* instead of being subject to the generic 30 s
timer. But it only fires on a fresh `.replace()` call; it does nothing
to a flow that is *already* hardware-bound, and qos-06 has no code path
that ever sets it. The two mechanisms are complementary, not
substitutes for one another, and neither one closes gap #2 above alone.

## 3. Other implementations surveyed for precedent

Per the request to look elsewhere before designing: surveyed every
mainline driver implementing `FLOW_CLS_REPLACE` (hardware-flowtable-
offload-capable NICs — `bnxt_tc.c`, `mlx5/core/en_tc.c`, `en/tc_ct.c`,
`nfp/flower/{offload,conntrack}.c`, `sfc/tc*.c`, `mlxsw`, `mscc/ocelot`,
and others) for any of: proactive congestion/table-pressure eviction of
an already-bound flow, or a driver calling back into
`flow_offload_teardown()`/`flow_offload_lookup()` on its own initiative.
**None exist.** `EXPORT_SYMBOL_GPL(flow_offload_teardown)` and
`EXPORT_SYMBOL_GPL(flow_offload_lookup)` (`nf_flow_table_core.c:351,376`)
are only ever called from `net/netfilter/*.c` itself (GC, nft rule
removal, ct destruction) — no in-tree hardware-offload driver reaches
back into the generic flowtable to request its own flow's removal.
Every other driver's `.replace()` just returns an error (`-ENOSPC`
typically) when its own hardware table is full and lets the generic
layer keep the flow in the *software* fastpath; none implement anything
resembling a congestion-driven active-eviction policy. **Conclusion:**
this fork's own qos-06 is genuinely novel territory here — there is no
peer driver implementation to copy the eviction *policy* from. What
mainline *does* supply, and what v2 should actually adopt, is the
generic flowtable's own **consistency contract** (`NF_FLOW_HW`,
`NF_FLOW_HW_DYING`/`NF_FLOW_HW_DEAD`, `NF_FLOW_TEARDOWN`,
`IPS_OFFLOAD_BIT`) that every other driver's `.destroy` path already
participates in correctly — which qos-06 currently bypasses entirely by
calling `mtk_foe_entry_clear()` directly instead of going through it.

Also checked `net/netfilter/nf_conntrack_qos.c`/`nf_conntrack_qos.h` on
the chance upstream already had a per-flow "don't hardware-offload this"
extension to build on: it doesn't — `struct nf_conn_qos` is a
per-direction ToS value + byte counter (DSCP/fairness accounting), an
unrelated feature that happens to share the word "qos". No redirection
of this design.

## 4. v2 design

Three independent, additively-adoptable pieces. All three insert into
the **same** RCU-walk loop in `mtk_qdma_aqm_unbind_queue()` where
`mtk_foe_entry_clear()` is already called (`mtk_eth_soc.c:1447-1490`,
post-qos-15's single-pass form) — no new walk, no new lock acquisition
beyond what's described below.

### 4.1 Resolve `struct flow_offload *` from the entry already in hand

`struct mtk_flow_entry` (`mtk_ppe.h:288-310`) stores `entry->cookie`
(`= f->cookie`, set once at bind time, `mtk_ppe_offload.c:645`).
`nf_flow_table_offload.c:903`: `cls_flow->cookie = (unsigned long)tuple`
— the cookie **is** a `struct flow_offload_tuple *` (specifically
`&flow->tuplehash[dir].tuple`), the exact same object
`flow_offload_lookup()` itself resolves via `container_of()`
(`nf_flow_table_core.c:353-375`). So:

```c
struct flow_offload_tuple *tuple = (void *)entry->cookie;
struct flow_offload *flow =
    container_of(tuplehash, struct flow_offload, tuplehash[tuple->dir]);
```

**Safety, verified not assumed:** `flow_offload_free()`
(`nf_flow_table_core.c:209-221`) frees via `kfree_rcu(flow, rcu_head)` —
RCU-deferred. `mtk_qdma_aqm_unbind_queue()` already runs inside
`rhashtable_walk_start()`'s RCU read-side critical section (this is the
exact same guarantee qos-06's own existing comment already relies on for
`entry` itself: "RCU-protected and will not be freed until after
rhashtable_walk_stop()"). RCU grace periods are global, not
per-rhashtable: holding `rcu_read_lock()` anywhere blocks *any*
`kfree_rcu()`-scheduled reclaim everywhere. `nf_flow_offload_gc_step()`
itself dereferences `flow->ct` directly under nf_flowtable's *own* RCU
walk with no extra refcounting (`nf_flow_table_core.c:412-424`) — the
same discipline applies here since we're inside an equivalent RCU
region, just a different rhashtable's walk. **Conclusion: memory-safe to
dereference `flow`/`flow->ct` here without an additional reference —
verified by tracing the exact free path, not assumed.** The cookie may
point at an already-torn-down (but not yet freed) `flow_offload`; every
operation in 4.2/4.3 below is idempotent against that, so no extra
liveness check is required before calling them.

### 4.2 Synchronize the generic flowtable's state on eviction

Call `flow_offload_teardown(flow)` (`nf_flow_table_core.c:344-350`,
`EXPORT_SYMBOL_GPL`) immediately alongside the existing
`mtk_foe_entry_clear()` call. This is the exact call every other
teardown path in the kernel makes; it does no hardware I/O and takes no
blocking locks (verified by reading its body — `nf_ct_qos_clear()` is an
extension lookup, the rest is bitops and a `WRITE_ONCE`), so it's safe
to call from qos-06's existing BH/RCU context. Effects: clears
`IPS_OFFLOAD_BIT` on the conntrack entry (closing gap #2's "generic
30 s timer decides" problem at the *belief* layer — nf_flowtable's
bookkeeping now matches reality immediately instead of drifting until
its own GC catches up), marks `NF_FLOW_TEARDOWN` (so
`flow_offload_lookup()` stops fast-pathing this flow immediately, not
after 30 s), and fixes up the conntrack timeout for the switch back to
the normal path. The actual hardware-side FOE invalidate stays the
existing synchronous `mtk_foe_entry_clear()` call — deliberately **not**
routed through the generic `nf_flow_offload_del()` async-workqueue path,
which is only reachable from within `net/netfilter/*.c` (not exported)
and would in any case add up to ~1 s of extra hardware-still-bound
latency (its own `gc_work` cadence) that the AQM's whole point is to
avoid.

`mtk_flow_offload_destroy()`'s full teardown
(`rhashtable_remove_fast()` + `kfree(entry)`) still isn't run here —
that's `eth->flow_table`-local bookkeeping cleanup, orthogonal to this
fix, and already inert-but-harmless per the existing `hash == 0xffff`
skip guard. Not in scope for v2; a real cleanup would need its own
audit of `mtk_flow_offload_destroy`/`stats` cookie-lookup call sites
before touching entry lifetime.

### 4.3 Make eviction stick: congestion-aware ct-mark hold

Set `flow->ct->mark` to the exception tag (namespace question — §5) at
the same point, and track it in a small bounded table (reuse the
existing `batch`-capped array pattern qos-13/15 already established, no
new allocation): `{ struct nf_conntrack_tuple, unsigned long
marked_jiffies }`, up to `MTK_QDMA_AQM_MAX_BATCH` (64) live holds.
Clear the mark (write back the mark value it had before, tracked in the
same record) once **both**: `hold_ms` (new debugfs knob, independent of
`grace_ms`) has elapsed since it was marked, **and** the AQM has not
retriggered since. This makes "how long does this flow stay off
hardware" an actual congestion-aware AQM decision — release happens when
the AQM itself observes the queue has been quiet, not on nf_flowtable's
context-free 30 s idle timer.

**Bounded, not unbounded**: capped at 64 concurrently-held marks
(matches the existing `MTK_QDMA_AQM_MAX_BATCH`); a hold-table walk to
check expiry runs once per `mtk_qdma_aqm_work()` poll cycle
(`poll_ms`-scale, not per-packet), same cadence discipline as the rest
of qos-06.

**Overwrite-safety**: writing `ct->mark` clobbers whatever value was
there before, including this tree's own `30-queue-mark.nft` priority
marks (7/8) or any future explicit-queue value — see §5, this is the
same value-space problem `999-ppe-93` already has, sharpened by v2
actually writing (not just reading) the field on a hot path. The
held-record must save/restore the prior mark value, not just set/clear
a magic constant, or a held bulk flow permanently loses its priority
classification on release.

### 4.4 Debugfs surface

Extend the existing `qdma_aqm` file
(read format: `enabled=N queue=N poll_ms=N byte_thresh=N batch=N
grace_ms=N trigger_count=N unbind_total=N`, write format: `enable
<queue> [poll_ms [byte_thresh [batch [grace_ms]]]]` /
`disable`) with one further optional positional write argument,
`hold_ms` (default: equal to `grace_ms`, range 0–60000; **`0` disables
the whole ct-mark-hold mechanism and reverts exactly to v1's
`mtk_foe_entry_clear()`-only behavior — the rollback/kill-switch**), and
two new read-only counters: `holds_active=N` (current hold-table
occupancy) and `holds_released=N` (lifetime release count, the v2
analogue of `unbind_total` — lets a live test distinguish "evicted and
immediately re-eligible" from "evicted and actually held").

## 5. Namespace fix — narrower than first proposed

My initial recommendation (a separate write-up before this doc) was "use
a dedicated bit instead of the exact-value match." That undersells the
actual constraint: `999-ppe-04`/`999-ppe-11`'s HQoS queue-select logic
(`mtk_ppe_offload.c:361-376`) already interprets **the entire 32-bit**
`ct_mark` as queue-select data in `qos_toggle==2` mode — low 16 bits
(`ct_mark & MTK_QDMA_QUEUE_MASK`, `MTK_QDMA_QUEUE_MASK = (1ULL<<16)-1`)
as the upload queue, high 16 bits (`ct_mark >> 16`) as the download
queue. There is no unclaimed bit to reserve orthogonally without
shrinking that field, which would mean touching `ppe-04`/`ppe-11`'s
layout and `30-queue-mark.nft` together — a real, separately-scoped
redesign, not a one-line fix, and not needed unless a real requirement
appears for "priority queue N *and* off hardware" on the same flow
simultaneously (not currently expressed anywhere in this tree).

**What v2 actually does about it, scoped down:**
- Confirmed (already, in the prior session) that `999-ppe-93`'s check
  in `mtk_flow_offload_replace()` runs unconditionally *before*
  `mtk_flow_set_output_device()` is ever called (`mtk_ppe_offload.c:426`
  vs `:633`), so `MTK_PPE_EXCEPTION_TAG`'s current low-bits/high-bits
  overlap with valid queue numbers is inert today, by construction of
  that ordering.
- Add one small, independent, low-risk hardening patch (`999-ppe-94`):
  a defensive range clamp inside `mtk_foe_entry_set_queue()`
  (`mtk_ppe.c:634-650`) itself — reject/clamp `queue` to `0-15` before
  the `FIELD_PREP()` call, instead of relying on `FIELD_PREP`'s silent
  truncation. This is correct regardless of the AQM-v2 question at all
  (any future caller passing an out-of-range `ct_mark`-derived queue
  value gets a defined, checked failure instead of a silently-wrong
  queue), and removes the "ordering-dependent safety" fragility named
  in the prior write-up without touching the value-space layout.
- §4.3's save/restore-on-release (not clobber) is the actual mitigation
  for v2's own new *write* path — narrower and sufficient for the
  currently-expressed requirement.
- Defer the bigger field-layout redesign; record it here so it isn't
  re-litigated from scratch if a real "queue N AND bypass" requirement
  shows up later.

## 6. Locking and ordering summary

No new lock is introduced. `qdma_sch_lock` (existing, BH spinlock,
guards `qdma_aqm` state) and `ppe_lock` (existing, BH spinlock, taken
inside `mtk_foe_entry_clear()`/`mtk_foe_entry_get_stats()`) are already
released before the eviction walk per qos-06's own existing comment
("qdma_sch_lock is always released before the rhashtable walk to avoid
nesting"). `flow_offload_teardown()` and the hold-table bookkeeping
(§4.3) take no additional locks beyond what's already documented safe
in §4.1/4.2 — verified by reading their bodies, not assumed. The
hold-table itself needs its own small spinlock (new, leaf lock, never
held across `ppe_lock`/`qdma_sch_lock` acquisition) since it's touched
both from `mtk_qdma_aqm_work()`'s poll cycle and potentially a future
release timer.

## 7. Phased implementation and validation plan

Follows this project's own established methodology (build-verify → real
image build+flash → live hardware A/B against
`scripts/e8450/saturating-load-harness.sh`) rather than a single big
change:

- **Phase A (`999-qos-18`)**: §4.1 + §4.2 only — resolve `flow_offload`
  via cookie, call `flow_offload_teardown()` alongside the existing
  `mtk_foe_entry_clear()`. No ct-mark write, no new debugfs field. Pure
  consistency fix: nf_flowtable's bookkeeping now matches hardware state
  immediately. Testable in isolation: after this alone, does
  `unbind_total`'s cadence or `ppe0/entries` `BND` recovery time change
  at all under sustained real load, compared to the pre-existing
  A/B-disproved-regression baseline (`e8450-mtk-feeds-audit-2026-09.md`
  §4)? Expect little-to-no observable behavior change on its own (this
  phase only fixes bookkeeping drift, not the actual re-offload delay)
  — the real, measurable effect is expected once Phase B lands. Keeping
  it separate makes any regression attributable to a single, small
  diff.
- **Phase B (`999-qos-19`)**: §4.3 + §4.4 — the ct-mark hold/release
  state machine and the `hold_ms`/`holds_active`/`holds_released`
  debugfs surface. `hold_ms=0` at boot (opt-in, not default-on) until
  hardware-validated.
- **Phase C (`999-ppe-94`)**: §5's defensive range clamp. Independent,
  can land/be tested first since it's the lowest-risk piece.
- **Validation, each phase**: `target/linux/clean`+`prepare` (zero
  `.rej`), full `target/linux/compile`, then flash + the existing
  per-image test checklist
  (`e8450-upstream-roadmap-2026-09.md` "Per-image test checklist"), then
  a **new** targeted test this design specifically needs and v1 never
  had a way to measure: **re-offload latency after eviction** — mark a
  known bulk flow's 5-tuple, force an eviction (or wait for a natural
  trigger), and poll `ppe0/entries` at short intervals to measure actual
  wall-clock time from `UNB` back to `BND` (or confirm it never returns
  while genuinely congested) — the metric this whole design exists to
  put under the AQM's own control instead of nf_flowtable's 30 s
  timer. Compare against the pre-v2 baseline using the same wired-client
  methodology already used for the ct-mark/CAKE verification
  (`e8450-mtk-feeds-audit-2026-09.md` §4, 2026-09-06 update).
- **Rollback**: `hold_ms=0` reverts Phase B's behavioral effect at
  runtime without a reflash. Phase A has no runtime toggle (it's a pure
  correctness fix with no expected behavior change) — rollback there
  means reverting the patch, same as any other local patch in this
  tree.

## 8. Open risks / questions carried into implementation

- `flow_offload_teardown()`'s effect on **already in-flight** packets
  for a flow mid-teardown (a packet that already passed
  `flow_offload_lookup()` before `NF_FLOW_TEARDOWN` was set) is not
  independently verified here — expected to be the same behavior every
  other flowtable-offload driver's teardown path already exhibits
  (this is exactly the generic contract, not new exposure from v2), but
  worth an explicit dmesg/packet-loss check in Phase A's hardware A/B,
  not assumed clean by source-reading alone.
- §4.3's save/restore-on-release must be verified against a **live**
  `ct mark set 7/8` HQoS-classified bulk flow specifically (not just an
  unmarked one) before Phase B is considered done — the failure mode
  (permanently losing priority classification on release) has no
  compile-time signal.
- Hold-table capacity (64) is reused from `MTK_QDMA_AQM_MAX_BATCH`
  without independently re-deriving whether that's the right bound for
  *concurrently held* flows (a different quantity than *evicted per
  trigger*) — a router-wide congestion event lasting several `hold_ms`
  windows could plausibly hold more than 64 flows at once; check live
  `holds_active` against this cap under real saturating-load testing
  before trusting it sized correctly, cap-eviction-of-the-oldest-hold
  vs silently declining a new hold is an implementation decision not
  yet made.

## 9. Implementation notes (2026-09-06) — what changed from the design above

All three phases implemented and build-verified together (clean
`target/linux/clean` + `target/linux/prepare`, zero `.rej`, full
`target/linux/compile` through a real `vmlinux`/`Image` link) as
`999-ppe-94-mtk_ppe-clamp-set_queue-to-the-hardware-field-width.patch`,
`999-qos-18-mtk_eth-aqm-sync-flow-offload-teardown.patch`, and
`999-qos-19-mtk_eth-aqm-ct-mark-hold-release.patch`. Two real
constraints surfaced only by actually compiling, not by source reading
alone — recorded here because that's exactly the kind of gap this
project's own methodology exists to catch:

- **§4.2's direct `flow_offload_teardown()` call doesn't link.** This
  tree's config has `CONFIG_NET_MEDIATEK_SOC=y` (this driver is built
  into `vmlinux`) but `CONFIG_NF_FLOW_TABLE=m` (loadable module) —
  confirmed by a real failed build:
  `undefined reference to `flow_offload_teardown'`,
  `relocation truncated to fit: R_AARCH64_CALL26`. A built-in object
  can never link against a loadable module's exported symbol; no
  Kconfig relationship between the two was ever established because
  the only interaction the driver had with `nf_flow_table` before this
  patch was receiving pointers via a registered callback (nf_flowtable
  calls *into* the driver), never the driver calling back out. Fixed
  with `symbol_get(flow_offload_teardown)`
  (`EXPORT_SYMBOL_GPL`-only lookup by name against currently-loaded
  modules, `kernel/module/main.c`), cached in a function-local `static`
  function pointer after the first successful resolution — which also
  takes a permanent module reference, pinning `nf_flow_table` loaded
  for as long as this driver is (acceptable: `nf_flow_table` is already
  a hard functional prerequisite for PPE offload to work at all).
  Graceful no-op (falls back to exactly qos-06 through qos-17's
  `mtk_foe_entry_clear()`-only behavior for that call) if the module
  isn't loaded yet, rather than a hard failure.
- **§4.1's reference-holding needs an explicit reference, not just RCU,
  for the *release* side.** §4.1 correctly established that reading
  `flow`/`flow->ct` inside the existing RCU walk is safe without an
  extra reference. That covers the *hold* side (qos-18/§4.2's
  synchronous teardown). It does **not** cover §4.3's *release* side:
  restoring `ct->mark` happens later, from `mtk_qdma_aqm_work()`'s next
  poll tick — outside any RCU critical section tied to the original
  walk. `mtk_qdma_aqm_flow_hold()` therefore takes an explicit
  `refcount_inc(&ct->ct_general.use)` (the identical pattern
  `flow_offload_alloc()` itself uses) at hold time, paired with
  `nf_ct_put()` at release time in both `mtk_qdma_aqm_hold_gc()` and
  `mtk_qdma_aqm_hold_flush()`. `nf_conntrack` is `CONFIG_NF_CONNTRACK=y`
  (built-in, unlike `nf_flow_table`), so this reference-counting pair
  links directly with no `symbol_get()` needed.
- **A rollback gap not covered by the original design doc: what happens
  to pending holds if the AQM is disabled mid-flight.**
  `mtk_qdma_aqm_work()` (unchanged qos-06 behavior) simply stops
  rescheduling itself once `enabled` goes false — so a periodic
  `mtk_qdma_aqm_hold_gc()` call alone would never run again after a
  `disable` write, permanently stranding any flow still held at that
  moment (mark stuck, `struct nf_conn` reference never dropped). Added
  `mtk_qdma_aqm_hold_flush()` — an unconditional release-everything-now
  helper — called from both the `disable` write path and immediately
  before applying a fresh `enable` reconfiguration. `disable` is this
  whole mechanism's documented runtime kill switch; it must not leave
  the router in a worse state than before it was ever turned on.
- **`hold_ms` ships opt-in (default `0`), not opt-out**, including for
  any pre-existing `enable <queue> [poll_ms [thresh [batch [grace_ms]]]]`
  caller that predates this patch and only supplies five arguments —
  the sscanf fallback default for the new sixth argument is `0`
  (disabled), not a nonzero convenience default, so upgrading the
  kernel alone never silently activates unvalidated new behavior.
  Matches §7's stated rollout caution exactly.

Flashed and hardware-validated the same session — see §10.

## 10. Hardware validation (2026-09-06)

Built the full sysupgrade image (all three patches present) and
flashed live via `sysupgrade -c` (config preserved). Clean boot: both
radios up, flow offload `1/1`, `dmesg` free of oops/panic/BUG/SER/
timeout/lockdep warnings throughout the entire session. The persisted
boot config (`package/qdma-shaper/files/qdma-shaper.init`) only ever
writes the original 5 positional args (`queue poll_ms byte_thresh
batch grace_ms`) to `qdma_aqm`, so `hold_ms` lands on its compiled-in
`0` (disabled) fallback on every real boot without any config change -
confirmed live: `enabled=1 ... grace_ms=1000 hold_ms=0` immediately
after the fresh boot, before this session touched the debugfs node at
all.

**Phase A/qos-18 (always-on, no toggle):** no observable regression.
`trigger_count`/`unbind_total` climbed normally under real household
load from the first minute of boot, matching pre-existing baseline
behavior.

**Phase B/qos-19 (`hold_ms`, opt-in):** enabled live via debugfs
(`enable 7 100 0 4 1000 <hold_ms>`) for testing, matching this
project's own established live-tuning methodology.

- **End-to-end mechanism confirmed on real traffic.** Set `hold_ms=5000`
  and watched `holds_active`/`holds_released` under real household
  load for 60s: `holds_active` fluctuated 4-8 (never near the 64 cap),
  `holds_released` climbed continuously in step with `unbind_total`
  (both ended around 65-80) - the hold table populates and drains
  continuously, not stuck or leaking.
- **Save/restore correctness confirmed on a controlled, fully-traced
  flow** (this project's own wired-workstation methodology,
  `192.168.1.6`, `iperf3` against `fra.speedtest.clouvider.net`, exact
  local port identified via `ss`, polled every 1s against
  `/proc/net/nf_conntrack` with `hold_ms=3000`): `mark=7` (this tree's
  default WAN-bulk classification, `files/etc/nftables.d/30-queue-mark.nft`)
  →`mark=153` (held) for several seconds while `bytes=` kept climbing
  continuously (917377→2206553, i.e. genuinely still transferring on
  the software path, not stalled) → `mark=7` again, correctly restored,
  not corrupted or left at `153`. The same flow cycled through this
  transition multiple times over a 20s saturating upload as real
  congestion recurred - `bytes=` never stopped climbing across any
  transition (3330521→4062113 monotonic through multiple hold/release
  boundaries), i.e. no connection disruption from the mark churn
  itself. This was §8's top-listed open risk (permanently losing a
  flow's HQoS classification on release) - directly disproven on real
  hardware, not just by code inspection.
- **A real, unresolved signal: more TCP retransmits with `hold_ms`
  active.** A same-length (20s), same-server `iperf3` A/B: `hold_ms=0`
  (Phase A only) → 411 retransmits, 8.23 Mbit/s sent, 17 triggers/36
  unbinds in-window; `hold_ms=3000` → 965 retransmits, 7.26 Mbit/s
  sent. This project's own docs already document that a hardware→
  software eviction transition has an inherent TCP retransmit cost
  (`netsys-qos-port-investigation.md`'s "389 vs 7 retransmits" note);
  the open question `hold_ms` raises is whether holding a flow off
  hardware for multiple seconds at a time changes that cost
  meaningfully versus the immediate-re-eligibility v1 behavior. One
  A/B pair under real, noisy household traffic (this project's own
  repeatedly-documented confounder) is **not** enough to call this a
  confirmed regression or dismiss it - it's the concrete reason
  `hold_ms` ships at `0` (disabled) rather than defaulting on. **Do
  not enable `hold_ms` in the persisted boot config
  (`package/qdma-shaper/files/qdma-shaper.init`/`qdma-shaper.config`)
  without a larger, cleaner, multi-rep A/B (matching the rigor of the
  original `grace_ms` tuning A/B, `netsys-qos-port-investigation.md`
  §35) resolving this one way or the other first.**
- **Hold-table capacity**: never observed above single digits
  (`holds_active` peaked at 8) against the 64-entry cap under real
  current household load - §8's capacity-sizing risk stays open in
  principle (a genuinely worse congestion event could exercise it
  further) but isn't a concern at today's measured load.

Router left in its safe default state after testing:
`grace_ms=1000 hold_ms=0` (Phase A active, Phase B present but
dormant, matching the persisted boot config exactly - reflashing or
rebooting reproduces this state without any manual step).

**Net verdict:** Phase A ships as an unconditional correctness fix.
Phase B's mechanism is proven correct (save/restore, no connection
disruption, no leaks) but its retransmit-cost tradeoff needs a real
A/B before recommending a production `hold_ms` value - tracked as
follow-up work, not blocking this patch set's adoption at the current
(disabled) default.
