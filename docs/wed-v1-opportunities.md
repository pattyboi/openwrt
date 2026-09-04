# WED-v1 opportunities — implementation status

## Status update (2026-08-31) — read this first

Controlled SER validation, called "pending" throughout this doc, is now
**done, with a definitive (partly negative) result**: the WED-03-class ring
bug this doc tracks (`914`/`916`) was real - found independently by reading
`mtk_wed_reset_dma()` directly, root-caused precisely (busy-path DMA reset
skips the WED-side ring index reset), and fixed as `999-wed-14`, confirmed
on hardware (stuck ring before, clean `QCNT=0` with advancing CIDX/DIDX
after). But a controlled SER under active traffic can still leave the AP
beaconless via a *separate* mechanism this doc doesn't cover: the MT7915
MCU firmware itself never acknowledges a command during full-reset
recovery - confirmed unfixable from host driver source, independently by
both a recovered prior investigation and this session. Full detail:
`docs/e8450-ppe-validation.md`. The rest of this doc is preserved for
process history; treat every "pending"/`[ ]` item below about controlled
SER as answered by the above, not open.

## Status update (2026-09-04) — roadmap closed here

- **WED-03**: "Test with a 5 GHz client attached and saved pstore/UART
  access" is done — this is exactly what the 2026-08-31 session ran
  (`999-wed-14`), confirmed on hardware: stuck ring before, clean
  `QCNT=0` with advancing CIDX/DIDX after, same repro, same hardware. See
  `e8450-ppe-validation.md`.
