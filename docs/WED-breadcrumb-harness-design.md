> Recovered 2026-08-31 from dangling commit `1da872b9af` on the abandoned
> `e8450-hw-driven` branch (this repo's history was reset to a fresh
> `e8450-deployed-minimal` line from `ba915c2ee7`, which does not include
> this branch). Preserved at git tag
> `archive/wed-ser-investigation-2026-07-12` (pushed to origin) so it
> survives gc. Content below is verbatim from that commit; see
> `docs/e8450-ppe-validation.md` for how it connects to the 2026-08-31
> controlled-SER regression investigation.

# WED v1 Breadcrumb Harness

Target: Linksys E8450 / MT7622 + MT7915E, no UART, single UBI rootfs, watchdog
31 s.

Purpose: make WED failures observable and make the v1 TX-BM quiesce hypothesis
runtime-testable.

## Scope

- `999-zzz-wed-breadcrumb-harness.patch`
  - adds a small reserved-memory breadcrumb region at `wed-breadcrumb@42fef000`
  - writes phase/id/arg checkpoints immediately before risky WED MMIO
  - replays the last checkpoint to `dmesg` on the next boot
  - exposes runtime params under `/sys/module/mtk_eth/parameters/`:
    `wed_debug_breadcrumb`, `wed_v1_txbm_quiesce`
- `999-zzz-mt7622-ramoops-console-capture.patch`
  - expands ramoops use so the replay survives reboot in `console-ramoops-0`

The harness is inert unless WED is manually armed after SSH is up.

## Verified runtime facts (2026-07-03)

- Router: Linksys E8450 (UBI), OpenWrt 25.12.4 `r32933-4ccb782af7`,
  kernel `6.12.87`
- `pstore` is mounted and `/dev/pmsg0` exists
- Live reserved-memory nodes:
  - `ramoops@42ff0000`
  - `wed-breadcrumb@42fef000` with `no-map`
- Live params:
  - `/sys/module/mtk_eth/parameters/wed_debug_breadcrumb`
  - `/sys/module/mtk_eth/parameters/wed_v1_txbm_quiesce`
  - `/sys/module/mt7915e/parameters/wed_enable`
- Live WED debugfs:
  - `/sys/kernel/debug/wed0`
  - `/sys/kernel/debug/wed1`
- Live SER trigger:
  - `/sys/kernel/debug/ieee80211/wl1/mt76/sys_recovery`
  - do not hardcode `wl0` / `phy0`
- `devmem` is not installed on the image; rely on `dmesg` and
  `/sys/fs/pstore/console-ramoops-0`

Raw probes are under `.recall/router-probes/2026-07-03-breadcrumb-audit/`.

## Checkpoint map

Phases:
- `1`: stop
- `3`: reset DMA
- `4`: start
- `5`: FE reset

Important IDs:
- `10..12`: stop path and optional v1 TX-BM pause
- `30..37`: reset-DMA path, including the token FIFO drain loop
- `50..55`: FE reset / ethsys side

Interpretation:
- last `33` usually means the hang is inside the TX-BM token-FIFO read loop
- last `53` or `54` points at the FE/ethsys reset side
- no phase-3 progress after stop points back toward the MCU/SER wait side

## Current limitation

The initial `wed_enable=Y` PCI rebind fault hard-locks the SoC before the
watchdog resets it. Recovery requires a cold power-cycle, which clears both
ramoops and the breadcrumb region. That means the breadcrumb harness is still
useful for warm-reset/SER cases, but not for the current attach-time hard lock.

Netconsole was the original plan for that case, but it is broken on this
image: netpoll TX silently drops every frame before ndo_start_xmit (verified
2026-07-03; console layer itself works — markers reach ramoops/dmesg). See
the beads bug for the full diagnosis.

