# E8450 AQM v2 — design (2026-09-06)

Status: **v2 shipped and closed out (2026-09-06).** All three phases
implemented, build-verified, flashed, and hardware-tested. Phase B
(`hold_ms`) **adopted as the production default** (`hold_ms=3000`,
wired into `package/qdma-shaper/files/qdma-shaper.{init,config}`,
confirmed activating correctly from a cold boot with zero manual
intervention) after a properly-powered A/B found no measurable cost
and a plausible tail-latency benefit — see §12. Scoped the next AQM
iteration now that `999-ppe-93` (PPE hardware-offload bypass via
`ct mark`) is live in this tree. Every claim below is grounded in this
fork's own patched source
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
- **A single-sample retransmit signal from this initial pass, revised
  by a proper multi-rep A/B — see §11.** The original single-pair
  comparison here (`hold_ms=0` → 411 retransmits vs `hold_ms=3000` →
  965) is superseded; do not cite it as a standalone finding.
- **Hold-table capacity**: never observed above single digits
  (`holds_active` peaked at 8) against the 64-entry cap under real
  current household load - §8's capacity-sizing risk stays open in
  principle (a genuinely worse congestion event could exercise it
  further) but isn't a concern at today's measured load.

Router left in its safe default state after testing:
`grace_ms=1000 hold_ms=0` (Phase A active, Phase B present but
dormant, matching the persisted boot config exactly - reflashing or
rebooting reproduces this state without any manual step).

**Net verdict as of this pass:** Phase A ships as an unconditional
correctness fix. Phase B's mechanism is proven correct (save/restore,
no connection disruption, no leaks); its cost/benefit tradeoff was
re-examined with proper statistical rigor in §11 below, which
supersedes this section's single-sample retransmit claim.

## 11. Continued testing and refinement (2026-09-06, same day)

Extended `scripts/e8450/saturating-load-harness.sh` to also report
TCP retransmits from the `iperf3` JSON (`d['end']['sum_sent']['retransmits']`)
- a durable, reusable improvement, not a one-off script, since the
harness previously measured throughput and latency but not the metric
§10's regression claim actually needed.

### 11.1 Properly-powered A/B revises §10's retransmit claim

Ran the harness 4 reps per side (`hold_ms=0` and `hold_ms=3000`, same
20 s duration, same real household-traffic conditions, same session)
instead of §10's single pair:

| metric | `hold_ms=0` (mean±stdev, n=4) | `hold_ms=3000` (mean±stdev, n=4) | delta |
|---|---:|---:|---:|
| sent (Mbit) | 8.19±0.11 | 8.12±0.26 | −0.9% |
| avg latency (ms) | 25.5±0.2 | 26.1±0.5 | +2.4% |
| p95 (ms) | 30.1±0.5 | 31.1±0.6 | +3.3% |
| p99 (ms) | 33.0±2.4 | 35.8±6.5 | +8.7%, dominated by one rep's 45.5 ms outlier |
| retransmits | 460±123 | 505±89 | +9.8% |

**The within-group standard deviation (89-123 retransmits, 2.4-6.5 ms
for p99) is larger than the between-group mean delta (45 retransmits,
2.9 ms for p99) on every metric.** §10's single-pair comparison (411
vs 965 retransmits, a >2x difference) was an unlucky/lucky draw at
n=1, not a representative effect - exactly the household-traffic-noise
confounder this project's own docs have repeatedly flagged
(`netsys-qos-port-investigation.md` SS31.3, SS35.1). **Revised finding:
no statistically distinguishable throughput, latency, or retransmit
cost from `hold_ms=3000` at this household's current traffic level.**

### 11.2 Direct validation that `hold_ms` does what it's designed to do

§10 validated save/restore correctness on a single flow but didn't
directly confirm the mechanism actually changes how long a flow stays
off hardware - the whole reason it exists. Two further checks, same
wired-workstation methodology:

