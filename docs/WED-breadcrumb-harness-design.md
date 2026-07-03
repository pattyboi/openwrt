# WED v1 Breadcrumb-Capture Harness — Design

**Target:** Linksys E8450 / MT7622 (WED v1) + MT7915E. No UART. Single UBI rootfs
(no fallback slot). Recovery = power-cycle only. mtk-wdt = 31 s.

**Purpose:** make the WED v1 SER hang *observable* and the proposed v1 TX-BM
PAUSE quiesce *testable*, using only data that survives a bus hang + reset.

---

## 0. Success criteria

1. **Localize:** after a hang + auto-reboot, read back the *exact last MMIO the
   CPU reached* before the freeze (register + phase + loop index).
2. **A/B the quiesce:** with the quiesce toggled on vs off, compare where the
   breadcrumb trail ends / whether SER completes — on **one** build, via runtime
   toggles, no reflash between arms.

---

## 1. Safety model (why this can't brick the box)

- **No instrumented WED code runs at boot.** `wed_enable=N` by default; WED
  attach + SER are triggered *manually over SSH* after userspace is up (this is
  already how the wed-toggle helper works — attach fires from the mt7915e probe
  path post-SSH, not early init).
- **Hang path → clean recovery:** hang → mtk-wdt resets SoC at ≤31 s → boots
  with WED off → SSH returns → read pstore + breadcrumb. The box heals itself.
- **Backstop:** if a bus hang also wedges the watchdog (verify in Step A), a
  **networked smart-plug / PDU** power-cycles the unit. This is the only hard
  recovery given no UART; have it wired before starting.
- All instrumentation is **boot-safe**: ioremap/memremap failure → NULL handle →
  every breadcrumb mark becomes a no-op. A bad debug build still boots.

---

## 2. Capture substrate (mostly already built)

- `999-zzz-mt7622-ramoops-console-capture.patch` (exists): adds `console-size`,
  `pmsg-size`, `ftrace-size` to `ramoops@42ff0000` within the existing 64 KiB.
  `PSTORE_CONSOLE=y` / `PSTORE_RAM=y` already set.
- **Already verified live on 2026-07-03:** `pstore` is mounted, `/dev/pmsg0`
  exists, `ramoops@42ff0000` is present, and `wed-breadcrumb@42fef000` is a
  live `no-map` reserved-memory node on the flashed image. Raw probe output is
  saved under `.recall/router-probes/2026-07-03-breadcrumb-audit/`.
- **Step 0 verification (do first, before any WED work):**
  - `mount | grep pstore` → pstore mounted.
  - Provoke a benign capture: `echo 1 > /proc/sys/kernel/panic_on_warn`? No —
    keep it non-fatal: `echo test > /dev/pmsg0`, reboot, confirm
    `/sys/fs/pstore/pmsg-ramoops-0` == "test". This proves the reserved region
    survives a reset **and** that our chosen write path lands in DRAM.
  - Then a WARN test: trigger any `WARN_ON` path, reboot, confirm it appears in
    `/sys/fs/pstore/console-ramoops-0`. Proves the console zone captures.

If Step 0 fails, fix the substrate before instrumenting — everything below
depends on "a write issued just before the freeze is in DRAM after the reset."

---

## 3. Breadcrumb primitive (belt + suspenders)

Two independent trails so a mapping/printk surprise can't blind us:

### 3a. Raw "last checkpoint" word (deterministic, primary)

A tiny fixed struct in a dedicated `no-map` reserved region
`wed-breadcrumb@42fef000`, 4 KiB — carved from RAM, *not* from the ramoops 64 KiB
so the two are independent). Mapped **non-cached** (or `memremap` WB + explicit
cacheline clean) so the store reaches DRAM before the next, possibly-hanging,
access.

```c
struct wed_bc { u32 magic, seq, phase, id, arg, ts, rsv[2]; };
static void __iomem *wed_bc;              /* NULL if map failed → marks no-op */

static inline void wed_bc_mark(u32 phase, u32 id, u32 arg)
{
    if (!wed_bc) return;
    writel(0x57454442, wed_bc + 0);       /* "WEDB" */
    writel(phase, wed_bc + 8);
    writel(id,    wed_bc + 12);
    writel(arg,   wed_bc + 16);
    writel(readl(wed_bc + 4) + 1, wed_bc + 4);
    mb();                                 /* complete this MMIO write before the next access */
}
```

Key property: `wed_bc_mark(...)` is placed **immediately before** each candidate
MMIO. If that MMIO hangs the CPU, the mark is already in DRAM. On reboot the word
tells us precisely which access froze.

> Mapping caveat: warm reset may invalidate caches. Non-cached mapping is safest;
> if unavailable, follow each mark with a cacheline clean-to-PoC. Step 0's
> `/dev/pmsg0` test is what confirms the chosen mapping actually survives.

### 3b. pstore console trail (human-readable, secondary)

`pr_emerg("WEDBC ph=%u id=%u arg=%#x\n", ...)` at **phase boundaries only** (not
per-MMIO — printk in the reset path may defer). Gives narrative context; the raw
word gives the precise last step. Cross-check the two.

### 3c. Read-back

- **Implemented:** on the first `mtk_wed_add_hw` after boot, `wed_bc_setup()`
  ioremaps the region and, if magic is valid, emits `pr_emerg("WED-BC last boot:
  ph=%u id=%u arg=%#x seq=%u\n", ...)` → shows in `dmesg` **and** is re-captured
  into `console-ramoops-0`. That is the read-back for the A/B. The region is
  then cleared so later clean boots do not replay stale crashes.
- Raw region can be read ad hoc if `devmem` is available, but the current
  flashed image does **not** ship it; rely on `dmesg` / `console-ramoops-0`
  unless you add a separate reader.