- **WED-16**: now provably moot, not just low-priority. Its own stated
  trigger condition was "only if repeated SER or attach causes ring
  allocation conflicts" — and separately, the vendor rationale ties it to
  the MCU-death loop. That loop is independently confirmed twice (a
  recovered prior investigation, and this fork's own 2026-08-31 testing)
  to be an MT7915 MCU firmware ACK failure during full-chip reset, not a
  ring double-initialization issue. No ring-init patch, including
  WED-16, can address it. Dropped from further consideration.
- **WED-20**: still the one real open candidate. Carried forward to
  [`e8450-upstream-roadmap-2026-09.md`](e8450-upstream-roadmap-2026-09.md).
- **WED-04**: still correctly deferred (no normal-runtime benefit).

This is an audit note for the E8450's PCIe MT7915 WED-v1 path. The two

### Current test image

- Full sysupgrade image was built and flashed with configuration retention.
- Image SHA-256:
  `fabf0c1976a216bac072bde359202a145461574c929ce7f65ff71c5a27fe25c7`.
- The image contains `914`, `915`, `916`, and `917` plus the existing PPE/WED,
  mt76, PCIe, and NAND changes.
- Post-boot `wed0/v1_queue` exists and reports zero occupancy at idle:
  WED TX0, WPDMA TX0, WED/WDMA RX0/1, and TX-free. Packed WPDMA and WED-WDMA
  CIDX/DIDX values are masked before QCNT calculation.
- WED remains enabled as version 1; PCIe and WAN are up; no new WED, SER,
  watchdog, timeout, BUG, or oops messages were logged.

The final corrected-image reboot initially had no 5 GHz station for 60 seconds;
the client subsequently re-associated and the corrected queue view remained at
zero occupancy.

### 5 GHz smoke test

- Station `d2:29:f6:28:f9:40` is associated on `wl1-ap0`, authorized, and
  authenticated. Signal averaged `-71 dBm`; current rates were
  `275.2/292.5 Mbit/s` RX/TX at 40 MHz HE NSS2.
- 100 ICMP packets from the test client to `192.168.1.220` returned 100/100:
  0% loss, `22.481 ms` average, `374.352 ms` maximum.
- The active AWG PPE binding remained paired and advanced from `1,148` to
  `3,613` packets (`381,548` to `1,219,286` bytes) during the test window.
- WED TX CIDX/DIDX remained equal. Hardware WDMA RX low indices also differed
  by one (`CIDX=0x21c`, `DIDX=0x21d`), consistent with zero occupied entries.
- The current diagnostic reports an invalid large `QCNT` for `WED_WDMA_RX0`
  because its packed CIDX was not masked. A correction is being built; use
  raw `txinfo`/WDMA indices for this image.
- No new PPE, WED, SER, watchdog, timeout, BUG, or oops messages appeared.

### 5 GHz smoke test on corrected image

- Station `d2:29:f6:28:f9:40` re-associated on `wl1-ap0`, authorized and
  authenticated. Initial signal averaged `-50 dBm`; rates were
  `573.5/541.6 Mbit/s` RX/TX at HE40 NSS2.
- The initial post-reconnect counters were `1,122` TX packets and `35` TX
- retries (`3.1%`). A 300-packet wired-to-5 GHz ICMP run returned 300/300
  with `97.398 ms` average RTT and `1,831.126 ms` maximum RTT.
- During the longer run the signal moved to approximately `-72 dBm`, RX rate
  fell to `206.4 Mbit/s`, and the cumulative counters reached `3,488` TX
  packets and `381` retries. The interval added approximately `346` retries
  over `2,366` TX packets.
- A follow-up 100-packet run returned 100% but averaged `258.616 ms` with a
  `1,963.015 ms` maximum. Counters then reached `4,681` TX packets and `568`
  retries; the signal averaged `-66 dBm`.
- Channel 52 survey busy time remained below 1% (`7,918/1,362,608 ms`);
  WED TX/RX queues all reported `QCNT=0`, and no WED/SER/watchdog/timeout
  errors appeared.
- The retry increase tracks the signal/rate collapse while channel occupancy
  stays low and WED queues drain. This currently favors client RF/path
  conditions over WED ring blockage. `tx_failed` equaled `tx_retries` in all
  samples; treat that field as driver/firmware accounting requiring a
  controlled iperf or packet-loss comparison, not as direct lost-packet count.


### Close-range retry investigation

- The station remained associated during sustained AWG traffic. At the latest
  sample it reported `10,389` TX packets, `1,236` retries (`11.9%`), and
  `-69 dBm` average signal with HE40/NSS2.
- A 200-packet wired-to-5 GHz ICMP interval returned 200/200 with 0% loss,
  but averaged `210.729 ms` and reached `2,811.056 ms` maximum RTT.
- The interval ended at `13,031` TX packets and `1,481` retries. The signal
  moved to `-73 dBm`, while RX/TX rates were `275.2/325.0 Mbit/s`.
- Channel 52 remained lightly occupied: `11,732/1,727,023 ms` busy time
  (`0.68%`), with `853 ms` BSS receive time. WED TX/RX queues all reported
  `QCNT=0`; no WED/SER/PPE/watchdog/timeout errors appeared.
- The data does not show a WED queue blockage. Retries and latency are
  strongly associated with weak per-chain RSSI (`-73..-81 dBm`) and rate
  fallback, despite low channel occupancy. The client/AP RF path remains the
leading cause. The strong-signal no-WireGuard A/B is now complete; a non-DFS
channel comparison remains optional.
- `tx_failed` continues to equal `tx_retries`; do not treat it as direct
  packet loss until compared with iperf/application loss. The mt76 source
  also has WED-dependent retry-statistics handling.

### Isolated close-range no-WireGuard comparison

- With WG disabled and the client within approximately 5 feet of the router,
  signal was `-44/-46 dBm`, HE40/NSS2, MCS11, with approximately
  `541.6/573.5 Mbit/s` TX/RX rates.
- The isolated 200-packet interval returned 200/200 with 0% loss. Counters
  changed by only `2` retries over `1,642` TX packets (`0.12%`).
- The following strong-signal interval added `31` retries over `2,646` TX
  packets (`1.17%`); station pings averaged `4.274 ms` with `9.515 ms`
  maximum.
- Channel 52 remained lightly occupied; WED TX/RX queues stayed at `QCNT=0`
  and no WED/SER/PPE/watchdog/timeout errors appeared.
- This isolates the earlier `10-16%` retry result to weak RF/path conditions
  and/or tunnel traffic rather than a WED queue stall. The repeated equality
  of `tx_failed` and `tx_retries` still requires iperf/application-loss
  correlation before treating that field as packet loss.

## Hardware and live-state boundary

- The MT7915 is attached to WED device 0 as version 1.
- WED TX ring 0 currently has equal CIDX/DIDX; WED-v1 WDMA RX is present,
  and station `d2:29:f6:28:f9:40` is currently associated on `wl1-ap0`.
- WED-v1 uses the hardware WDMA path. The software WED file is primarily
  attach/configuration/reset code, not a per-packet CPU datapath.
- Existing deployed recovery changes are the MT7915 PLE/RIOC L1-SER detector
  and vendor WDMA-PSE gating around DMA reset.

## Implemented candidate and remaining work

### WED-03 — WDMA RX hang after WED1 SER

Vendor patch:
[`999-wed-03`](https://raw.githubusercontent.com/mediatek/mtk-openwrt-feeds/main/25.12/files/target/linux/mediatek/patches-6.12/999-wed-03-fix-wdma-rx-hang-on-wed1-after-SER.patch).

This was the strongest remaining WED-v1 candidate and is now implemented in:
- `914-wed-v1-reset-rx-prefetch-after-ser.patch`: clear WED-v1 RX prefetch
  indices/FIFO after SER while leaving the WED-v3 sequence unchanged.
- `916-wed-v1-reset-configured-rx-descriptors.patch`: reset configured WDMA
  RX descriptor indices instead of skipping them.

The patches apply and the target kernel builds successfully.

- [x] Rebase WED-03 for the current source.
- [x] Build and inspect the generated WED-v1 reset sequence.
- [ ] Test with a 5 GHz client attached and saved pstore/UART access.

### WED-20 — shorten WED busy polling during SER

Vendor patch:
[`999-wed-20`](https://raw.githubusercontent.com/mediatek/mtk-openwrt-feeds/main/25.12/files/target/linux/mediatek/patches-6.12/999-wed-20-refactor-check-wed-module-busy-time.patch).

It changes `mtk_wed_poll_busy()` from a 1.5-second maximum wait to 100 ms.
The vendor rationale is that heavy bidirectional traffic can leave L1 SER
waiting several seconds and disconnect stations. This is potentially useful
with the E8450, but it is global: a WED-v1 operation that legitimately needs
more than 100 ms could be reported as failed prematurely.

- [ ] A/B WED-20 under heavy bidirectional 5 GHz traffic.
- [ ] Reject if it increases false busy/reset failures.

### WED-16 — prevent duplicate WDMA ring initialization

Vendor patch:
[`999-wed-16`](https://raw.githubusercontent.com/mediatek/mtk-openwrt-feeds/main/25.12/files/target/linux/mediatek/patches-6.12/999-wed-16-refactor-wdma-init-flow-to-avoid-double-init.patch).

This guards descriptor allocation and avoids resetting ring indices during
non-reset setup. It is relevant to repeated attach/reset/recovery, but the
vendor patch does not apply to the current tree because the local WED code
has diverged. It requires a deliberate rebase, not a direct import.

- [ ] Rebase WED-16 only if repeated SER or attach causes ring allocation
  conflicts.

### WED-08 — extended WED debugfs

Vendor patch:
[`999-wed-08`](https://raw.githubusercontent.com/mediatek/mtk-openwrt-feeds/main/25.12/files/target/linux/mediatek/patches-6.12/999-wed-08-extended-wed-debugfs.patch).

The current `wed0/txinfo` exposes ring registers but not calculated queue
occupancy for every ring. A reduced WED-v1-only diagnostic was implemented
as `915-wed-v1-debugfs-queue-state.patch`. It adds `wed0/v1_queue`, reporting
raw CNT/CIDX/DIDX and calculated QCNT for WED TX, WPDMA TX, WDMA RX, and
TX-free rings. It is diagnostic-only and does not alter forwarding.

- [x] Add reduced WED-v1 queue diagnostics.

### WED-04 — configured-ring cleanup

Vendor patch:
[`999-wed-04`](https://raw.githubusercontent.com/mediatek/mtk-openwrt-feeds/main/25.12/files/target/linux/mediatek/patches-6.12/999-wed-04-Fix-reinsert-wifi-module-cause-memory-leak-issue.patch).

It frees only configured rings during Wi-Fi module removal/reinsertion.
This is safe-looking but has no normal-runtime benefit; the router does not
normally unload MT7915 with WED active. Keep deferred unless controlled
module lifecycle testing becomes necessary.

## Hardware-gated or already-covered work

- WED-v2/v3 reserved-buffer, TX-free, RRO, RXDMAD_C, and AMSDU changes do not
  execute on this WED-v1 MT7915 path.
- Vendor PPE-drop support explicitly skips NETSYSv1.
- The upstream WED+Wi-Fi reset ordering fix is already present in the local
  driver.
- No remaining safe WED ring-size or token-count performance knob was found.
  Ring sizes and descriptor formats are hardware/protocol contracts.

## Recommended order

1. [x] Rebase WED-03 and add the WED-v1 RX prefetch reset fix — done,
   hardware-confirmed (`999-wed-14`).
2. [x] Add reduced WED-v1 queue diagnostics — done (`915`/`917`).
3. [ ] Evaluate WED-20's 100 ms timeout under real bidirectional traffic —
   open, see `e8450-upstream-roadmap-2026-09.md`.
4. ~~Rebase WED-16 only if ring double-initialization is observed~~ —
   dropped, trigger condition provably unmet (see 2026-09-04 status
   update above).
