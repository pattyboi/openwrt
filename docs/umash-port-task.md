# UMASH hash-port experiment — closed and reverted

Date closed: 2026-07-10. The five-patch experimental UMASH series and
`CONFIG_UMASH=y` were removed from the active tree. The kernel's original
`jhash()`, `jhash_1word()`, and `jhash_3words()` implementations are the
deliberate baseline again.

2026-07-11 update: successor-candidate audit recorded
(§Alternative-hash suitability audit) and the next-phase benchmark
candidate matrix fixed (§Next-phase microbenchmark).

## Decision

Do not restore commit `fba9631009` or patches `999-umash-01..05` as-is.
The port compiled and booted on the E8450, but neither correctness equivalence
nor a performance benefit was demonstrated. Its intended collision guarantee
also did not apply to the values actually returned by the converted kernel
call sites.

The removal covers all parts of the experiment:

- the hand-ported `lib/umash.c` and public kernel header;
- Kconfig and Makefile integration;
- nftables rhashtable conversion;
- IPv4/IPv6 established-socket and UDP port/address conversions;
- the MT7622 `CONFIG_UMASH` selection.

## Why it was removed

1. Every converted call site truncated UMASH's 64-bit result to `u32`.
   Upstream's full-width collision bound therefore could not be claimed for
   the table hash that the kernel actually consumed. The experiment's commit
   messages overstated the resulting DoS-hardening property.
2. `CONFIG_UMASH` depended only on `ARM64`, while keys longer than 16 bytes
   unconditionally executed PMULL. The E8450 supports PMULL, but the Kconfig
   interface was unsafe for other arm64 systems without the crypto extension.
3. Header-local random parameter blocks made inline hash results depend on the
   translation unit. Current paths appeared paired, but this weakened the
   original helper's deterministic contract and created a maintenance trap.
4. The hand port had no kernel differential tests against upstream vectors,
   especially at the 8/9, 16/17, and 256/257-byte boundaries.
5. No pre/post benchmark existed. For the active 4-byte and 12-byte socket
   keys, specialized jhash routines are strong candidates to be faster than
   the scalar UMASH setup. Long nftables keys additionally pay FPSIMD context
   management around PMULL.

## Policy for future hash work

Do not replace a packet-path hash based on library throughput claims alone.
First show that the exact call site is CPU-bound and that hashing is material
in its profile. Then benchmark the exact output width, key sizes, execution
context, and target CPU.

A candidate must pass all of these gates before entering an image:

1. **Correctness:** differential vectors for lengths 0..64 plus boundaries
   8/9, 16/17, and 256/257; parameter-init failure cases; insertion/lookup
   consistency across translation units; concurrent first-use testing.
2. **Architecture safety:** compile-time or runtime feature gating with a safe
   fallback. Inline assembly must never make a generic arm64 option depend on
   an undeclared CPU extension.
3. **Microbenchmark:** compare against `jhash_1word`, `jhash_3words`, and
   `jhash` at 4, 8, 12, 16, 17, 32, 48, and 64 bytes on MT7622. Pin one CPU,
   leave the router's normal `ondemand` policy unchanged, run enough iterations
   to report cycles/hash and instructions/hash, and measure first-use separately
   from steady state.
   The concrete candidate matrix for the next phase is fixed in
   §Next-phase microbenchmark below.
4. **Call-site A/B:** isolate one subsystem per image. Use TCP connection rate
   for inet ehash, connected UDP request/response for UDP ehash, and forced
   rhashtable exact-match nft sets at several key sizes and populations.
   Bulk iperf throughput is not a sufficient socket-hash benchmark.
5. **Decision threshold:** require a repeatable improvement outside run noise
   with no weaker collision behavior, architecture coverage, or context
   safety. A merely plausible or zero-cost change does not qualify.

## Alternative-hash suitability audit (2026-07-11)

Post-revert, three modern candidates were assessed as potential successors,
strictly against the gates above and the target microarchitecture. This
section records the verdicts so the evaluation is not repeated from scratch.

### Cortex-A53 multiplier constraints (govern every verdict below)

MT7622 = 2× Cortex-A53: in-order, 2-wide, single multiply pipe. Estimated
costs (to be confirmed by the benchmark itself — that is its purpose):