Instead, `999-zzzz-wed-attach-netconsole-trace.patch` now gates the traced
MMIO: with `wed_debug_breadcrumb=1` and `wed_attach_max_access=N`, traced
accesses beyond sequence N are skipped (reads return 0) and attach fails
cleanly. `N=0` enumerates the whole attach access list with the SoC
surviving (read dmesg over SSH); stepping N upward executes the real access
prefix until the first hard-locking access is identified — one cold
power-cycle total.

## Current attach trace result

The bind sequence reaches these blocks in order:

1. WED0: clear WPDMA TX/RX driver bits
2. WED0: clear WDMA RX driver bit
3. WED0: clear WED TX/RX DMA bits
4. WDMA0: first read-modify-write of DMA state
5. PCIe mirror: clear port-0 mirror
6. WED reset/init and MT7915 WPDMA base programming
7. HIFSYS: clear PCIe0 coherent-DMA-agent mapping

~~Current prime suspect: the first WED0 access at offset `0x508`.~~
DISPROVEN 2026-07-03: the `wed_attach_max_access=0` run (all traced MMIO
skipped) still hard-locked the box, and a plain detached
`ip link set eth0 down; up` (no WED at all) locked it identically. The bug
is the mtk_eth stop/open path; WED only reaches it via the
`mtk_eth_set_dma_device` close/reopen (eth node is `dma-coherent`, swap
happens on attach and again on detach). Not an oops (panic auto-reboot armed
but never fired). Next: debug kernel (MAGIC_SYSRQ + DETECT_HUNG_TASK) plus
`docs/e8450-eth0-deadman.sh` to capture the hung-task stack in ramoops and
self-recover via `reboot -f`. See `docs/HANDOFF-codex.md`.

## First SER quiesce run — result (2026-07-10)

Run by the user with the breadcrumb/trace harness armed (WED-AT lines in
the log prove `wed_debug_breadcrumb=1`; the `wed_v1_txbm_quiesce` value
was not echoed into the log — capture it explicitly next run). Router had
been up ~4.8 h with WED attached. Evidence:
`docs/logs/wed-quiesce-ramoops-20260710.txt` (console-ramoops preserved by
fast power-replug), plus the breadcrumb replay on the following boot:
`WED-BC last boot: ph=4 id=40 arg=0x0 seq=104`.

What the evidence shows:

- **No SoC/AXI hard lock.** Breadcrumbs advanced through stop (phase 1)
  and reset-DMA (phase 3) into start-entry (`ph=4 id=40`) — no id-33
  token-FIFO-drain hang signature. The box kept routing (ethernet path
  untouched) and kept writing console logs until the user pulled power.
- **mt7915 MCU death instead:** `Retry message 000013ed (seq 1)` →
  `Message 000013ed (seq 1) timeout`, then mt76 looped full-chip
  restarts (repeated HW/SW + WM/WA firmware banners at 17334 s, 17347 s,
  …), each restart re-running the traced WED attach. Wireless never
  accepted clients again until the power cycle.

Interpretation: the wifi death in this path is an **MCU/firmware-recovery
failure, not a WED TX-BM hang** — WED's own stop/reset/start sequence
completes. This is the "points back toward the MCU/SER wait side" branch
of the checkpoint map above.

Recovery notes: fast replug preserved ramoops as designed; no pstore
`dmesg-*` was created (no panic, so no recovery-boot trap); router came
back on the normal volume with WED attached and stations associating;
all harness params reverted to defaults on boot.

Open follow-ups:

1. ~~Baseline A/B leg: repeat with `wed_v1_txbm_quiesce=0`~~ DONE
   2026-07-12, see "2×2 discriminator result" below.
2. ~~If the MCU loop reproduces in both legs, the target shifts to the
   mt76 SER/MCU restart path~~ SUPERSEDED — it reproduces in both WED
   legs but NOT with WED detached, so the target is WED/WDMA reset
   state after all (see below).

## 2×2 discriminator result (2026-07-12)

