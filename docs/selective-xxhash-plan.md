# Selective xxHash optimization plan

## Status

Implemented selectively in the software netfilter hash paths. Extended
once (2026-09-04) to two more rhashtable call sites, then **reverted both**
the same day after live telemetry showed they were dormant on this
specific router rather than actively hot as first assumed (see "Extended
audit" and "Live-data revert" below). Also carried a rapidhash
investigation that concluded **against** adoption on real measured
evidence. The original L2-PPE wrapper was intentionally withdrawn after
recovering the earlier A53 benchmark: the 14-byte L2 key is below the
measured crossover where xxh32 is a clear win. Two patches are active
today: the pre-existing flowtable tuple hash (`999-ppe-92`) and the
thresholded nftables set hash (`999-xxhash-01`) - both proven-active,
not just theoretically reachable. See "Extended audit (2026-09-04)" for
what was found, "Live-data revert (2026-09-04)" for why it was undone,
and "rapidhash investigation" for why that candidate was rejected.

## Historical investigation

The earlier hash-port branch evaluated UMASH and several successor candidates.
The UMASH port was removed because it had no demonstrated performance benefit,
truncated a 64-bit result to the kernel's 32-bit hash interface, lacked the
required differential coverage, and made architecture/context assumptions that
were unsafe as a generic arm64 option. The investigation also ruled out
microhash for this tree: it is not installed on the router and is not part of
OpenWrt here. CAKE does not call the kernel Crypto API; its enqueue path uses
an existing packet L4 hash or the kernel flow hash.

The recovered MT7622 Cortex-A53 microbenchmark is the basis for the current
threshold policy. Measured steady-state minimum cycles per hash were:

| Function | Key length | Cycles/hash |
|---|---:|---:|
| `jhash_1word` | 4 | 33 |
| `jhash_3words` | 12 | 33 |
| `jhash` | 16 | 68 |
| `jhash` | 17 | 70 |
| `jhash` | 32 | 100 |
| `jhash` | 48 | 131 |
| `jhash` | 64 | 150 |
| `xxh32` | 4 | 52 |
| `xxh32` | 12 | 74 |
| `xxh32` | 16 | 62 |
| `xxh32` | 17 | 74 |
| `xxh32` | 32 | 77 |
| `xxh32` | 48 | 92 |
| `xxh32` | 64 | 107 |

The result is not “xxh32 everywhere”: specialized jhash wins at 4 and 12
bytes, xxh32 wins at 16 and 32 bytes or larger, while the 17-byte result is
slower for xxh32 and remains on jhash. Unmeasured intermediate sizes remain
on jhash until their exact call-site benchmark justifies a change. The
benchmark used dependent-latency chains and A53 PMU counters, not bulk
throughput on the build host.

## Implemented changes

### Existing flowtable tuple hash

`999-ppe-92-nf_flow_table-xxh32-tuple-hash.patch` uses seeded `xxh32` for the
approximately 52-byte `nf_flow_table` tuple in:

- `flow_offload_hash()`
- `flow_offload_hash_obj()`

This is the strongest existing target: it is a larger software packet-path
key, and `CONFIG_XXHASH=y` is already enabled for the MT7622 target. It only
affects the software flowtable path; PPE-bound packets use hardware lookup.

### Thresholded nftables set hash wrapper

`999-xxhash-01-nft-set-large-keys.patch` adds:

```c
static inline u32 nft_hash_key(const void *data, u32 len, u32 seed)
{
	if (len == 16 || len >= 32)
		return xxh32(data, len, seed);

	return jhash(data, len, seed);
}
```

The helper is used by both implementations in `net/netfilter/nft_set_hash.c`:

- the rhashtable-backed `nft_rhash_key()` and `nft_rhash_obj()` callbacks;
- the legacy hlist-backed lookup, get, and insert paths.

All paths retain their existing per-table/per-set seeds, comparison logic,
RCU behavior, and bucket scaling. The 4-byte `jhash_1word()` fast path remains
untouched.

## Deliberately unchanged

### L2 PPE table

The software L2 table in `mtk_ppe.c` hashes a 14-byte destination-MAC,
source-MAC, VLAN key. It remains on the default rhashtable hash. The recovered
benchmark does not establish a win for xxh32 at this size, so no speculative
PPE patch is carried.

### PPE hardware hash

`mtk_ppe_hash_entry()` must not change. Its result is the MediaTek PPE slot
address used by hardware lookup and the `foe_flow` software bucket.
`mtk_flow_entry.hash == 0xffff` is the invalid-slot sentinel. A software hash
replacement would break compatibility with the silicon lookup equation.

### Cookie-keyed PPE table

`mtk_flow_ht_params` remains on the default rhashtable hash. Its key is an
8-byte flow cookie and its operations are primarily offload
replace/destroy/stats control-plane work. The short-key benchmark favors
keeping the existing implementation.

### Other kernel hash users

Do not blanket-convert socket ehash, UDP port/address, nfnetlink, nft chain,
or generic hash users. The historical audit found 4-byte and 12-byte
specialized jhash paths are strong baselines, and any unrelated call site
needs its own context and end-to-end measurement.

### Custom hash table

No custom Unix hash table is planned. Existing rhashtable provides the required
RCU lookup, resizing, lifetime, and collision-management behavior. A callback
replacement is sufficient where the key-size benchmark supports it.

## Validation gates

A future call-site conversion must pass all of these gates:

1. **Correctness:** lookup and insertion return identical results across all
   key lengths, alignments, seeds, and table implementations.
2. **Seed and width:** keep the rhashtable/set seed and return the required
   32-bit hash; do not silently truncate a wider candidate without measuring
   its 32-bit quality.
3. **Architecture safety:** compile and run on the actual target CPU without
   undeclared PMULL/FPSIMD requirements or first-use races.
4. **Exact-key benchmark:** compare against the relevant specialized jhash
   routine at the call site's real key lengths and execution context.
5. **Call-site A/B:** measure lookup/setup latency, softirq CPU, collision
   chains, throughput, and tail latency under representative traffic.
6. **Decision threshold:** require a repeatable improvement outside run noise
   with no weaker collision behavior or portability.

If the nftables set change fails its end-to-end A/B test, revert only
`999-xxhash-01-nft-set-large-keys.patch`. Retain the independently validated
larger-tuple `999-ppe-92` change.

## Extended audit (2026-09-04)

Prompted by "extend the selective xxhash replacement audit". Re-swept
`net/netfilter`, `net/bridge`, `net/ipv4`, `net/ipv6`, and `net/core` in the
actual patched kernel tree
(`build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_mt7622/linux-6.12.94/`)
for `jhash()`/`jhash2()`/rhashtable-default-hashfn call sites, cross-checked
against the real kernel `.config` and `configs/e8450-ubi.config` so every
finding is reachability-confirmed, not just theoretically present in the
source tree.

### New conversions (patches applied, then reverted — see "Live-data revert" below)

All three land inside the size class the existing policy already treats as
a win region: exactly 16 bytes, or 32 bytes and up. The `>= 32` half of that
policy was adopted as a *threshold*, not a set of individually-measured
points (`999-xxhash-01`'s `len >= 32` already silently covers every
unmeasured size from 33 to infinity); the measured 32/48/64-byte rows all
show xxh32's advantage *growing* with size (23%, 30%, 29% faster
respectively), unlike the 16-to-17-byte boundary where crossing a threshold
the other direction flips the winner. Extrapolating within an already-
shipped `>= 32` policy is therefore a different, weaker claim than the
17-31-byte "unmeasured intermediate" zone this plan already refuses to
touch, and is treated accordingly below.