- 32×32→32 `MUL Wd` — ~3-cycle latency, pipelined. Cheap.
- 64×64→64 `MUL Xd` — ~4-cycle latency, partially blocking.
- 64×64→128 (`MUL` + `UMULH` pair, what `__uint128_t` compiles to) —
  `UMULH` is ~6 cycles and the pair does not pipeline; budget ~8–10 cycles
  of multiplier occupancy per full-width product.

Consequence: every "mum"-style hash (rapidhash, Komihash, wyhash lineage)
is built on the 64×64→128 fold, the one primitive this core executes
poorly relative to the out-of-order x86/Apple cores all published
benchmarks come from. Their headline GB/s numbers do **not** transfer.
Conversely `jhash` is pure 32-bit ALU (EOR/ROR/SUB chains, no multiplies)
and dual-issues well here, and its specialized 4/12-byte entry points are
essentially just the ~21-instruction final avalanche (~15–25 cycles
including setup). Theoretical crossover: mum hashes need ~1 full-width
product per 16 bytes vs. jhash's ~1 mixing round (~24 serial-chained ops)
per 12 bytes, so parity is expected somewhere in the 12–16-byte region
with the mum hashes pulling ahead by 32–64 bytes. Below 12 bytes the
specialized jhash routines are presumed unbeatable on this core.

### rapidhash (v3) — SELECTED as primary candidate

- Pure GPR scalar C: no PMULL, no FPSIMD, no `kernel_neon_begin()` —
  callable from any context including hardirq. This eliminates removal
  reasons 2 and 5 (arch gating, FPSIMD context cost) by construction.
- v3 ships size-tiered variants: `rapidhashNano` (smallest code, tuned for
  short-key latency) and `rapidhashMicro` (small, unrolled bulk loop for
  medium keys). Small hot footprint matters on an 32 KiB-I$/core A53.
- Passes SMHasher3; seed- and secret-parameterizable, so a keyed per-boot
  variant is possible (required — see matrix below; default upstream
  secrets are public constants and give zero DoS resistance).
- Cost: lives or dies on the A53 `MUL`+`UMULH` budget above. That is
  exactly what the microbenchmark measures.

### Komihash — REJECTED (not benchmarked)

Same mum primitive as rapidhash, so the same A53 multiplier penalty, but
with a larger function body, more short-length branching, and no variant
tiering. On every axis we care about (code size, short-key path, secret
handling) it is dominated by rapidhash while sharing its one weakness.
Carrying it into the benchmark adds image and analysis cost with no
plausible win condition.

### XXH3 — REJECTED (not benchmarked)

- Not in the kernel tree (`lib/xxhash.c` has only XXH32/XXH64); a hand
  port of XXH3's 192-byte secret table and boundary-heavy short-key paths
  repeats removal reason 4 — the exact differential-vector trap that
  killed the UMASH port.
- Its long-key advantage is SIMD; scalar-only XXH3 forfeits that, and
  NEON XXH3 re-imports the FPSIMD context-management problem (removal
  reason 5) that we just removed.
- Our key sizes top out around 64 bytes; XXH3's design center is well
  above that.

### xxh32 — control reference only

Already in-tree (`include/linux/xxhash.h`), already deployed on this box
(seeded flowtable tuple hash, `999-ppe-92`), and already measured once:
the 2026-07-05 audit found `jhash_1word` beats it at 4 bytes. Its 32×32
multiplies are the cheap kind on A53. It anchors the new numbers against
the previous audit and catches harness regressions — it is not a
replacement candidate (unkeyed beyond the seed).

## Next-phase microbenchmark — candidate matrix (pre/post-flash)

All measurements on the E8450 itself (in-order A53, not the build host),
per gate 3: fixed CPU affinity, the normal `ondemand` policy, cycles/hash and
instructions/hash, with first-use measured separately from steady state.

### Baselines — jhash family (what is in the image today)

| Function | Key sizes (bytes) | Models call site |
|---|---|---|
| `jhash_1word()` | 4 | single-word sites (RX flow hash etc.) — no candidate targets this; presumed unbeatable |
| `jhash_3words()` | 12 | IPv4 established-socket tuple (`inet_ehashfn`: laddr, faddr, ports) |
| `jhash()` | 16, 17, 32, 48, 64 | nft set keys (16 = v4 concat; 32 = v6 addr pair; 48 = v6 concat; 64 = large concat/map); 17 forces the loop-tail path one byte past a boundary |