Ran the three legs the doc called for (quiesce×WED-attach; quiesce is
meaningless with WED detached so that cell was skipped), each isolated
by a clean `reboot` between legs (ethernet/SSH stayed up throughout —
no AXI/SoC lock in any leg, matching the 07-10 finding):

| Leg | wed_enable | quiesce | Result |
|---|---|---|---|
| A | Y | N (0) | **MCU-death loop**: `Message 000013ed timeout` repeating with WM/WA firmware reload banners, indefinitely (watched to seq 4700+ WED-AT trace lines / ~100s, never self-recovered). Breadcrumb replay next boot: `ph=4 id=40 seq=104`. |
| B | Y | Y (1) | **Same MCU-death loop**, identical `0x13ed` signature, identical breadcrumb (`ph=4 id=40`, seq incremented to 105). Confirms quiesce does not gate this failure in either direction. |
| C | N (detached via modules.d + reboot) | n/a | **Clean SER recovery.** No `0x13ed`, no retry/firmware-reload loop. `wl1-ap0` came back up normally (AP mode, hostapd alive, SSID served) within ~15s of the trigger. |

Logs: `docs/logs/wed-quiesce-legA-quiesce0-20260712.txt`,
`-legB-quiesce1-20260712.txt`, `-legC-detached-20260712.txt`.

**Conclusion: the MCU/SER restart failure is WED-dependent, not a
generic mt76 SER/MCU bug and not quiesce-gated.** This satisfies the
doc's own decision criterion from the prior audit ("if SER recovers
without WED and wedges with it, the WED/WDMA reset-state theory is
confirmed and the wed-03/13 backports are justified") — **the
backports are now justified**. Next step: flash the prepared
`999-zzzzz-wed-ser-01` (CPU_IDX inversion fix) and `-02` (PSE/WDMA
block during reset) and repeat leg A/B to see if the loop clears.

## Backport retest — NEGATIVE result (2026-07-12, same day)

Built and flashed an image with both backports in (clean patch apply,
clean compile, manifest gate passed — see `docs/BUILDING.md`-style log
`docs/logs/build-wed-ser-backports-20260712.log`), then reran leg A and
B against the patched kernel:

| Leg | wed_enable | quiesce | Result |
|---|---|---|---|
| A2 (patched) | Y | 0 | **Same MCU-death loop** — `0x13ed` timeout repeating, watched ~100s, never self-recovered. |
| B2 (patched) | Y | 1 | **Same loop again**, same signature. |

Logs: `docs/logs/wed-quiesce-legA2-patched-quiesce0-20260712.txt`,
`-legB2-patched-quiesce1-20260712.txt`. Ethernet/SSH stayed alive both
times (no AXI lock); recovered with a plain `reboot` each time (note:
`wed_enable` persists across a plain reboot but resets to the
package-default `N` after a *sysupgrade* — must be re-set via
modules.d post-flash every time, see [[e8450-router-access]]).

**The wed-03/wed-13 backports do NOT fix this failure mode.** The
WED-attached-vs-detached discriminator from the same day is still
valid evidence that the failure is WED-path-dependent, but these two
specific patches aren't the (or aren't the whole) fix. Per the
original sequencing plan, the next escalation candidate is
`999-wed-16-refactor-wdma-init-flow-avoid-double-init` (re-init
robustness: alloc keyed on `!desc` instead of `!reset`, CPU_IDX
rewrite on reset) — "take only if 03+13 don't resolve the MCU-death
loop," which is now the case. Also worth reconsidering: the original
code-trace theory (host-side response path racing the WM firmware
reboot, `mtk_wed_device_start()` writing WPDMA regs while WM is still
coming up) may be closer to the real cause than a WDMA-ring
reset-state bug — the backports targeted ring/CPU_IDX state, not the
response-path race.

## wed-16 retest — ALSO NEGATIVE (2026-07-12, same day)