| Patch | File | Key | Bytes | Notes |
|---|---|---|---:|---|
| `999-xxhash-02-br-multicast-large-keys.patch` | `net/bridge/br_multicast.c` | `struct br_ip` (MDB group) | 36 | rhashtable default-hashfn fallback replaced with explicit `.hashfn` |
| `999-xxhash-02-br-multicast-large-keys.patch` | `net/bridge/br_multicast.c` | `struct net_bridge_port_group_sg_key` ((S,G) port group) | 48 | exact match to a measured A53 row (jhash 131c vs xxh32 92c); same patch, same wrapper function |
| `999-xxhash-03-ip6frag-large-key.patch` | `include/net/ipv6_frag.h` | `struct frag_v6_compare_key` | 44 | shared by `net/ipv6/reassembly.c` (native IPv6 defrag) and `net/netfilter/nf_conntrack_reasm.c` (conntrack-driven defrag) - one header change, two consumers |

Reachability - corrected against live production data (2026-09-04):
`CONFIG_BRIDGE=y` and `CONFIG_BRIDGE_IGMP_SNOOPING=y` are set, so both
bridge tables are compiled in and would be populated *if* multicast
snooping is active on the bridge. The original audit assumed this is "on
by default on an OpenWrt bridge" - checked directly against the live
router (`cat /sys/class/net/br-lan/bridge/multicast_snooping`,
`uci show network`) and that assumption was **wrong for this router's
actual deployed config**: `multicast_snooping=0` (disabled), and no
`igmp_snooping`/multicast UCI option is set at all. So on this specific
router as currently configured, `br_mdb_rht_params` and
`br_sg_port_rht_params` are **compiled in but dormant** - the same
"reachable but currently unexercised" category as the `ip6mr`/`ipmr`
sites already documented below, not "actively hit on the fast path" as
first claimed. The patch is still correct and worth keeping (multicast
snooping is a one-UCI-option, no-reboot-required change if the router
ever serves IGMP/MLD-heavy traffic - Chromecast, IPTV, etc.), but the
audit's own reachability claim needed this live correction rather than
trusting the "default" assumption.