### rapidhashNano32() — primary candidate (12, 16, 17, 32, 48 bytes)

Exact wrapper to benchmark (the inner `rapidhash_nano64()` is the kernel
port of upstream `rapidhashNano_withSeed`):

```c
u32 rapidhash_nano32(const void *data, u32 len)
{
	u64 h = rapidhash_nano64(data, len, rapid_seed, rapid_secret);

	return (u32)(h ^ (h >> 32));
}
```

Hard requirements, each mapped to a removal reason it must not repeat:

- **Fold, don't truncate** (removal reason 1): the 32-bit value is
  `low32 ^ high32` of the 64-bit result, so no output entropy is silently
  discarded. Document honestly that the folded value carries rapidhash's
  *empirical* 32-bit quality — no 64-bit collision bound may be claimed
  for it.
- **Per-boot random secret** (no public constants): `rapid_seed` and the
  full `rapid_secret[]` array are filled by `get_random_bytes()` once per
  boot — benchmark module does it in `module_init()`; production wiring
  would use the `net_get_random_once()` lazy pattern like `inet_ehashfn`.
  Force each secret word odd (`|= 1`) so no multiplicative lane collapses;
  if the fetched upstream source documents further secret constraints
  (wyhash-style popcount/byte-uniqueness rules), replicate them at
  generation time.
- **One translation unit owns the parameters** (removal reason 3): secret
  and seed are `static ... __read_mostly` in the single .c file; nothing
  parameter-bearing in a header.
- **Codegen check**: confirm with objdump that the `__uint128_t` products
  compile to `MUL`+`UMULH` pairs (no `__multi3` libcalls) at the tree's
  datapath `-O2`.
- No 4-byte target: theory says it cannot beat `jhash_1word` there; 12
  bytes is its entry point against `jhash_3words`.

### rapidhashMicro() — bulk-loop candidate (32, 64 bytes)

Same fold and secret rules as Nano32. Only question it answers: does
Micro's unrolled bulk loop beat Nano at 32 and 64 bytes on an in-order
2-wide core, or does the unroll just spill the I$? If Micro does not
clearly win at 64 bytes it is dropped and Nano covers the whole range.

### xxh32() — control (all sizes: 4, 12, 16, 17, 32, 48, 64 bytes)

In-tree implementation, fixed seed. Anchors against the 2026-07-05 audit
(must reproduce `jhash_1word` > `xxh32` at 4 bytes) and flags harness
breakage if its numbers move between runs.

### Image/build plan

The candidates are self-contained C — no call-site patches are needed for
this phase. Preferred: one image carrying a bench kmod that contains all
candidates plus baselines, so every number comes from the same boot under
identical conditions (pre/post-flash then means baseline-image vs.
bench-image only). Separate pre/post-change images per candidate are only
required at gate 4 (call-site A/B), one subsystem per image, and only for
a candidate that has already won here.

### Bench kmod — IMPLEMENTED 2026-07-11

`999-zzzzzz-hashbench-01-lib-test-hashbench-microbench.patch` adds
`lib/test_hashbench.c` (`CONFIG_TEST_HASHBENCH=m` in mt7622
`config-6.12`; unpackaged, so the image is unchanged and the `.ko` is
picked up from the kernel build dir). Status:

- **Differential vectors: PASS** — the in-module rapidhash Nano/Micro
  port was verified against upstream rapidhash V3 on the (aarch64)
  build host: 24 080 cases (len 0–300 × align offsets 0–7 × 5 seeds),
  0 mismatches.
- **Codegen: PASS** — `__uint128_t` products emit `mul`+`umulh`, no
  `__multi3`; W=1 compile clean.
- Measurement: dependent-latency chain (result feeds next seed/initval,
  the hash→lookup model), 64×1024-iteration chunks with IRQs off,
  min+mean reported; `nop-overhead` case calibrates the shared
  loop+indirect-call cost; first-use measured separately. Cycles and
  retired instructions are read directly from the A53 PMU registers
  (`PMCCNTR_EL0`, `PMSELR_EL0`+`PMXEVCNTR_EL0`) while perf kernel
  counters own the hardware — deliberately avoiding
  `perf_event_read_local()`, which 6.12 doesn't export, so the module
  loads on a running kernel built from this tree **without a reflash**
  (vermagic `6.12.87 SMP mod_unload aarch64`, standard exports only).