Recovered `999-wed-16-refactor-wdma-init-flow-to-avoid-double-init`
from the SDK commit (`eef2a51256`) as
`999-zzzzz-wed-ser-03-refactor-wdma-init-avoid-double-init.patch`. The
pristine SDK hunk's context matched this tree exactly (the touched
functions — `mtk_wed_wdma_rx_ring_setup`, `mtk_wed_wdma_tx_ring_setup`,
`mtk_wed_tx_ring_setup`, `mtk_wed_rx_ring_setup`, `mtk_wed_start` —
weren't touched by wed-ser-01/-02), so no v1 adaptation was needed;
only the hunk offsets needed regenerating against this tree (`patch`
auto-relocated 4 of 5 hunks via fuzzy search, the 5th was applied by
hand at the unchanged pre-image location and round-tripped byte-
identical against a clean copy before being committed as a patch file).
Built, flashed, re-enabled WED (same post-sysupgrade modules.d reset
gotcha), reran leg A/B a third time:

| Leg | wed_enable | quiesce | Result |
|---|---|---|---|
| A3 (wed-16) | Y | 0 | **Same MCU-death loop.** `0x13ed` appeared slightly later (~77s vs ~85-90s in prior runs) but otherwise identical signature, never self-recovered. |
| B3 (wed-16) | Y | 1 | **Same loop again.** |

Logs: `docs/logs/wed-quiesce-legA3-wed16-quiesce0-20260712.txt`,
`-legB3-wed16-quiesce1-20260712.txt`. Ethernet/SSH alive throughout,
recovered via plain reboot each time.

**Three backports in a row (wed-03, wed-13, wed-16) — none fix the
`0x13ed` MCU-death loop.** All three targeted WDMA/WED-side ring or
reset-sequencing state. The persistence of an identical failure
signature across three independent state-management fixes is now
fairly strong evidence the bug is NOT in WED's ring/reset bookkeeping
at all, but genuinely in the **mt76/mt7915 MCU response path** — i.e.
back to the original code-trace theory: `mt7915_mac_full_reset()`'s
10x retry downloads firmware successfully (`mt7915_firmware_state()`
passes) but the very first post-download command
(`mt7915_mcu_fw_log_2_host`, our `0x13ed`) never gets a response,
every iteration. The WED-attached-vs-detached discriminator still
holds — so whatever's wrong is something WED *triggers* in that
response path (e.g. WED still driving WPDMA registers the MCU expects
to own during its own reboot), not a WED-side data-structure bug in
scope for any of the three tried patches. **Recommended next step:
instrument/trace the actual host↔MCU response path during a WED-
attached SER (mailbox/ring state at the moment `0x13ed` is sent) rather
than trying more WDMA-side patches from the SDK series 03/13/14/16.**

## Terminal failure signature — live trace (2026-07-12)

All three prior legs (wed-03/13/16 backport retests, above) only watched
each SER for ~100s and never saw the actual end state — the "MCU-death
loop" is not infinite. A live trace run long enough (~180s) captured it:

1. `mt7915_mac_full_reset()` retries `mt7915_mac_restart()` up to 10×
   (~11s/iteration: WM/WA firmware reload, then `0x13ed`/`fw_log_2_host`
   sent, 5s retry + 5s timeout). The response never arrives on **any** of
   the 10 attempts.
2. Driver gives up explicitly: `mt7915e 0000:01:00.0: chip full reset
   failed` — deliberate retry-budget exhaustion, not a silent hang.
3. `ieee80211 wl1: Hardware restart was requested` fires mac80211's own
   `ieee80211_reconfig()` recovery path, which immediately logs `Hardware
   became unavailable during restart.` and WARN_ONs.
4. mac80211 force-tears-down every interface
   (`cfg80211_shutdown_all_interfaces()` → `dev_close()` →
   `cfg80211_stop_ap()` → `__sta_info_flush()` →
   `__ieee80211_stop_tx_ba_session()` → `drv_stop()`); each teardown step
   also fails against the dead hardware and throws its own `WARNING:` — 6
   separate WARN_ON traces in ~2s. None are panics; pstore stayed clean
   (`console-ramoops-0` only) before and after — safe within rule 3's
   boundary.