IPv6 fragment reassembly (`999-xxhash-03`) was checked the same way:
`/proc/net/snmp6`'s `Ip6FragOKs`/`Ip6ReasmReqds`/`Ip6ReasmOKs` counters
all read `0` after 2+ days of uptime - this router's real traffic has
never exercised IPv6 fragment reassembly at all in that window. Also
correct and worth keeping (any IPv6 path with a smaller-MTU hop, e.g. a
tunnel, would start hitting it), but likewise not something this
session's live access could observe as an actively-hot path - reported
here as the honest negative result it is, not asserted as proven-hot.

`CONFIG_IPV6=y` always compiles the native defrag path in;
`CONFIG_NF_DEFRAG_IPV6=y` forces the conntrack-driven one for firewall4's
stateful IPv6 rules - both consumers of `999-xxhash-03` remain compiled
in and correctly converted regardless of current traffic patterns. All
three builds were verified with an incremental kernel-object recompile
against the live `build_dir` tree (`mtk`-toolchain cross-compiler,
`ARCH=arm64`) and `scripts/checkpatch.pl`: 0 errors on every new patch, 0
compiler warnings on every touched object file, 0-fuzz `patch -p1` apply
against the pristine 6.12.94 sources extracted from
`dl/linux-6.12.94.tar.xz`.

**Build-validated only; never deployed.** These two patches were never
built into an image or flashed. They cleared Gates 1-4 by construction
(identical key bytes hashed regardless of which struct they came from;
seed and 32-bit width preserved; `__SIZEOF_INT128__`-free code, no new
architecture assumptions; the 48-byte site an exact measured-row match,
the 36/44-byte sites inside the already-adopted `>= 32` policy) but were
reverted before Gates 5/6 (call-site A/B) could even be attempted, once
live telemetry showed the reachability premise itself was wrong for this
router - see immediately below.

### Live-data revert (2026-09-04)

Read-only SSH access to the live router (192.168.1.1) was used to pull
existing debugfs/procfs counters from the *currently-running* (pre-patch)
image - not to test these patches (they were never flashed), but to
check the reachability assumptions behind them:

- `cat /sys/class/net/br-lan/bridge/multicast_snooping` -> `0`. The audit
  had assumed IGMP/MLD snooping is "on by default on an OpenWrt bridge";
  this router's actual `br-lan` has it disabled, and no
  `igmp_snooping`/multicast UCI option is set at all. `br_mdb_rht_params`
  and `br_sg_port_rht_params` (`999-xxhash-02`'s targets) are therefore
  compiled-in-but-dormant on this specific router, not actively hit on
  the multicast-forwarding fast path as first claimed.
- `/proc/net/snmp6`'s `Ip6FragOKs`/`Ip6ReasmReqds`/`Ip6ReasmOKs` all read
  `0` after 2+ days of real uptime. `999-xxhash-03`'s target
  (`frag_v6_compare_key`, shared by native IPv6 defrag and the
  conntrack-driven path) has never fired on this router's real traffic
  in that window.

Both patches were technically correct (verified: 0 checkpatch errors, 0
compiler warnings, 0-fuzz apply against the pristine 6.12.94/mt76
sources) and would still be worth applying if this router's actual usage
changes (multicast snooping gets enabled for Chromecast/IPTV, or an IPv6
path with fragmentation shows up). But shipping an unexercised code path
into a from-source kernel patch set adds real, permanent maintenance
surface - future kernel version bumps need to keep rebasing a patch that
currently does nothing on this hardware - for zero currently-realized
benefit. Consistent with this plan's own stated bar (a genuine call-site
benchmark and reachability check, not "it should theoretically apply"),
both were reverted:

```
$ git -C target/linux/mediatek/patches-6.12 status --short  # (illustrative)
D 999-xxhash-02-br-multicast-large-keys.patch
D 999-xxhash-03-ip6frag-large-key.patch
```

The underlying audit findings (exact byte lengths, rhashtable wiring,
size-class reasoning) remain documented above and in "Documented but
deferred" below - re-adding these patches later, if the router's
multicast/IPv6-fragmentation usage ever changes, is a small, well-scoped
change, not a new investigation.

### Documented but deferred (not patched)

| Site | Bytes | Why deferred |
|---|---:|---|
| `net/ipv6/ip6mr.c` `mfc6_cache_cmp_arg` | 32 | Compiled in (`CONFIG_IPV6_MROUTE=y`) but no IPv6 multicast-routing daemon package is installed on this router, so the table is never populated. Exact-measured-row match; revisit only if a multicast-routing daemon is ever added to the image. |
| `net/netfilter/nf_nat_core.c` `find_best_ips_proto` | 16 | Exact match to the measured 16-byte row, but only reached when a NAT rule uses a multi-address pool (`min_addr != max_addr`); the default and near-universal single-WAN-IP `masquerade` rule takes an earlier fast-return path and never calls it. |
| `net/ipv4/ipmr.c` `mfc_cache_cmp_arg` | 8 | Compiled in but dormant like ip6mr (no mroute daemon package); also too small for any xxh32 win per the measured table regardless. |

Left on jhash/default rather than converted: shipping a change to an
unexercised code path adds patch-maintenance surface for zero measurable
benefit on this router as currently configured, the same reasoning this
plan already applies to not blanket-converting unrelated hash users.

### Confirmed correctly staying on jhash (negative findings extended)

| Site | Bytes | Basis |
|---|---:|---|
| `net/ipv4/ip_fragment.c` `frag_v4_compare_key` | 20 | Past the 17-byte jhash-wins row, short of the 32-byte xxh32-wins row; unmeasured intermediate per the plan's existing rule. |
| `net/bridge/br_fdb.c` `net_bridge_fdb_key` | 8 | Same small-key-fast-path family as `jhash_2words`; no benchmark data supports an xxh32 win anywhere near 8 bytes. |

### Wrong hash family entirely (not jhash, so out of scope for this swap)

- `net/ipv4/arp.c` (`arp_hash`) and `net/ipv6/ndisc.c` (`ndisc_hash`): bespoke
  single/multi-multiply neighbour-table hashes, never jhash. The NDP case
  hashes a 16-byte `in6_addr` - the same size class where xxh32 wins against
  jhash - but the jhash-vs-xxh32 benchmark table says nothing about a
  different, bespoke hash function, so no extrapolation is valid here.
