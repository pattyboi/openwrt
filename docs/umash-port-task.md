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
   use the performance governor, run enough iterations to report cycles/hash
   and instructions/hash, and measure first-use separately from steady state.
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
per gate 3: pinned CPU, performance governor, cycles/hash and
instructions/hash, first-use measured separately from steady state.

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
