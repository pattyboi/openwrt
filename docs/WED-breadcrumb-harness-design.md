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

1. Baseline A/B leg: repeat with `wed_v1_txbm_quiesce=0` (and log both
   param values into dmesg before triggering `sys_recovery`) to see
   whether the MCU restart-loop is quiesce-dependent or the generic SER
   outcome on this box.
2. If the MCU loop reproduces in both legs, the target shifts to the
   mt76 SER/MCU restart path (message 0x13ed timeout), not WED.

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