- Run: `insmod test_hashbench.ko [bench_cpu=1] [rapid_fixed=1]
  [align_offset=0-7]`, results in dmesg; init returns `-EAGAIN` by
  design so re-runs need no rmmod. `rapid_fixed=1` keeps upstream
  secret constants so printed `h32` vectors can be cross-checked;
  default is the per-boot random secret per the candidate spec.
- Expected `h32` on the router with `rapid_fixed=1 align_offset=0`
  (host-computed from upstream V3 over the module's fixed buffer
  pattern `buf[i] = i*0x9d + 0x35`):
  nano32 12B `0x01b8a267`, 16B `0x9c32a00a`, 17B `0x61dedde4`,
  32B `0x628051f8`, 48B `0x93aa7638`;
  micro32 32B `0x628051f8` (== nano32, shared tail path — built-in
  cross-check), 64B `0x1cc97cb9`.

### First on-router run — 2026-07-11, vectors PASS, matrix measured

Module scp'd to the live router (no reflash) and run with
`rapid_fixed=1` on CPU1: **all 7 rapidhash h32 vectors matched** the
host-computed references, the PMU path worked (`cy_idx=31 in_idx=0`,
15-cycle read overhead), and the run completed in ~350 ms. Timing is
secret-independent, so these are also the steady-state numbers
(min-of-64-chunks; "net" subtracts the 11.03-cycle nop-overhead
loop+indirect-call baseline):

| Function | len | min cy/hash | net cy | insn/hash |
|---|---|---|---|---|
| nop-overhead | – | 11.03 | 0 | 8 |
| jhash_1word | 4 | 33.0 | 22 | 42 |
| jhash_3words | 12 | 33.0 | 22 | 41 |
| jhash | 16 | 68.0 | 57 | 82 |
| jhash | 17 | 70.0 | 59 | 84 |
| jhash | 32 | 100.0 | 89 | 118 |
| jhash | 48 | 131.0 | 120 | 154 |
| jhash | 64 | 150.1 | 139 | 194 |
| rapidhash_nano32 | 12 | 56.0 | 45 | 43 |
| rapidhash_nano32 | 16 | 55.0 | 44 | 43 |
| rapidhash_nano32 | 17 | 70.0 | 59 | 49 |
| rapidhash_nano32 | 32 | 69.0 | 58 | 49 |
| rapidhash_nano32 | 48 | 82.0 | 71 | 55 |
| rapidhash_micro32 | 32 | 68.0 | 57 | 49 |
| rapidhash_micro32 | 64 | 96.0 | 85 | 65 |
| xxh32 | 4 | 52.0 | 41 | 59 |
| xxh32 | 12 | 74.0 | 63 | 75 |
| xxh32 | 16 | 62.1 | 51 | 92 |
| xxh32 | 17 | 74.0 | 63 | 99 |
| xxh32 | 32 | 77.1 | 66 | 109 |
| xxh32 | 48 | 92.0 | 81 | 126 |
| xxh32 | 64 | 107.1 | 96 | 143 |

Findings (gate 3 complete):

- **Control sanity reproduced:** `jhash_1word` (33 cy) beats `xxh32`
  at 4 B (52 cy), matching the 2026-07-05 audit. Harness trusted.
