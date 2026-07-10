## UMASH Port Experiment

### Objective
Port UMASH (backtrace-labs/umash, MIT license) into the kernel tree as a
faster, provably DoS-resistant replacement for hsiphash at packet-input-exposed
hashtable call sites. This is an experimental performance project — not
targeting upstream. Target hardware is MT7622 (dual Cortex-A53) with PMULL
confirmed present in /proc/cpuinfo.

### Hardware capability confirmed
The vmull.p64 fast path will be taken. No software fallback needed.

### Prior hash work in this branch
- commit 633fe63: jhash → xxh32 in net/netfilter/nf_flow_table_core.c
  (flow_offload_hash / flow_offload_hash_v6). Non-crypto seeded, correct for
  that site. Do not touch this — it is intentionally xxh32.

### Source files to fetch before writing any code
https://raw.githubusercontent.com/backtrace-labs/umash/master/umash.c
https://raw.githubusercontent.com/backtrace-labs/umash/master/umash.h

Read both fully before writing a single line of kernel code.

### Reference files to read in this tree
- net/netfilter/nf_flow_table_core.c   — style reference for the xxh32 patch
- net/netfilter/nft_set_hash.c         — primary port target
- net/netfilter/nf_conntrack_core.c    — secondary port target
- include/linux/siphash.h              — what we are replacing at these sites
- include/linux/xxhash.h               — style reference for how xxhash was
                                         added to the kernel

### Port structure
1. Add include/linux/umash.h — kernel-adapted header (no malloc, no libc,
   __uint128_t is fine, gate PMULL path on CONFIG_KERNEL_MODE_NEON and
   __ARM_FEATURE_CRYPTO)
2. Add lib/umash.c — kernel-adapted implementation
3. Add lib/Makefile entry for umash.o
4. Per-subsystem init: declare static struct umash_params __read_mostly,
   call get_random_bytes() + umash_params_prepare() at module/subsystem init
5. Replace hsiphash call sites:
   hsiphash(data, len, &key)  →  (u32)umash_full(&params, 0, data, len)
   Output is u64; truncating to u32 for bucket index is safe — both 32-bit
   halves pass SMHasher independently.

### Hard constraints
- Kernel C only. No Rust, no userspace libc headers.
- __uint128_t is available in kernel GCC — use it for the wide multiply.
- NEON/crypto registers require save/restore in interrupt context.
  BEFORE replacing any call site, determine if it can be reached from
  softirq or hardirq context. If yes, either:
  a) wrap with kernel_neon_begin() / kernel_neon_end(), or
  b) exclude that site from the port and leave it on hsiphash.
  Do not skip this check. nf_conntrack_core.c in particular has paths
  called from softirq — flag these explicitly before patching.
- umash_params is 320 bytes. Declare per-subsystem as static, not on stack.
- Do not modify nf_flow_table_core.c — that file uses xxh32 intentionally.

### Collision bound (why this is better than hsiphash)
UMASH provides a proven collision probability of ⌈s/2048⌉ × 2^-56 for any
two distinct inputs of at most s bytes. This is a mathematical proof, not an
empirical security claim. hsiphash's DoS resistance is empirical only.

### Commit style for this branch
Follow existing patch commits in the branch:
- Subject: net/netfilter: replace hsiphash with UMASH for <subsystem> hash
- Body: explain the PMULL dependency, the collision bound, and the
  kernel_neon context handling decision for each patched site.
- Sign off with your usual SOB line.

### Success criteria
- Compiles clean for target mediatek/filogic with no warnings
- nft_set_hash and nf_conntrack_core boot and pass basic connectivity test
  on the E8450
- No kernel oops under iperf3 load (exercises the conntrack hash path hard)


## UMASH Expansion — Find More Call Sites

Now that UMASH is working in nft_set_hash.c, audit the broader net stack
for additional jhash/hsiphash call sites that are good candidates.

### How to find candidates
```bash
grep -rn "jhash\|hsiphash" net/ include/net/ \
  --include="*.c" --include="*.h" \
  | grep -v "\.mod\." | sort
```

For each result, determine:
1. Is the input data from a packet/untrusted source? (good candidate)
2. Is the call site reachable from softirq/hardirq context?
   - If yes: NEON wrapping is already handled inside umash_full() for
     inputs >16 bytes, but confirm the input size at this call site.
     Inputs <=16 bytes do NOT use PMULL — they use a scalar fallback —
     so those are safe from any context.
   - If no: no restriction at all.
3. Is it in a hot path? (prioritize — no point patching cold paths)

### Priority order to investigate
High value hot paths likely worth porting:
- net/ipv4/route.c / net/ipv6/route.c   — routing cache hash
- net/bridge/br_fdb.c                   — bridge forwarding table
- net/core/flow_dissector.c             — flow key hashing
- net/ipv4/udp.c / net/ipv6/udp.c      — UDP socket lookup
- net/ipv4/tcp.c                        — TCP socket lookup
- net/netfilter/nft_set_*.c             — any remaining nftables set types

Lower priority / likely leave alone:
- net/ipv4/inetpeer.c                   — cold path
- net/ipv6/addrconf.c                   — management plane only
- anything under drivers/               — out of scope

### For each candidate site, produce
1. The file and function name
2. The input struct/data being hashed and its size
3. Whether it is reachable from interrupt context (check call chain)
4. Whether input size is <=16 bytes (scalar) or >16 bytes (PMULL path)
5. A go/no-go recommendation with one sentence of reasoning

### Do not patch yet — audit and report first
Produce the candidate table before writing any code. Confirm findings
before proceeding to any new patch.
