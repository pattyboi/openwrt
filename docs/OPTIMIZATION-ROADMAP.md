# E8450 optimization and investigation roadmap

This roadmap is deliberately evidence-driven. The E8450 is a dual-core
MT7622 with hardware PPE/WED paths, so a change that improves a software
microbenchmark may have no effect on ordinary routed traffic. Every candidate
must first identify which packets execute the changed code.

## Safety gates for every hardware test

1. Record the exact git commit, image hash, DTS/DTB, kernel version, patch set,
   flow-offload settings, Wi-Fi state, and test topology. Leave the router's
   normal `ondemand` CPU policy unchanged.
2. Keep a known-good image and recovery procedure available. Never combine a
   NAND clock change with a networking or WED change.
3. Use one behavioral change per image. Preserve an independent reachability
   path and collect pstore/ramoops after every reboot or failure.
4. Stop on an AXI lock, repeated MCU recovery loop, NAND error, or unexplained
   packet loss. Do not treat a successful boot as validation.

## Priority 0 — establish a reproducible baseline

The last detailed live snapshot is from 2026-07-09, while the tree has changed
since then. Before interpreting new measurements, capture a fresh baseline:

- routed WAN↔LAN and WAN↔WLAN throughput with hardware flow offload on;
- software-only fallback with hardware flow offload disabled;
- CPU frequency, temperature, CPU time, `/proc/softirqs`, PPE
  counters, WED state, and Wi-Fi reconnect/recovery behavior;
- image identity and all relevant UCI/configuration state.

This baseline is more valuable than another isolated optimization because it
separates PPE-bound traffic from the CPU-bound first-packet and control paths.

## Priority 1 — finish the open functional proofs

### Bridged offload end-to-end

Use one wired and one Wi-Fi client on `br-lan`, run sustained bidirectional
traffic, and prove both `BIND` entries and rising PPE counters. Repeat with
hardware offload disabled as a control. Until this is done, `ppe-89/90/91`
should be described as boot/compile validated, not fully validated.

### SER control and candidate A/B

Run the same trigger with `wed_v1_txbm_quiesce=0` and `=1`, then test the two
candidate patches independently:

1. baseline, quiesce 0;
2. baseline, quiesce 1;
3. WDMA RX CPU index fix only;
4. PSE→WDMA blocking fix only;
5. both fixes, only if each prior step is clean.

Use identical traffic and firmware state, record the MCU error, WED breadcrumb
last checkpoint, recovery-loop count, Wi-Fi availability, and whether a power
cycle was required. This distinguishes an MCU firmware/reset problem from a
WED ring-state problem without touching the unsafe runtime attach path.

## Priority 2 — measure likely CPU-path wins

### Flowtable hash validation

`999-ppe-92` changes the software flowtable tuple hash; PPE-bound flows do not
exercise it after binding. Benchmark short-lived/unbound flows with hardware
offload disabled, compare collision distribution and CPU cycles, and verify
IPv4/IPv6 plus differing tuple lengths. Do not infer a WAN throughput gain from
the hash microbenchmark.

### Mark-to-queue forwarding test

The current proof is router-originated. Add a controlled transit test that
marks packets before the software TX selector, then verify whether the flow is
still software-transmitted or becomes PPE-bound. The result should document
the exact scope of `999-eth-27`; it may be useful for local/control-plane QoS
while irrelevant to hardware-offloaded transit.

## Priority 3 — only if a measured bottleneck remains

- Revisit cache-line or datapath compiler changes only when a reproducible
  software-path workload is CPU- or refill-bound; current line-rate results
  show ample headroom.
- Profile first-packet flow setup, conntrack accounting, nftables rules, and
  bridge learning before changing another hash or PPE path.
- Investigate QDMA queue occupancy and BQL under mixed local traffic and
  offloaded traffic; do not use NET_TX softirq skew alone as the motivation.
- Review upstream/LTS changes for MT7622-specific PPE, WED, SNFI, and PCIe
  fixes only after mapping each change to a live block and compiling a minimal
  one-change image.

## Explicitly deferred

- SNFI 100 MHz and 60 MHz parent-clock experiments: reverted and unsafe to test
  without a recovery-boot and flash-integrity plan.
- Runtime WED enable, MT7915E PCI unbind/rebind, and attach-time experiments:
  historically capable of unrecoverable AXI locks; use boot-time WED/SER tests
  and the documented independent reachability protocol.
- Generic UMASH/rapidhash replacement: no change enters the image without
  differential vectors, architecture gating, exact call-site benchmarks, and
  one-subsystem-per-image A/B evidence.