- **`hold_ms=0` never marks at all**, confirmed unambiguously: polled
  a tracked `iperf3` flow's `/proc/net/nf_conntrack` mark every 0.5 s
  for a full 20 s saturating upload - **34/34 samples read `mark=7`**
  (this tree's default WAN-bulk classification), never once `153`.
  Matches `mtk_qdma_aqm_flow_hold()`'s own early-return
  (`if (!eth->qdma_aqm_hold.hold_ms) return;`) exactly: `hold_ms=0` is
  genuinely a full no-op for the hold mechanism, not merely a
  short/instant hold, reverting cleanly to qos-06 through qos-18's
  teardown-sync-only behavior.
- **`hold_ms=3000` produces real, multi-second-plus hold episodes
  under sustained congestion**, not brief blips: the same 0.5 s-poll
  methodology against a genuinely saturating (real queue-7-congesting)
  upload showed the flow's mark sitting at `7` for the first ~8.5 s
  (pre-congestion ramp), then transitioning to `153` and **staying
  there continuously for the rest of the observed ~13.5 s window** -
  longer than a single 3000 ms hold, consistent with the flow being
  re-marked on a fresh eviction almost immediately after each release
  (this is a genuinely elephant/dominant flow under a synthetic
  saturating load - exactly the scenario `hold_ms` targets) rather than
  a stuck/leaked mark (the debugfs `holds_released` counter kept
  climbing throughout the same session, ruling out a leak).
- **A negative methodology result, worth recording so it isn't
  re-attempted the same way**: tried to corroborate hold duration via
  `ppe0/entries`' `BND`/`UNB` state instead of the conntrack mark,
  polling once per second. Result was **not usable**: both `hold_ms=0`
  and `hold_ms=3000` showed the same pattern - the tracked flow's
  `ppe0/entries` row flickers `UNB` for a single ~1 s sample, then
  reads `BND` again, regardless of `hold_ms`. Root cause (traced, not
  guessed): `mtk_qdma_aqm_flow_teardown()`'s `flow_offload_teardown()`
  call sets `NF_FLOW_TEARDOWN` on the generic `flow_offload` object
  immediately; the *generic* `nf_flowtable` `gc_work` (1 Hz, unrelated
  to this AQM's own `poll_ms`/`hold_ms`) then calls back into this
  driver's own `mtk_flow_offload_destroy()` within about a second,
  which fully removes the `mtk_flow_entry` from `eth->flow_table`
  (`rhashtable_remove_fast()` + `kfree()`) - so the zombie stops being
  *visible* in `ppe0/entries` well before `hold_ms` (if longer than
  ~1 s) actually expires, even though the conntrack mark (the real
  gate) is still correctly held. `ppe0/entries` visibility duration is
  governed by the generic 1 Hz gc cadence, not by `hold_ms` - **the
  conntrack mark, not `ppe0/entries`, is the correct ground truth for
  validating `hold_ms` duration**, matching (and extending) this
  project's own already-documented methodology finding that
  `/proc/net/nf_conntrack`'s offload flags and `ppe0/entries` measure
  different things (`e8450-mtk-feeds-audit-2026-09.md` §4).

### 11.3 Revised net verdict

Phase A/C ship as unconditional fixes (unchanged). Phase B's mechanism
is now confirmed, on real hardware, to do exactly what it was designed
to do (extend off-hardware duration under sustained congestion,
correctly, with no data corruption, no leaks) **and** shows no
statistically distinguishable throughput/latency/retransmit cost at
`hold_ms=3000` under a properly-powered same-day A/B. This is
materially stronger evidence than §10 had. It is **not** yet strong
enough to recommend flipping the persisted boot default
(`package/qdma-shaper.init`) to a nonzero `hold_ms`: this session's A/B
used one synthetic single-flow saturating upload, not the genuinely
heavier, multi-flow, sustained congestion scenario `hold_ms` is meant
to help most, and this household's real background load stayed light
enough throughout (`holds_active` peaked at 8 of the 64 cap) that the
mechanism was never seriously stress-tested. Real remaining follow-up,
not blocking anything currently shipped: a multi-rep A/B specifically
during genuinely heavy real household congestion (or a multi-stream
synthetic load closer to saturating multiple flows at once), to see
whether `hold_ms`'s designed benefit (fewer, more deliberate hardware
transitions under sustained pressure) shows up as a measurable latency
or fairness improvement once the mechanism is actually under load
heavy enough to matter.

### 11.4 Follow-up executed same day: heavier, multi-flow congestion

§11.3's own stated follow-up (test under load closer to saturating
multiple flows at once) run immediately after: `iperf3 -P 4` (4
parallel TCP streams in one saturating upload) instead of a single
stream, 3 valid reps per side (one discarded rep per side re-run,
matching the harness's own discard/retry convention), same server/
session/ping methodology otherwise.

| metric | `hold_ms=0` (mean±stdev, n=3) | `hold_ms=3000` (mean±stdev, n=3) | delta |
|---|---:|---:|---:|
| sent (Mbit) | 8.8±0.0 | 8.5±0.4 | −3.2% |
| retransmits | 1759±216 | 1991±53 | +13.2% |
| avg latency (ms) | 27.2±0.5 | 27.1±0.8 | −0.4% |
| p95 (ms) | 31.5±0.6 | 31.2±1.1 | −1.0% |
| p99 (ms) | 36.8±6.1 | 37.6±5.7 | +2.2% |
| max (ms) | 48.4±25.2 | 41.1±5.2 | −15.1%, and **far tighter spread** |

Small samples (n=3/side, matching this session's time budget, not a
full statistical study) — read directionally, not as a confirmed
result. Two observations worth carrying forward rather than
overclaiming:

- **Retransmits scale with `hold_ms`** under this heavier load (+13.2%,
  now larger than `hold_ms=3000`'s own stdev, unlike §11.1's
  single-stream result which stayed within noise) - the cost §10
  originally flagged is real at heavier congestion, just not at this
  household's lighter single-flow load. Consistent with the mechanism
  working as designed: holding more flows off hardware for longer
  under heavier congestion means more of them pay the hardware→
  software transition's inherent retransmit cost
  (`netsys-qos-port-investigation.md`'s "389 vs 7 retransmits" note),
  applied to a larger fraction of the load.
- **Worst-case latency (`max`) was both lower and dramatically more
  consistent with `hold_ms=3000`** (41.1±5.2 ms vs 48.4±25.2 ms, one
  `hold_ms=0` rep hit 77.5 ms). `p95` and `avg` stayed flat either way.
  This is the textbook AQM tradeoff shape - trading a measurable
  retransmit-rate cost for tighter, lower tail latency - and if it
  holds up under a larger sample, is the first evidence of `hold_ms`'s
  *intended* benefit actually showing up in a metric, not just "no
  regression."

**Still not enough to change the shipped default.** Two real tradeoffs
now both have *some* evidence (retransmit cost real at heavier load;
possible tail-latency benefit at heavier load), pointing in opposite
directions, both from n=3 samples. Recommend this as the next concrete
piece of follow-up work: a larger (8-10 rep), multi-stream A/B
specifically, to determine whether the tail-latency benefit is real
and outweighs the retransmit cost for this household's actual usage
pattern, before touching `qdma-shaper.init`'s persisted default.

## 12. Wrap-up: the 8-rep multi-stream A/B and production adoption (2026-09-06)

Executed §11.4's own recommended follow-up immediately: 8 valid reps
per side (vs. §11.4's n=3) of the same 4-parallel-stream saturating
upload, reusing `saturating-load-harness.sh`'s `[streams]` parameter
added for exactly this (`./saturating-load-harness.sh 8 20 8.8.8.8 4`).

| metric | `hold_ms=0` (n=8, outlier excluded, n=7) | `hold_ms=3000` (n=8) | delta |
|---|---:|---:|---:|
| sent (Mbit) | 8.6±0.7 | 9.0±0.4 | +5.0% |
| avg latency (ms) | 27.7±1.0 | 26.8±1.0 | −3.2% |
| p95 (ms) | 32.5±1.0 | 32.3±2.6 | −0.5% |
| p99 (ms) | 39.9±6.0 | 37.8±5.3 | −5.2% |
| retransmits | 1680±221 | 1655±220 | −1.5% |

**With proper statistical power (n=7-8 per side, more than double
§11.4's n=3), the retransmit-cost signal from §11.4 does not
reproduce** - retransmits are now statistically flat (even very
slightly lower with `hold_ms=3000`), not +13.2% worse. §11.4's n=3
retransmit finding was itself still noise, same lesson as §11.1's
original n=1 finding: this project's real-household-traffic A/Bs need
real sample sizes before trusting a delta, even a delta that looks
larger than one side's stdev at n=3.

**One real severe congestion event occurred during the `hold_ms=0`
leg** (one rep: avg 71.5 ms, p95 254 ms, p99 861 ms, max 1065 ms - a
genuine real-world household-traffic spike, not a synthetic result)
**and none occurred during the `hold_ms=3000` leg** (worst single-rep
max across all 8 reps: 69.5 ms). This is mechanistically consistent
with `hold_ms`'s whole design intent - §11.2 already showed `hold_ms=0`
lets an evicted flow rebind to hardware within about a second, so a
real burst of contending traffic can drive rapid rebind/re-evict
cycling with no flow held back long enough to let the queue drain,
whereas `hold_ms=3000` forces a meaningful stretch of real breathing
room. **This is not proof** - one occurrence in 16 reps cannot rule out
coincidental timing of unrelated household traffic independent of
which config was active - but it is the most direct evidence yet of
the intended benefit, and it points the same direction as the "flatter,
lower `max`" finding in both §11.4 (n=3) and this section's own outlier
case.

### 12.1 Decision: adopt `hold_ms=3000` as the production default

Across every A/B run this session (single-stream 4-rep, single-stream
mark/duration validation, multi-stream 3-rep, multi-stream 8-rep):
`hold_ms=3000` never showed a statistically distinguishable cost on
throughput, `p95` latency, or (at proper sample size) retransmits, and
repeatedly showed flatter/lower worst-case latency, including one
direct observation of it apparently containing a real severe
congestion event that `hold_ms=0` did not. Combined with §11.2's
direct confirmation that the mechanism does what it's designed to do
(genuine multi-second hold episodes under sustained congestion, clean
save/restore, no leaks, no crashes across the full multi-hour test
session), this clears the bar this project has consistently used for
adopting a tuning change (`999-eth-17`'s NAPI-weight A/B, the
`grace_ms` tuning in `netsys-qos-port-investigation.md` §35): real
hardware evidence, no measured regression, a plausible and
mechanistically-grounded benefit.

**Wired into the persisted production config**, not just tested via
debugfs:

- `package/qdma-shaper/files/qdma-shaper.init`'s `apply_aqm()`: reads
  a new `hold_ms` UCI option (`config_get hold_ms "$cfg" hold_ms 0` -
  default `0`/disabled for any config predating this option, matching
  qos-19's own compiled-in default) and appends it as the 6th
  positional argument to the `enable` debugfs write.
- `package/qdma-shaper/files/qdma-shaper.config`: `config aqm 'queue7'`
  now carries `option hold_ms '3000'`.
- Built the full image, flashed live via `sysupgrade -c`. **Verified
  end-to-end from a genuine cold boot**, not just by re-reading the
  source: `logread` shows `qdma-shaper: AQM enabled queue=7 poll_ms=100
  grace_ms=1000 hold_ms=3000` at boot, `qdma_aqm` debugfs confirms
  `hold_ms=3000` with `trigger_count`/`unbind_total`/`holds_released`
  already nonzero within the first minute of uptime, zero manual
  debugfs writes this boot. Clean boot otherwise: both radios up, flow
  offload `1/1`, `dmesg` free of oops/panic/BUG/SER/timeout throughout.

### 12.2 What's still open (real follow-up, not blocking)

- The "one severe event during `hold_ms=0`" observation (§12) is
  suggestive, not proven causal - a dedicated test that can reliably
  *trigger* a comparable congestion burst on demand (rather than
  waiting for real household traffic to happen to produce one) would
  turn this into a real, repeatable A/B instead of an anecdote.
- §8's hold-table capacity risk (64 entries) has still never been
  exercised near its cap even under this session's heaviest 4-stream
  test (`holds_active` stayed in single digits) - revisit if a future
  session observes it approaching the cap under genuinely heavier
  real-world congestion.
- §8's already-in-flight-packet question for `flow_offload_teardown()`
  remains unverified by a dedicated packet-capture-level test (this
  session's evidence is all throughput/latency/retransmit-level, not a
  packet trace) - no evidence of a problem found, but not the same as
  a targeted check.
