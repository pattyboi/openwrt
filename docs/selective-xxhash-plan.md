# Selective xxHash optimization plan

## Status

Implemented selectively in the software netfilter hash paths. The original
L2-PPE wrapper was intentionally withdrawn after recovering the earlier A53
benchmark: the 14-byte L2 key is below the measured crossover where xxh32 is a
clear win. The active patch now uses one thresholded wrapper for nftables set
hashes, covering the measured winning sizes: exactly 16 bytes and 32 bytes or
larger.

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