5. End state: `wl1-ap0` still exists in `iw dev` (type AP) but has no
   channel/SSID configured — a zombie interface, hostapd never recovers
   it without a reboot. `wl0-ap0` (2.4GHz) is separate silicon
   (`mt7622-wmac`, SoC-integrated, not the mt7915e PCIe chip) and is
   completely unaffected.

**Live WED ring evidence** (`/sys/kernel/debug/wed0/txinfo`, polled every
2s across a full failure window, no kernel rebuild needed): the `WED TX
FREE` / `WED_RING_RX(1)` ring — the WED-bound `MT_RXQ_MCU_WA` completion
path where `0x13ed`'s response would land — keeps `BASE`/`CNT` configured
(`0x450a2000`/`0x200`, never torn down) but `CIDX`/`DIDX` are frozen
absolutely solid (`0x1fa`/`0x1fb`) for the entire ~140s capture, no
movement at all. The MCU's response genuinely never reaches the host DMA
path on any retry.

**Two host-driver theories ruled out by code trace before the live
test** (mt76 2026.03.19~39c960c3):
- Asymmetric WED ring reset in `mt7915_dma_reset()`: the first cleanup
  loop skips `mt76_queue_reset()` for `MT_WED_Q_TXFREE` queues, but this
  is intentional — the later unconditional `mt76_queue_rx_reset()` loop
  calls `mt76_wed_dma_setup(dev, q, true)` for every queue, which does
  the real reset+rearm via `mtk_wed_device_txfree_ring_setup()`. Not a
  skip bug.
- `MT76_STATE_WED_RESET` / `mt76_wed_dma_reset()` completion-wait: tested
  (`wed.c:201`) but never set anywhere in the mt76 tree, so always a
  no-op — looked like missing synchronization, but `mtk_wed_reset_dma()`
  (the actual WED-side reset) is fully synchronous register polling; this
  completion pairing belongs to the separate ethernet-FE-side reset flow
  (`mtk_wed_fe_reset_complete()`), unrelated to this WLAN SER path.

**Conclusion:** wed-03/13/16 were never going to fix this — they target
WED/WDMA ring-reset bookkeeping, but the driver's 10x retry loop already
runs to completion correctly and gives up as designed; the defect is that
WM firmware's `fw_log_2_host` response never arrives at the host on any
of 10 independent attempts. Points at either (a) WM firmware not
generating/sending the response while WED is attached, or (b) WED gating
something at the hardware level (e.g. `MTK_WED_CTRL_WED_TX_FREE_AGENT_EN`
re-assert timing — `mtk_wed_reset_dma()` explicitly clears it as step 3;
worth checking it's re-set before *every* retry's `0x13ed`, not just once)
that discards the response before the host ring ever sees it. `MTK_WED_CTRL_WED_TX_FREE_AGENT_EN` (bit 10, register `MTK_WED_CTRL` =
`0x00c`) — CLOSED 2026-07-12, ruled out by live trace, not the bug.
Static code trace first suggested a plausible latch bug:
`mtk_wed_hw_init()` (where the bit gets re-enabled) has an
`if (dev->init_done) return;` early-out, and that re-enable code only
runs once — but `mtk_wed_reset_dma()` (which clears the bit every retry)
also unconditionally resets `dev->init_done = false` right before its v1
early-return (line 2011, before the `mtk_wed_is_v1()` branch at 2012),
so the guard doesn't actually block re-arming on subsequent cycles.
Live-verified via `/sys/kernel/debug/wed0/regidx`+`regval` (regidx=12 =
byte offset `0x00c`, no rebuild needed), polled every 1s across a full
fresh-boot repro (`sys_recovery`=7): `MTK_WED_CTRL` read `0x01000505`
(bit 10 set) at the very first sample and **never changed** for the
entire ~200s window, through all 10 `0x13ed` retries and the terminal
`chip full reset failed`. The register-level enable gate is correctly
asserted throughout — this is not where the response is being lost.

