# E8450 AQM v3 — investigation and outcome (2026-09-07)

Successor to the AQM v1/v2 work (`999-qos-06`, `08`, `11`–`16`, `18`, `19`;
chronology in [`research/qos-aqm-lab-notes.md`](research/qos-aqm-lab-notes.md)).

v3 set out to fix the software AQM controller's congestion signal. Four gates
were run on hardware first. They did not produce a better controller — they
established that **the controller had no input, and no benefit**, and that two
queue-policy defaults were throttling the connection by an order of magnitude.

**Outcome: the AQM controller and the register readout it polled are deleted.
CAKE is the AQM. The hardware is used as a per-port queue set with one rate cap
on WAN egress.** Shipped and hardware-validated.

## Contents

- [1. The four gates](#1-the-four-gates)
- [2. What shipped](#2-what-shipped)
- [3. Validation](#3-validation)
- [4. Why not a better controller](#4-why-not-a-better-controller)
- [5. Falsified hypotheses from the v3 plan](#5-falsified-hypotheses-from-the-v3-plan)
- [6. Residual risks and open items](#6-residual-risks-and-open-items)

## 1. The four gates

### Gate A — the AQM's counters do not exist on this SoC

`999-qos-05`/`11` added a NETSYSv1 per-queue counter readout by assigning
`mib_if = 0x1abc` to the v1 register map and entering the vendor's
`QTX_MIB_IF` debug mode. Sampling that readout on the live router:

```text
queue=7, 1 s spacing:   mib_count=0  mib_bytes=0
                        mib_count=9  mib_bytes=918
                        mib_count=0  mib_bytes=0
queue=7, back-to-back:  ten reads, all zero
```

With the AQM disabled and a saturating upload running through queue 7 — first
at 6.4 Mbit/s (CAKE-limited), then at 1.1 Mbit/s with that queue's own leaky
bucket forced to 2,000 kbit/s so the hardware was provably the bottleneck —
the counters still read 0 on ~95% of samples, with occasional values like
`count=1 bytes=1518`. A sweep of all 16 queues during sustained transmission
returned all-zero.

The vendor source settles it. In every MediaTek generation the entire MIB
debug block is gated to NETSYSv2-or-greater, and `qtx_mib_if` is assigned only
for the v2/v3 register maps:

```c
/* mtk-openwrt-feeds 25.12, 999-eth-90-...-support-proprietary-debugfs.patch */
if (mtk_is_netsys_v2_or_greater(eth)) {
        mtk_m32(eth, MTK_MIB_ON_QTX_CFG, MTK_MIB_ON_QTX_CFG, soc->reg_map->qdma.qtx_mib_if);
        mtk_m32(eth, MTK_VQTX_MIB_EN,    MTK_VQTX_MIB_EN,    soc->reg_map->qdma.qtx_mib_if);
        ...
}
/* reg_map hunk: .qtx_mib_if = 0x46bc for mt7986_reg_map and mt7988_reg_map only;
 * the NETSYSv1 mtk_reg_map gains .fsm and .fwd_count, never .qtx_mib_if. */
```

The 5.4-era gate is `if (!MTK_HAS_CAPS(eth->soc->caps, MTK_QDMA_V1_1))`, which
MT7622 also fails (`MT7622_CAPS` includes `MTK_QDMA_V1_1`). There is no v1
path anywhere in the feed. `0x1abc` was this ROM's own invention: the symbol
`MTK_QTX_MIB_IF` only resolves to that address because the 5.4 header computes
`QDMA_BASE` at compile time, and the code using it is unreachable on v1.

Consequence for the shipped controller: it computed
`delta = current - previous` over those readings. Any decrease underflowed
unsigned arithmetic to a value near 2⁶⁴, which exceeds every threshold — so
**the rate trigger fired on falling traffic**, at roughly 26 evictions per
minute (`unbind_total=40566` over 26 h) regardless of congestion.

This falsified the v3 plan's own leading hypothesis (clear-on-read counters).
Per that plan's kill criterion, the phase built on it was abandoned rather
than implemented.

### Gate B — `qos_toggle=1` puts both flow directions on the WAN upload queue

`mtk_flow_set_output_device()`'s conntrack-mark branch has an asymmetric path
(`ct_mark >> 16` for upload) gated on `odev == eth->netdev[1]` (GDM2). This
board's WAN is DSA port 4 behind gmac0 (`wan: port@4`), so that test is never
true and both FOE directions receive `ct_mark & MTK_QDMA_QUEUE_MASK`. The
shipped nftables policy set `ct mark 7` per *connection*.

Confirmed live during a wired-client HTTPS download:

```text
01830 BND IPv6 ... eth=80:69:1a:1e:85:83->2c:cf:67:83:cc:07  ib2=007c0437  # download
03e96 BND IPv6 ... eth=80:69:1a:1e:85:82->00:1c:73:00:00:99  ib2=007c0437  # upload
```

`ib2 = 0x007c0437` → `MTK_FOE_IB2_QID` (bits 3:0) = 7, `PSE_QOS` (bit 4) set,
on both directions. Queue 7 is the 8,300 kbit/s bulk cap. So bulk download and
every download's own ACK stream were metered by the upload bucket.

### Gate C — the HQoS scheduler ceiling is a router-wide QDMA cap

`tx_sch_rate_value=0x80008df2`: scheduler 0 has `MAX_WFQ | MAX_RATE_EN` with
man=95 exp=2 → 9,500 kbit/s. Every one of the 16 queues reports
`scheduler=0` — `MTK_QTX_SCH_TX_SEL` is never set by
`mtk_qdma_v1_base_word()` and the production `qdma_txq` writes pass `sch=0`.
Mainline leaves this register with `MAX_RATE_EN` clear.

A 3-reps-per-arm download A/B isolated the two caps, which turned out to be in
series:

| Arm | Download |
|---|---:|
| `qos_toggle=1`, scheduler-0 cap 9,500 | 5.69 Mbit/s |
| `qos_toggle=1`, no scheduler cap | 5.92 Mbit/s |
| `qos_toggle=2`, scheduler-0 cap 9,500 | 7.70 Mbit/s |
| `qos_toggle=2`, no scheduler cap | **76.6 Mbit/s** |

Removing either alone leaves the other binding, which is why every earlier
attempt to explain the download deficit failed. An 8-stream saturating
download with both removed sustained 82.7 Mbit/s on a 75 Mbit/s contracted
line, with loaded latency avg 39 ms / max 70 ms against a ~26 ms idle
baseline.

This is the correction to a conclusion that had propagated through the whole
research record: "this connection's real sustained download capacity is
~6-10 Mbit/s" (lab notes §31.1, §36–38) was this router capping itself.
`download_base_kbits=10000` and the `sqm-autorate-rust` max-clamp were both
calibrated against that artifact. The clamp is still correct as a mechanism;
the number it clamps to was wrong.

### Gate D — the controller is not load-bearing, and it is harmful

Decisive A/B: `qos_toggle=2`, no scheduler cap, hardware offload on, autorate
stopped so CAKE's rate was fixed. Four valid saturating upload reps per side,
retrying failed public-server reps, alternating servers.

| Configuration | Sent rate | Retransmits | avg | p50 | p95 | p99 | max |
|---|---:|---:|---:|---:|---:|---:|---:|
| AQM enabled | 8.27 Mbit/s | **364** | 25.8 ms | 25.0 ms | 31.7 ms | 35.8 ms | 43.1 ms |
| AQM disabled | 8.26 Mbit/s | **1** | 26.0 ms | 25.2 ms | 31.6 ms | 36.7 ms | 44.4 ms |

Identical throughput, identical latency at every percentile, and two to three
orders of magnitude fewer retransmits with the controller off. Tearing live
flows out of the hardware path 26 times a minute costs real retransmissions
and buys nothing measurable.

Note also that with the controller off the upload flow stayed PPE-bound
(`ib2` QID 7, 20 MB through it) and p95 was still 31.6 ms. Gate E's old
79.6 ms p95 for "offloaded + hardware cap" was measured with `pfifo_fast` as
the `wan` root qdisc, i.e. with no software queue at all for the unoffloaded
interactive traffic — not a verdict on the hardware queue itself.

## 2. What shipped

Kernel patch series:

- **deleted**: `999-qos-06`, `08`, `11`, `12`, `13`, `14`, `15`, `16`, `18`,
  `19` — the AQM controller, its byte accounting, flow scoring, single-pass
  eviction, flowtable teardown sync, ct-mark hold/release, and the MIB byte
  counter;
- **reduced**: `999-qos-05` now carries only the `fc_th` diagnostic control
  and readback. The invalid `mib_if = 0x1abc` mapping, the readout function,
  the `QTX_MIB_IF` bit definitions and the `mib_*` columns are gone;
- **re-anchored**: `999-qos-17` (PSE debugfs) had its insertion context on the
  AQM's file-operations struct;
- **added**: `999-qos-20`, a configurable PPPQ priority queue. Native PPPQ is
  what gives the per-direction split, but `999-qos-10` hardcodes `queue = 4`
  for learned EF/AF41/CS4/CS5, and under PPPQ queue 4 is LAN port 1's own
  per-port queue. The new `qos_prio_map` debugfs file takes
  `"<port_queue> <prio_queue>"` and remaps only flows egressing the shaped
  port. Default `"0 0"` preserves the old behaviour exactly.

Userspace:

- `qdma-shaper.config`: `toggle=2` (native PPPQ), `scheduler_rate_kbps=0`,
  `prio_map=1`; the `aqm` section is removed;
- `qdma-shaper.init`: writes `qos_prio_map` before `qos_toggle` (the map only
  affects flows bound after it is set) and no longer drives an AQM;
- `qdma-shaper.sh`: `status` reports `qos_toggle` and `qos_prio_map` instead of
  AQM state;
- `30-queue-mark.nft`: the `ct mark set 7/8` chain is gone. WMM→DSCP
  translation stays, and `meta mark set 4` stays because `999-qos-07` uses it
  to place non-offloaded priority packets on a queue;
- `sqm`: download `10000` → `75000`; `sqm-autorate`: `download_base_kbits`
  `10000` → `75000`, `download_min_percent` `60` → `20`.

Resulting queue policy:

| Queue | Class | Selection |
|---:|---|---|
| 7 | Bulk WAN upload, capped 8,300 kbit/s, weight 4 | DSA port 4 egress |
| 13 | WAN-egress TCP ACKs | `999-ppe-11` small-ACK boost |
| 8 | Priority WAN upload, weight 12 | Learned EF/AF41/CS4/CS5 via `qos_prio_map` |
| 3–6 | LAN egress, uncapped | DSA ports 0–3 |
| 4 | Software-path priority | `meta mark 4` |
| 0 | Wi-Fi (WED/WDMA) | No queue assigned on that path |

## 3. Validation

Built clean (zero compiler warnings on every touched object, full series
applies with no rejects), flashed via `sysupgrade -c`, verified from boot.

`sysupgrade -c` retained the previous UCI, so the live config was explicitly
migrated afterwards — the same trap recorded in lab notes §33.2. Verified
live: `qos_toggle=2`, `qos_prio_map=7 8`,
`tx_sch_rate_value=0x80008000` (no scheduler cap), q7 `effective_kbps=8300`,
`qdma_aqm` absent from debugfs.

Per-direction split confirmed from `ppe0/bind`, decoding `ib2` QID against
`etype` (`ntohs(BIT(dsa_port))`):

```text
  9 dsa_bit=1000 qid=7   # DSA port 4 (wan) -> capped upload queue
  8 dsa_bit=0400 qid=5   # DSA port 2 (lan3) -> its own per-port queue
  1 dsa_bit=0400 qid=7   # stale, bound before the toggle change
```

The priority remap is also confirmed end to end. An IPv4 upload marked
`TOS=0xb8` (EF) bound as:

```text
orig=192.168.1.6:58518->51.158.1.21:5202 etype=1000
ib2=b87c0438 packets=9896 bytes=14490712
```

The high byte preserves `0xb8`, `etype=1000` identifies WAN/DSA port 4
egress, and the low nibble is QID 8. The same host's ordinary WAN-egress
flows remained on QID 7.

Throughput and latency, wired client:

| Direction | Before | After |
|---|---:|---:|
| Download (6-stream saturating) | 5.7 Mbit/s | **66.1 Mbit/s** |
| Download loaded latency | — | avg 28.0 / p50 23.8 / p95 49.0 / max 56.6 ms |
| Upload (4 reps) | 8.26 Mbit/s @ p95 31.6 ms | 7.40 Mbit/s @ p95 31.3-35.6 ms |

Health after the cutover: no `Oops`/`BUG`/`WARNING`/call trace in `dmesg`,
both radios up, no conntrack stranded on `mark=153`, CAKE present on `wan`
and `ifb4wan`.

The ~1 Mbit/s upload difference is expected rather than a regression: with
download no longer throttled to ~6 Mbit/s, the upstream direction now carries
the ACK stream for tens of Mbit/s of concurrent household download, which
shares the same 8,300 kbit/s WAN queue. Upload latency is unchanged.

A useful negative control fell out of the same run. With `qos_toggle=1` and
the ct-mark rules removed, `ct_mark` is 0, so the mark branch selects
**queue 0** — uncapped. Three interleaved reps:

| Toggle | Upload | Retransmits | p95 | max |
|---|---:|---:|---:|---:|
| 2 (shipped) | 6.3-7.0 Mbit/s | 4-24 | 31.9-33.5 ms | 33.4-47.1 ms |
| 1 (no ct marks) | 12.5-13.0 Mbit/s | 1278-1766 | 69.6-137.0 ms | 260-267 ms |

That is the unshaped line rate with textbook bufferbloat, and it demonstrates
the WAN queue cap doing its job in the shipped configuration.

## 4. Why not a better controller

The v3 plan proposed a hysteresis/CoDel-style trigger, an estimated-depth
signal from PPE-versus-queue byte differences, and a binary admission gate.
None were built, for reasons the gates established:

- there is no per-queue counter to build a rate or depth signal from
  (Gate A). PPE per-flow counters exist (`has_accounting = true`), so a
  controller could sum per-flow byte deltas — but that only reproduces a rate
  signal whose entire purpose was to trigger eviction;
- eviction itself has no measurable benefit and a measurable cost (Gate D), so
  a better-triggered eviction is a better-aimed version of something worth
  zero;
- the interactive traffic that matters is not offloaded in the first place.
  ICMP, DNS, new flows, and router-originated traffic all take the software
  path and are queued by CAKE. That is why p95 stays near 31 ms with a bulk
  upload sitting in an unmanaged hardware bucket;
- the real defect was never the trigger. It was the queue policy putting two
  directions in one capped queue, and an aggregate scheduler cap nobody had
  attributed correctly.

The remaining honest statement about the hardware: NETSYSv1 offers a per-queue
rate meter and a CPU-saving fast path. It offers no queue observability and no
AQM. Use CAKE for queueing and the hardware for rate and forwarding.

## 5. Falsified hypotheses from the v3 plan

Recorded because this project's methodology depends on not carrying forward
retracted claims:

- **"MIB counters are clear-on-read."** Wrong. They are not counters on this
  SoC at all; the register is unimplemented (Gate A). The *consequence*
  described in the plan — underflow-driven spurious triggers on falling
  traffic — was right, for a different reason.
- **"The scheduler ceiling is a prime suspect for the download deficit."**
  Partly right, and worth less than expected on its own: removing it alone
  moved download from 5.69 to 5.92 Mbit/s. It only mattered once the queue
  collapse was also fixed (Gate C).
- **"The v2 hold table strands conntracks permanently."** Confirmed on
  hardware (two conntracks held `mark=153` for 36 s at `hold_ms=3000`, with
  `holds_active` exceeding the distinct tagged count). No fix was written: the
  code that created the hold table is deleted.
- **"Retire the eviction machinery only if Arm B wins the architecture
  gate."** Superseded. Gate D retired it without needing the admission-gate
  arm, because eviction lost to doing nothing.

## 6. Residual risks and open items

- **Offloaded download is unshaped.** A hardware-forwarded packet never
  reaches the `wan` ingress hook, so `ifb4wan`/CAKE cannot see it. Measured
  loaded latency at 66 Mbit/s is acceptable (avg 28.0 ms, p95 49.0 ms against
  a ~26 ms idle baseline), so this ships as a documented tradeoff. The lever
  is `flow_offloading_hw=0`, which returns both directions to CAKE at a CPU
  cost.
- **Priority traffic bypasses the q7 bulk cap.** This is intentional, but a
  sustained or misclassified EF/AF41/CS4/CS5 flow can consume the physical
  uplink. The live EF probe confirmed the full classification/remap path;
  production DSCP policy must remain conservative.
- **WRR weights are stale.** `bulk_weight 4` / `priority_weight 12` were
  chosen when queue 7 carried both directions under a 9.5 Mbit/s scheduler
  ceiling that made weights binding. With no scheduler cap they only matter
  once the physical link saturates.
- **Two-client fairness is still untested.** Every measurement in the record,
  including all of v3's, is single-client.
- **Stale FOE entries keep their old queue** across a `qos_toggle` change
  until they age out. Expected; worth knowing when reading `ppe0/bind` right
  after a reload.
- **`checkpatch.pl` reports three trailing-whitespace errors** on
  `999-qos-17`. These are unified-diff context lines for empty source lines,
  which must be a single space; GNU patch 2.8 on the build host rejects
  zero-length context lines outright. The lint complaint is an artifact of
  linting a `.patch` file as source.