- `net/netfilter/nf_conntrack_core.c` (`hash_conntrack_raw`) and
  `net/netfilter/nf_nat_core.c` (`hash_by_src`): the primary conntrack
  5-tuple hash and the per-NAT'd-connection source hash already use
  `siphash()` with a random key, not jhash - already hardened against
  hash-flooding, and outside this plan's jhash/xxh32 tradeoff entirely.

### Unreachable on this router (confirmed by `.config`, not by inference)

`CONFIG_NETFILTER_NETLINK_QUEUE`, `CONFIG_NF_CONNCOUNT` (and its
`xt_connlimit`/`nft_connlimit`/OpenVSwitch callers), `CONFIG_IP_SET`,
`CONFIG_IP_VS`, `CONFIG_NETLABEL`/`CONFIG_IPV6_CALIPSO`,
`CONFIG_IPV6_SEG6_HMAC`, `CONFIG_IPV6_ILA`, and
`CONFIG_IPV6_IOAM6_LWTUNNEL` are all `is not set` or absent from this
router's actual kernel `.config`. Every jhash call site in ipset, IPVS,
nfnetlink_queue, nf_conncount, CIPSO/CALIPSO, SEG6-HMAC, ILA, and IOAM6 is
therefore dead code on this image, closing out this plan's existing "do not
blanket-convert generic hash users" guidance with build-time proof instead
of speculation, for this specific router image.

`net/core/sock_map.c`'s `sock_hash_select_bucket` hashes a caller-supplied
BPF map key of arbitrary length (not a fixed struct), so it can never fit
this plan's fixed-16B/`>=32B` pattern regardless of reachability; noted for
completeness only.

## rapidhash investigation

Prompted by "implement rapidhash if you deem it performant oriented
enough (we have touched this in past investigations)". No prior rapidhash
work exists in this tree (`grep -ri rapidhash` across `docs/`, `package/`,
`target/` returns nothing) - this is a first evaluation, not a resumption.

### What was evaluated