**Status after this round: three host-driver theories checked and ruled
out (asymmetric ring reset, dead `MT76_STATE_WED_RESET` completion wait,
`WED_TX_FREE_AGENT_EN` gating), plus the three SDK backports (wed-03/13/16)
already proven negative, plus no firmware-side diagnostic channel exists
(`fw_debug_wm`/`wa`/`bin` circular, no UART).** The WED-bound MCU
response ring stays hardware-armed and enabled the whole time, yet WM
firmware's `fw_log_2_host` reply never arrives, on any of 10 independent
attempts, every single repro run. This is now squarely a WM-firmware-side
question (does it even generate a reply while WED is attached, or is it
stuck on something else internally) rather than a host driver/WED
ring-state bug — and that is not diagnosable from this host without
either UART access, firmware symbols, or a different WM firmware build to
compare against. Next-direction candidates: (a) try a different/older WM
firmware blob if one is available, to see if this is version-specific;
(b) compare WED-detached-vs-attached MCU behavior more granularly (e.g.
does a *non-WED* SER's `fw_log_2_host` also occasionally show latency,
just not enough to hit the 5s timeout?); (c) treat this as accepted
WED-v1 hardware/firmware limitation on this chip and shift focus to
avoidance (e.g. keep WED detached during conditions likely to trigger
SER) rather than continuing to chase a host-side fix.

`fw_debug_wm`/`fw_debug_wa`/`fw_debug_bin` — CLOSED, dead end, do not
retry (2026-07-12 code trace, no hardware test needed): every one of
these debugfs setters (`mt7915_fw_debug_wm_set`, `_wa_set`, `_bin_set` —
the latter unconditionally ends by calling `_wm_set`) funnels through
`mt7915_mcu_fw_log_2_host()`, which sends `MCU_EXT_CMD_FW_LOG_2_HOST` —
the exact same `0x13ed` command that's stuck. Worse,
`mt7915_mcu_init_firmware()` (mcu.c:2413) hardcodes this call with
`ctrl=0` on every automatic retry, ignoring any previously-set
`dev->fw.debug_wm`/`debug_bin` state — so there's no way to pre-arm
verbosity before triggering that survives into the crash-loop's own
reinit attempts either. The request-to-start-logging message is the same
message that never gets a response; the log-to-host channel can't be
turned on to observe why the log-to-host channel is off. No UART exists
on this board (see top of doc), so there is currently no route to WM/WA
firmware-side diagnostics for this specific failure at all.

Operational note: `sys_recovery` value **7** (`SER_SET_RECOVER_FULL`) is
required for deterministic repro — it's the only value that calls
`mt7915_reset()` directly. Value 1 (L1) only sends MCU commands via
`mt7915_mcu_set_ser()` and, on a healthy chip, succeeds silently with no
escalation — confirmed by testing both back to back on a fresh boot.

## Code trace of the failure (2026-07-10)

Source: mt76 package at
`build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_mt7622/mt76-2026.03.19~39c960c3/`
(permanent fixes go via `package/kernel/mt76/patches/`). The ramoops
signature maps onto this chain exactly:

1. `mt7915/mac.c` `mt7915_mac_full_reset()` retries
   `mt7915_mac_restart()` **up to 10×** — that is the repeated
   firmware-banner loop (~13 s/iteration: 5 s retry + 5 s timeout +
   reset overhead).
2. Each iteration: `mt7915_mac_restart()` → `mt7915_dma_reset(dev,
   force=true)` (`mt7915/dma.c:609`) which runs `mt7915_wfsys_reset()`
   (WM re-executes ROM code) **then** `mtk_wed_device_dma_reset()` — the
   eth-side phase-3 breadcrumb path — then `mt7915_dma_start(...,
   wed_reset=true)` → `mtk_wed_device_start()`, whose entry is exactly
   the last breadcrumb (`ph=4 id=40`). Code and breadcrumbs agree.