- **Crossover exactly where the A53 theory put it (12–16 B):**
  `jhash_3words` is untouchable at 12 B (33 vs 56 cy — the mum setup
  cost can't amortize). From 16 B up, nano32 wins on cycles: −19% at
  16 B, tie at 17 B (its >16 path adds one mum, +15 cy step), −31% at
  32 B, −37% at 48 B; micro32 −36% at 64 B.
- IPC tells the microarch story: jhash retires ~1.2 insn/cy
  (dual-issue ALU chains), rapidhash only ~0.7–0.8 insn/cy
  (mul+umulh latency-bound) — yet still wins ≥16 B on far fewer
  instructions (43 vs 82 at 16 B).
- micro32 ≈ nano32 at 32 B (68.0 vs 69.0 — shared tail path);
  micro only differentiates in its 80 B+ bulk loop, so **Nano covers
  the whole ≤64 B range**; Micro is not needed for these key sizes.

Consequence for gate 4: the only call sites where rapidhash can pay
are `jhash()` users with runtime keys ≥16 B — i.e. nft set/concat
keys. `inet_ehashfn` (12 B `jhash_3words`) and 4-byte sites stay
jhash, full stop. Whether a ~30–60 net cy/hash saving is material at
any real call site still requires the gate-4 call-site A/B and gate-5
threshold before any conversion patch.

## Gate-4 nft-set call-site A/B — run 2026-07-11

Run without touching the image: `test_nftsetbench.ko` (same PMU/chunk
infra as the microbench, scp'd onto the running kernel) A/Bs the
complete lookup — hash + `reciprocal_scale`/bucket math + chain walk +
key `memcmp` — through two structures faithful to
`net/netfilter/nft_set_hash.c`: a replication of the fixed `nft_hash`
backend (individually kmalloc'd elements, hlist buckets) and the
**real** `lib/rhashtable.c` driven exactly like `nft_rhash`
(cmp-arg + `hashfn`/`obj_hashfn`/`obj_cmpfn`). Every table passed a
full verify (all 64k inserted keys found, no absent key found) before
timing. Patterns: hot-hit (one key hammered — upper bound), cold-hit /
cold-miss (result-dependent pseudo-random key order — realistic,
bucket cache misses included).

Min cycles/lookup, jhash → nano32:

| Structure | klen | pop | hot-hit | cold-hit | cold-miss |
|---|---|---|---|---|---|
| nfthash | 16 | 1k | 132→108 (−18%) | 148→126 (−15%) | 142→120 (−16%) |
| nfthash | 16 | 64k | 154→108 (−30%) | 169→191 (**+13%**) | 575→553 (−4%) |
| nfthash | 32 | 1k | 195→135 (−31%) | 199→154 (−22%) | 179→140 (−22%) |
| nfthash | 32 | 64k | 179→151 (−16%) | 212→195 (−8%) | 626→581 (−7%) |
| nfthash | 48 | 1k | 237→160 (−32%) | 239→172 (−28%) | 220→160 (−27%) |
| nfthash | 48 | 64k | 221→160 (−28%) | 335→252 (−25%) | 759→701 (−8%) |
| rhash | 16 | 1k | 211→151 (−28%) | 198→165 (−17%) | 185→159 (−14%) |
| rhash | 16 | 64k | 176→151 (−14%) | 208→177 (−15%) | 608→591 (−3%) |
| rhash | 32 | 1k | 218→176 (−19%) | 237→194 (−18%) | 222→180 (−19%) |
| rhash | 32 | 64k | 218→176 (−19%) | 267→239 (−11%) | 670→626 (−7%) |
| rhash | 48 | 1k | 260→201 (−23%) | 286→220 (−23%) | 261→202 (−23%) |
| rhash | 48 | 64k | 260→201 (−23%) | 315→245 (−22%) | 795→729 (−8%) |

Findings:

- **The microbench delta survives at the call-site level.** nano32 wins
  35 of 36 cells by 20–80 cycles absolute — consistent with its
  30–60 cy hash-level advantage carrying straight through the bucket
  math and chain walk. Instruction counts drop 25–45%.
- **Cache dominates the realistic worst case.** At 64k population with
  cold random misses, total lookup cost is 550–800 cy of which
  ~400–600 cy is bucket/element cache-miss stall — the hash choice
  compresses to −3…−8% there. The hash matters most when tables are
  cache-resident (small sets, hot flows).
- One anomalous cell (nfthash 16 B/64k cold-hit, +13%): different
  per-table random seeds give different bucket layouts; treat as
  layout/noise, not a systematic nano32 loss — the neighbouring cells
  and both miss columns at the same size go the other way.
- rhashtable costs ~40–60 cy more per lookup than the fixed nft_hash
  table at equal load — structure overhead, independent of hash choice.

**Verdict:** gate 4 *passes technically* — the improvement is
repeatable, outside run noise, with no loss of keying, context safety,
or architecture coverage (gate 5's mechanical criteria). But the
policy's first sentence still gates deployment: no workload on this
box has shown nft set lookups to be hot. With PPE/WED hw-offload,
established flows bypass nft entirely; set lookups run on slow-path
packets only, and the live ruleset's sets are small (cache-resident,
where the win is real but the absolute rate is low). **Decision: do
NOT write the conversion patch now.** File this as a ready-to-go
optimization with measured numbers; reopen only if a profile ever
shows `nft_hash_lookup`/`nft_rhash_lookup` material in a real
workload, at which point the conversion (nft_set_hash.c only, one
subsystem, one image) is pre-validated by this A/B.

## Wider-kernel beneficiary audit — 2026-07-11 (negative result)

With the cost model measured (nano32 wins 16–48 B keys by 30–60 cy,
Micro only differentiates ≥64–80 B, wins compress to 3–8% when
cache-miss-bound, DoS-keyed sites off-limits), the whole tree was
swept for other homes: `jhash/jhash2` call sites across net/, fs/,
kernel/, mm/, lib/, drivers/net/, security/, cross-checked against
this target's config and the **live router's** actual paths
(qdiscs, ruleset, conntrack, frag/BPF/xfrm counters probed
2026-07-11).

Every per-packet hash on this box falls into one of three buckets:

1. **Already hardware-hashed.** mtk_eth_soc RX sets
   `skb_set_hash(jhash_1word(FOE id))` for every PPE-parsed packet
   (v1 rxd4 path), so RPS (`rps_cpus=3`) and mac80211's fq
   (`fq_flow_classify` → plain `skb_get_hash()`, 6.12) *reuse* the
   existing hash; router-originated traffic reuses `sk_txhash`.
   Software flow dissection is a corner path (non-IP, PPE-missed,
   WiFi→WiFi bridged TX).
2. **Deliberately DoS-keyed siphash — never swap (policy).** The
   software flow dissector itself (siphash over ~52 B flow_keys since
   v5.4), conntrack `hash_conntrack_raw`, and every
   `skb_get_hash_perturb` user. These are the *biggest* per-packet
   hash consumers left, and they are security constructs, not
   performance hashes.
3. **Cold on this workload.** Live probe: **zero nft sets in the
   running ruleset**, 42 conntrack entries total, ReasmReqds=0 (no
   frag reassembly since boot), no BPF maps, no xfrm state, no
   fq_codel qdiscs (eth0=mq hw queues, rest noqueue). ip_fragment,
   xfrm_hash, bpf hashtab, tcp_cong, workqueue/lockdep, UBIFS r5
   name hashing, dcache (already word-at-a-time) — all cold here.
   The remaining grep hits (mlx5, batman, ovs, nfsd, dlm, …) aren't
   even built for this target.

The single technically-eligible site is one we already own:
`999-ppe-92`'s seeded-xxh32 flowtable tuple hash (~52 B). Measured
delta xxh32→nano32 at 48 B is 81→71 net cy — ~10 cy on a path that
only runs for not-yet-hw-offloaded flows. Not worth the churn; noted
for bundling only if that patch is ever touched again.

**Micro specifically has no customer:** no hot path in this kernel
hashes ≥64 B. Its niche (long-key bulk loop) exists upstream in
workloads this box doesn't run (BPF maps with large keys, OVS flow
tables, storage dedup).

Verdict: the investigation stays closed. The E8450's architecture is
the reason — PPE/WED move established flows off the CPU and the
driver hands the leftover stack a precomputed hash, so the kernel's
remaining hashing is either security-keyed or cold. The rapidhash
port's value on this box is as a shelved, pre-validated building
block, not a deployable win.

## Future directions

The default recommendation is **no replacement** until profiling identifies a
hash bottleneck. The microbenchmark phase above establishes the cycle
numbers so that decision can be made from data instead of library claims;
a candidate that wins there still has to clear gates 4 and 5 before any
call site changes. If a bottleneck does appear, investigate in this order:

1. rapidhashNano32/Micro per the candidate matrix above (audit winner);
2. existing in-kernel hashes with the same 32-bit output and context contract;
3. call-site-specific batching or reduced hashing work;
4. a PMULL-assisted implementation only for sufficiently long keys where its
   FPSIMD entry/exit cost is amortized.

Do not add PMULL to short-key jhash paths speculatively. For 4-byte and
12-byte inputs, measure the complete call cost first; instruction acceleration
for the mixing primitive does not imply a faster table lookup.

Historical source remains recoverable from git for audit purposes, but it is
not an implementation template.