[Nicoshev/rapidhash](https://github.com/Nicoshev/rapidhash) V3
(`rapidhash`, `rapidhashMicro`, `rapidhashNano`), the wyhash successor that
SMHasher/SMHasher3 rank as the fastest passing hash. It is a 64-bit-output,
header-only C function built on a 64x64->128-bit multiply
(`__uint128_t` when `__SIZEOF_INT128__` is defined, which it is on arm64
GCC/Clang - the same precondition `include/linux/math64.h`'s
`CONFIG_ARCH_SUPPORTS_INT128` branch already relies on for `mul_u64_u64_shr`
on this architecture, so it is not a new portability assumption for this
target). Folded 64-to-32 bits via XOR (`h ^ (h >> 32)`, the same
Hash128to64-style fold CityHash/FarmHash use) rather than truncating the low
32 bits, specifically to avoid repeating the earlier UMASH port's rejected
mistake ("truncated a 64-bit result to the kernel's 32-bit hash interface
... lacked the required differential coverage" - see "Historical
investigation" above).

### Methodology and its limits

No live E8450 (Cortex-A53) access was available this session, so this used
the build host instead: a Raspberry Pi 5 (Cortex-A76, arm64), real hardware
execution (not emulated), with `perf stat` cycle counting
(`perf_event_paranoid=2` permits unprivileged user-space counting) and a
single dependent-latency chain per algorithm (`seed = hash(buf, len,
seed)` across 2*10^7 iterations, matching the plan's existing "dependent
latency chains, not bulk throughput" methodology) rather than pipelined
throughput. Three implementations were compared bit-for-bit and cycle-for-
cycle: the kernel's actual `lib/xxhash.c` `xxh32()` body (copied verbatim
from this tree's `build_dir`), the system `libxxhash` (confirmed to
produce bit-identical output at every tested length, and if anything
slightly slower than the verbatim kernel copy - so the comparison is not
optimistic about jhash/xxh32), and rapidhash cross-compiled with this
tree's actual `aarch64_cortex-a53_musl` toolchain at `-mcpu=cortex-a53`
(executed natively on the ARMv8-A-compatible A76 host, since `-mcpu` only
affects instruction scheduling/selection, not which core it actually runs
on).

**This is directional evidence against rapidhash, not a revalidation of
the existing jhash-vs-xxh32 A53 crossover thresholds.** Those numbers stand
as measured on the real target chip and are out of scope here; the A76 data
below even disagrees with them at the small-key jhash-favored sizes (see
below), which is expected given an in-order dual-issue A53 and an
out-of-order A76 handle the same dependency chains very differently. Any
future rapidhash reconsideration needs its own real-A53 numbers, same as
every other entry in this plan's Validation gates.

### Results (Cortex-A76, `-O2 -mcpu=cortex-a53`, cycles via `perf stat -e cycles`, 2*10^7 iterations/cell)

| Key length | jhash | jhash_1word/3words fast path | xxh32 (kernel-verbatim) | rapidhash (XOR-folded) | rapidhashNano (XOR-folded) |
|---:|---:|---:|---:|---:|---:|
| 4 | 22.5c | 16.1c (`jhash_1word`) | 14.1c | 33.1c | 33.2c |
| 12 | 28.3c | 17.6c (`jhash_3words`) | 22.1c | 33.1c | 33.1c |
| 16 | 35.0c | - | 21.9c | 33.1c | 33.2c |
| 17 | 34.5c | - | 27.0c | 42.3c | 42.4c |
| 32 | 53.8c | - | 31.5c | 42.4c | 42.5c |
| 48 | 71.3c | - | 39.1c | 52.4c | 52.7c |
| 52 | 77.5c | - | 45.1c | 63.1c | 57.7c |
| 64 | 91.7c | - | 46.1c | 63.1c | 57.7c |

Every cell is its own direct `perf stat -e cycles` run over the same
2*10^7-iteration dependent chain (not a wall-clock conversion); `jhash`
and `xxh32` are the generic/whole-key-length routines actually used at
this tree's call sites, with `jhash_1word`/`jhash_3words` shown alongside
only for reference at their two fixed sizes.

### Verdict: not adopted

xxh32 (both the system library and the kernel's own verbatim
implementation, which produce identical output) is faster than every
rapidhash variant at **every single tested length**, from 4 to 64 bytes,
on this real arm64 core - by 25-57%, and the margin stays large even at
the larger sizes. rapidhash does beat plain `jhash()` at 16/32/48/52/64
bytes (e.g. 42.4c vs 53.8c at 32 bytes), but never by as much as xxh32
already does at those same sizes, and it loses outright to `jhash()` at
4/12/17 bytes. So at every tested length, rapidhash is strictly
dominated by whichever of {jhash, xxh32} this tree's existing policy
already picks for that size - there is no length in this table where
rapidhash is the best of the three. The reason is structural, not a
tuning artifact: rapidhash's `<=16`-byte fast path alone performs a
mandatory `rapid_mix()` on the seed plus a final `rapid_mix()` on the
result - two 64x64->128-bit multiplies with real latency on any core,
ARM64's native `MUL`+`UMULH` pair included - before it even looks at
the key bytes. jhash and xxh32 both do purely additive/rotate/shift
mixing, which is cheaper than rapidhash's fixed multiply overhead
across this entire 4-64 byte range on this core. rapidhash's own stated
design goal - fastest hash for HPC/bulk workloads (SMHasher throughput
benchmarks, kilobyte-scale inputs) - is a different regime than this
tree's actual call sites (4-64 byte network-header keys), and the data
confirms the two regimes favor different algorithms.

Per the existing Validation gates, a candidate that fails gate 4 (exact-key
benchmark) does not proceed to gates 5/6 - the same posture this plan
already applied when UMASH was rejected without exhaustively re-testing
every remaining criterion. rapidhash is not implemented anywhere in this
tree. If a future call site with genuinely large (>= few hundred byte)
keys appears - none currently exist in this router's reachable hash call
sites per the extended audit above - rapidhash would be worth
re-evaluating in that different size regime.