3. Then `mt7915_mcu_init_firmware()` (`mt7915/mcu.c:2389`): download
   succeeds, `mt7915_firmware_state(dev, true)` **passes** (WM reports
   running), and the first real command `mt7915_mcu_fw_log_2_host`
   (`mcu.c:2413` = our `0x13ed`) gets no response. Every iteration.
4. `0x13ed` decode: ext-cmd `0x13` = `MCU_EXT_CMD_FW_LOG_2_HOST` on
   ext-CID `0xed`, WM (no WA bit). Timeout/retry mechanics in
   `mt76/mcu.c:100–125`.

Key structural facts for the response-path theory:

- `mt7915/dma.c:494`: on MT7915 with WED active, `q_rx[MT_RXQ_MCU_WA]`
  is WED-bound (v1 txfree/WA ring shares the WED path).
- The WED restart writes directly into the mt7915's WPDMA registers
  (the `wpdma-tx W` lines in the WED-AT trace) while the WM firmware is
  rebooting; PPE kept feeding WDMA the whole time (live clients).
- So "firmware state OK, first command times out, forever, across 10
  clean wfsys resets" is equally consistent with *responses lost on the
  host DMA path* as with a wedged MCU — the host-side ring/DMA state is
  rebuilt the same (possibly wrong) way each iteration.

## SER patch re-audit (2026-07-10) — potential fixes

The SDK 999-series (evaluated in `docs/PHASE3-patch-verdicts.md`, files
removed from the tree since) is recoverable from git:
`git show f994c928e7:target/linux/mediatek/patches-6.12/<name>` for the
eth ones, `git show eef2a51256:...` for the wed ones. Re-read against
the new failure signature:

| Patch | Verdict |
|---|---|
| `999-wed-03-fix-wdma-rx-hang-on-wed1-after-SER` | **Backport candidate #1.** Hunk 1 flips `if (dev->rx_wdma[i].desc) continue;` → `if (!...)` in `mtk_wdma_rx_reset()`. Verified: pristine upstream 6.12.87 **and current mainline master** still have the inverted form — the CPU_IDX zeroing is applied only to *inactive* WDMA RX rings, so every active ring resumes SER with a stale index. Generic (v1-relevant) code, runs inside our phase-3 breadcrumb window (id 32). One-line fix, never upstreamed. Hunk 2 (RX_PREF SIDX/FIFO clears) is v3-only hardware — drop it. |
| `999-wed-13-add-WDMA-disable-flow-to-WiFi-L1-SER` | **Backport candidate #2.** Sets FE link-down on the PSE WDMA port at the top of `mtk_wed_reset_dma()`, re-enables in `mtk_wed_start()` — stops packets entering WDMA mid-SER ("incomplete packets stuck in PSE → buffer management chaotic state"). We ran SER with live traffic; this is that exact hole. Needs small v1 adaptation: `PSE_WDMA_PORT(id)` doesn't exist in 6.12 — use `PSE_WDMA0_PORT + id` (= port 8); `MTK_FE_GLO_CFG`/`MTK_FE_LINK_DOWN_P` exist (`mtk_eth_soc.h:85–86`) but the BIT((8+8)%16)=BIT(0) mapping on MT7622's FE_GLO_CFG needs a datasheet/live-register sanity check before trusting. |
| `999-wed-16-refactor-wdma-init-flow-avoid-double-init` | Medium. Re-init robustness for WDMA/TX/RX rings on the reset path (alloc keyed on `!desc` instead of `!reset`, CPU_IDX rewrite on reset). Generic code, v1-applicable. Take only if 03+13 don't resolve the MCU-death loop. |
| `999-wed-14-refactor-mtk_wed_irq_get` | Skip — changes the v3-only ext-mask branch; v1 branch untouched. |
| `999-eth-04/05/11/32` (forced-reset control / hw dump / reset monitor / SER fast mode) | Keep shelved. They are the FE-side SER framework; our failure left the eth side healthy (LEDs, routing, SSH all fine). eth-32 only shortens the eth↔wifi outage during a *successful* SER — QoL, not a fix. |