---

## 4. Instrumentation map (checkpoint IDs)

Phases: `1=STOP  2=WAIT(MCU)  3=RESET_DMA  4=START  5=FE_RESET(eth)`.

**Phase 1 — `mtk_wed_stop`/`mtk_wed_dma_disable`** (runs first on SER):
`10` enter · `11` before each dma-disable write (`arg=0..3` selects the call
site) · `12` the **quiesce write** (TX_BM PAUSE) so we know it executed.

**Phase 3 — `mtk_wed_reset_dma`** (prime suspect):
`30` enter · `31` after TX-DMA-disable poll (`arg=busy`) · `32` after
`mtk_wdma_rx_reset` (`arg=busy`) · `33` **TKFIFO drain loop — mark each iter
with `arg=i` immediately before the risky read** (if it hangs reading
`MTK_WED_TX_BM_INTF`, last id=33 pinpoints it) · `34` after
`RESET_TX_FREE_AGENT` · `35` after clear `WED_TX_BM_EN` + `RESET_TX_BM`
(`arg=0`) · `36` after the WPDMA-tx busy poll (`arg=busy`) · `37` exit.

**Phase 5 — eth side** (`mtk_wed_fe_reset` / `mtk_pending_work` →
`mtk_hw_init` → `ethsys_reset`): `50` fe_reset enter · `51` before wlan.reset
· `52` after wlan.reset returns · `53` before `mtk_hw_init` (ethsys/WDMA goes
into reset here) · `54` after `mtk_hw_init` · `55` fe_reset_complete. A hang
with last id in `[53,54)` = the "ethsys reset under a live WED / WDMA read
during reset" mechanism; a hang at `33` = the TX-BM token-FIFO drain.

> Phase 2 (the MCU `wait_reset_state`) lives in mt7915 firmware/mt76 and can't be
> MMIO-instrumented the same way; infer it from "trail ends after id=10..12 with
> no phase-3 marks" == stalled waiting for RESET_DONE (the mt76#754 case).

---

## 5. Everything is a runtime toggle (minimize flashes)

Module params on the **one** instrumented build:
- `mtk_eth.wed_debug_breadcrumb=0|1` — arm the harness
  (`/sys/module/mtk_eth/parameters/wed_debug_breadcrumb`).
- `mtk_eth.wed_v1_txbm_quiesce=0|1` — **the DUT** (assert TX_BM PAUSE in stop).
- SER-on-demand: **no patch needed** — mainline mt76 already ships the
  `sys_recovery` debugfs knob. Discover the live path with
  ``find /sys/kernel/debug/ieee80211 -path '*/mt76/sys_recovery'``; on the
  current E8450 image it is `/sys/kernel/debug/ieee80211/wl1/mt76/sys_recovery`.
  `echo 1 > .../sys_recovery` fires the **L1 SER** path (the exact one
  `mt7915_mmio_wed_reset` drives); `echo 8` forces a firmware crash → full-reset
  path. Makes SER deterministic instead of load-dependent.

One flash covers the whole matrix; each arm is `echo` + trigger + (power-cycle) +
read-back.

---

## 6. Experimental protocol

Preconditions: Step 0 passed; smart-plug wired; `wed_enable=N` default.

1. **Baseline hang localize** (`v1_txbm_quiesce=0`):
   - SSH: load mt7915e, `debug_breadcrumb=1`, trigger WED attach (wed-toggle).
   - Discover the live SER path:
     ``SER=$(find /sys/kernel/debug/ieee80211 -path '*/mt76/sys_recovery' | head -1)``
   - Fire SER: `echo 1 > "$SER"`. Observe: hang? auto-reboot? (records watchdog
     behavior.)
   - After reboot: read `breadcrumb` + `console-ramoops-0`. Record last
     `(phase,id,arg)`. Repeat ×3 for stability — SER timing is racy.
2. **Quiesce arm** (`v1_txbm_quiesce=1`): identical trigger. Compare last
   `(phase,id,arg)`.
   - **Success signals:** trail advances past the baseline hang point; SER
     reaches phase-4/START; NORMAL_STATE observed; box no longer hangs (auto or
     at all) across N runs.
   - **Null result:** trail ends at the same id → quiesce doesn't address this
     hang (likely MCU-internal, phase-2) → drop the quiesce, it's insufficient.
3. **Sanity/false-positive guard:** run baseline arm again after the quiesce arm
   to confirm the hang still reproduces (rules out "it stopped hanging for
   unrelated reasons").

---

## 7. Deliverables

1. `999-zzz-mt7622-ramoops-console-capture.patch` — **exists**.
2. `999-zzz-wed-breadcrumb-harness.patch` — **done**: no-map breadcrumb region
   + `wed_bc_mark` + instrumentation call sites (phases 1/3/4/5) +
   `wed_debug_breadcrumb` param + boot read-back to dmesg. All no-op unless
   armed. Params exposed at `/sys/module/mtk_eth/parameters/` (KBUILD_MODNAME
   is `mtk_eth`; boot cmdline form `mtk_eth.wed_debug_breadcrumb=1`).
3. SER trigger — **no patch**; use the existing mt76 `sys_recovery` debugfs knob.
4. Quiesce DUT folded into patch #2 as the `wed_v1_txbm_quiesce` param (runtime A/B).

All debug patches numbered `999-zzz-*` so they sort last and are trivially
droppable for a production build.

---

## 8. Honest scope note

This harness answers **"where does it freeze"** and **"does the TX-BM PAUSE
quiesce move/eliminate that freeze."** It does **not** make WED v1 worth
shipping — even a green A/B result only improves SER *recovery*; the documented
speed regressions and MTK's v1 abandonment stand. Treat this as root-cause
closure + a testable hypothesis, not a road to enabling WED in production.