Suggested sequence (each step is one flash + one SER test):

1. Instrument first: log `wed_v1_txbm_quiesce` + `wed_debug_breadcrumb`
   values at SER trigger time (close the evidence gap from run 1).
2. **2×2 discriminator, no code changes**: SER with WED detached
   (`wed_enable=N` via modules.d, one reboot) × quiesce=0/1. If SER
   recovers without WED and wedges with it, the WED/WDMA reset-state
   theory is confirmed and the wed-03/13 backports are justified.
3. Backport wed-03 hunk 1 (one line), retest SER-with-WED.
4. Add adapted wed-13 if step 3 alone doesn't clear the MCU timeout.

### Backports prepared (2026-07-10)

Both candidates are in the tree, dry-run- and compile-validated
(mtk_wed.o + mtk_eth_soc.o, GCC 14.3.0 target toolchain), applied to
build_dir, **not yet flashed or hardware-validated**:

- `999-zzzzz-wed-ser-01-fix-wdma-rx-cpu-idx-reset-inversion.patch` —
  wed-03 hunk 1 only (v3 prefetch hunk dropped).
- `999-zzzzz-wed-ser-02-block-pse-wdma-during-wed-reset.patch` — wed-13
  adapted to v1: helper `mtk_pse_wdma_enable(eth, enable)` hardcodes PSE
  port 3 / FE_GLO_CFG BIT(11) (the v1 WDMA port per
  `mtk_flow_set_output_device()`; same register+bit family
  `mtk_prepare_for_reset()` already uses), call sites gated
  `mtk_wed_is_v1()`. Disable at `mtk_wed_reset_dma()` entry, re-enable
  in `mtk_wed_start()` before `dev->running = true` — pairing balanced
  because reset_dma is only reachable as the `.reset_dma` op.

Naming sorts them after the harness patches (zzzz) and before the
cacheline series (zzzzzz); neither later patch touches these regions.

**NAND clock status:** the unvalidated 100 MHz SNFI DTS experiment and the
follow-up 60 MHz parent-clock experiment have both been reverted. Current
images retain the validated default 50 MHz pad clock. Changing the SNFI parent
is unsafe to test until a recovery-boot and flash-integrity validation plan is
available; do not reintroduce either experiment meanwhile.

## Minimal protocol

1. Prove capture first:
   - pstore mounted
   - dmesg readable over SSH (netconsole is broken; do not rely on it)
2. For SER testing:
   - set `wed_debug_breadcrumb=1`
   - set `wed_v1_txbm_quiesce=0` or `1`
   - trigger deterministic SER with `sys_recovery`
   - compare the last replayed checkpoint after reboot
3. For attach-time fault localization (bisect):
   - `echo 1 > /sys/module/mtk_eth/parameters/wed_debug_breadcrumb`
   - `echo N > /sys/module/mtk_eth/parameters/wed_attach_max_access`
   - `echo Y > /sys/module/mt7915e/parameters/wed_enable`, then PCI
     unbind/rebind of `0000:01:00.0`
   - surviving run: `dmesg | grep WED-AT` gives the executed/skipped list
   - locking run: the last executed seq (= N) names the faulting access
   - always reset `wed_attach_max_access=-1` and `wed_enable=N` afterwards

## Deliverables

- `999-zzz-wed-breadcrumb-harness.patch`: runtime-gated breadcrumb + quiesce DUT
- `999-zzz-mt7622-ramoops-console-capture.patch`: console/pmsg/ftrace capture
- `999-zzzz-wed-attach-netconsole-trace.patch`: attach-path MMIO trace +
  `wed_attach_max_access` skip gate (bind-fault bisect)
