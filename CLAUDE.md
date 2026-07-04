# Claude Handoff — E8450 / MT7622 WED

Read this first, then read:
- `docs/HANDOFF-codex.md`
- `docs/WED-breadcrumb-harness-design.md`
- `.recall/router-probes/2026-07-03-breadcrumb-audit/summary.md`

## Update — 2026-07-04 current state

- The earlier "mtk_eth stop/open is the root cause" theory is no longer current.
- Current verified ground truth is the opposite:
  - `wed_enable=0` PCI unbind/rebind can still lock the box, which is a separate
    WED-independent rebind bug.
  - `wed_enable=1` first-bind also hard-locks on vanilla `25.12.4` /
    `6.12.87`, so the existing local WED patch stack is not the root cause.
- The highest-value remaining source-level suspect is now the MT7915 steady-state
  WED txfree/WA queue start timing, not the original attach MMIO sequence.
- A new mt76 patch now defers the first MT7915 WED start until after
  `mt7915_mcu_init()` succeeds, then waits `400 ms` before arming WED.
- That patch and the updated docs both compile in a full clean build.

### New patch now in tree

- `package/kernel/mt76/patches/1000-mt76-mt7915-defer-first-wed-start-until-fw-init.patch`

What it does:

1. Factors the normal WED start sequence into `mt7915_wed_start()`.
2. In `mt7915_dma_start()`, if WED is active on MT7915 during the first
   hardware init path, it defers `mtk_wed_device_start()` instead of arming WED
   immediately.
3. After `mt7915_mcu_init()` returns successfully, `mt7915_init_hardware()`
   sleeps `400 ms` and then calls `mt7915_wed_start()`.

Why this was chosen:

- On MT7915 with WED enabled, the WA RX queue is repurposed into the shared
  WED txfree queue before firmware bootstrap is fully complete.
- RX NAPI is enabled and interrupts can run before WM/WA firmware init has
  finished.
- The best remaining theory is that early txfree/token-release activity races
  mt7915 firmware/bootstrap and causes the wandering WED crash signatures.

### Build result

- Full clean build completed successfully on `2026-07-04`.
- The build reached and completed:
  - `package/kernel/mac80211/regular/compile`
  - `package/kernel/mt76/compile`
- Final images were produced under `bin/targets/mediatek/mt7622/`.

### Immediate next step

- Flash and test the new deferred-WED-start image on hardware.
- Primary question:
  - does delaying first WED arm until after firmware init avoid the first-bind
    hard lock?
- If not, the next structural move should be to delay even later in the same
  class:
  - delay the WA->txfree conversion itself, or
  - delay the first IRQ/tasklet enable instead of only delaying WED start.

## Current goal

Localize and fix the MT7622 WED bind-time hard lock on the Linksys E8450
without UART, using only SSH-visible state and network capture.

## Ground truth

- Repo: `github.com/pattyboi/openwrt`
- Working branch: `e8450-hw-driven`
- Router: Linksys E8450 (UBI)
- OpenWrt: `25.12.4 r32933-4ccb782af7`
- Kernel: `6.12.87`
- SoC: MT7622
- Wi-Fi: MT7915E on PCI `0000:01:00.0`

## What is already done

- PPE / HNAT, PPPQ QoS, builtin conntrack TCP-ACK path, DSCP-qos stack, and
  the `eth-07` napi fix are already handled on this branch.
- `999-zzz-wed-breadcrumb-harness.patch` is committed, built, and flashed.
- `999-zzz-mt7622-ramoops-console-capture.patch` is in place.
- Docs were condensed to reflect the current hardware facts instead of older
  assumptions.

## Verified live hardware facts

- `pstore` is mounted and `/dev/pmsg0` exists
- Reserved memory is live:
  - `ramoops@42ff0000`
  - `wed-breadcrumb@42fef000` with `no-map`
- Runtime params are exposed at:
  - `/sys/module/mtk_eth/parameters/wed_debug_breadcrumb`
  - `/sys/module/mtk_eth/parameters/wed_v1_txbm_quiesce`
  - `/sys/module/mt7915e/parameters/wed_enable`
- WED platform devices are present:
  - `/sys/bus/platform/devices/1020a000.wed`
  - `/sys/bus/platform/devices/1020b000.wed`
- WED debugfs exists:
  - `/sys/kernel/debug/wed0`
  - `/sys/kernel/debug/wed1`
  - both reported `regidx=0`, `regval=0x76220001`
- MT7915E:
  - PCI ID `14c3:7915`
  - driver `mt7915e`
  - `enable=1`
- Live mt76 SER trigger path is:
  - `/sys/kernel/debug/ieee80211/wl1/mt76/sys_recovery`
- `wl0` does not expose `sys_recovery`
- `devmem` is not installed on the current image

## Current blocker — REFRAMED 2026-07-03

The "WED bind lock" is not a WED bug. Two decisive runs:

1. Skip-gate run (`wed_attach_max_access=0`, ALL traced WED/WDMA/WPDMA/
   mirror/HIFSYS MMIO skipped, attach force-failed): box still locked.
2. Baseline: detached `ip link set eth0 down; sleep 3; up` with NO
   WED/PCI/mt7915 involvement: box locked identically.

The bug is in the mtk_eth stop/open path. WED only triggers it because
`mtk_wed_attach` calls `mtk_eth_set_dma_device` (eth is `dma-coherent`),
which close/reopens eth0 — twice, counting the detach restore.

It is NOT an oops: `PANIC_ON_OOPS=y` + `kernel.panic=3` would have
auto-rebooted. It is a permanent deadlock (watchdog keeps getting fed) or a
bus lock. The current kernel cannot show stacks (no MAGIC_SYSRQ, no
DETECT_HUNG_TASK, no CONFIG_STACKTRACE) — a debug+size-optimized rebuild is
in progress (`builddebug3.log`, detached; look for `BUILD-EXIT=0`).

## What probing learned about the bind path

The failure begins before direct MT7915 BAR traffic. The observed access order is:

1. WED0: clear WPDMA TX/RX driver bits
2. WED0: clear WDMA RX driver bit
3. WED0: clear WED TX/RX DMA bits
4. WDMA0: first DMA-state read-modify-write
5. PCIe mirror update
6. WED reset/init and WPDMA base programming
7. HIFSYS coherent-agent update

~~Current prime suspect: the first WED0 read-modify-write at offset `0x508`~~

**DISPROVEN 2026-07-03 (bisect run):** with the skip gate armed
(`wed_attach_max_access=0`, ALL traced WED/WDMA/WPDMA/mirror/HIFSYS MMIO
skipped, attach force-failed), the rebind still hard-locked the box. The
fault is NOT in the traced attach MMIO. What still executed:
`mtk_eth_set_dma_device` (eth node is `dma-coherent` → full
`dev_close_many`+`dev_open` of eth0 under RTNL) on attach AND again on the
forced-fail detach, plus DMA-only buffer allocs. New prime suspect: the
mtk_eth netdev close/reopen cycle. A hang under RTNL also explains why the
watchdog never fires and why stock mainline faults too.

## Netconsole verdict (2026-07-03, verified live)

Netconsole is BROKEN on this image — do not retry it. Modprobe succeeds
(br-lan / lan1 / eth0 targets, correct host MAC, loglevel 8, KERN_EMERG
markers), the console layer works (all markers reach the ramoops console and
dmesg), but zero frames ever hit the wire and lan1's DSA software TX stats
never increment — netpoll drops every frame before ndo_start_xmit, silently.
Source + config audit found no cause (NETPOLL=y, NET_POLL_CONTROLLER=y, DSA
hooks present). Tracked as a beads bug.

## Replacement: attach-access bisect

`999-zzzz-wed-attach-netconsole-trace.patch` (committed, no longer
untracked) now also gates traced MMIO. With `wed_debug_breadcrumb=1` and
`/sys/module/mtk_eth/parameters/wed_attach_max_access=N`:

- traced accesses with seq > N are skipped (reads return 0)
- attach is forced to fail cleanly, mt76 falls back to non-WED
- `N=0`: full attach access list lands in dmesg, SoC survives, read via SSH
- stepping N upward executes the real access prefix; the first N that
  hard-locks names the faulting access (one cold power-cycle total)

## Immediate next steps

Router is UP on the debug + size-optimized image (flashed and verified
2026-07-03 evening: sysrq=1, hung_task_timeout_secs=120, bisect params
present, image 11.9M). Both the skip-gate run and the eth0-only baseline
are already done — do not repeat them bare; the next run must be the
deadman version below.

1. Deploy `docs/e8450-eth0-deadman.sh` → `/tmp/t2.sh`; run
   `setsid /tmp/t2.sh </dev/null >/dev/null 2>&1 &`; wait ~4 min.
   (`nohup &` over ssh dies with dropbear — must be setsid.)
   - Box self-recovers (deadman `reboot -f`, warm reset preserves ramoops):
     read `/sys/fs/pstore/console-ramoops-0` — khungtaskd stack dumps of the
     stuck task are the root cause.
   - Box stays dead: bus-level lock, not a kernel deadlock — also decisive
     (user must power-cycle).
2. Then A/B: disable offloads (nft flowtable / PPE) and retry eth0 cycle;
   consider testing stock OpenWrt the same way.
3. Netconsole is broken on this stack (netpoll drops pre-ndo, beads bug
   filed) — never plan around it.
4. Resume the SER / `wed_v1_txbm_quiesce` A/B only after this is fixed.
5. Build note: kernel debug/size flags are OpenWrt buildroot symbols in the
   untracked `.config` (`KERNEL_MAGIC_SYSRQ`, `KERNEL_DETECT_HUNG_TASK`,
   `KERNEL_CC_OPTIMIZE_FOR_SIZE`); target config-6.12 cannot override them.

## Constraints

- No UART
- Do not enable WED at boot
- Do not assume the watchdog will recover the bind fault
- Do not hardcode `wl0` or `phy0`
- Prefer verified runtime state over older notes
- Patches under `target/linux/mediatek/patches-6.12/` are diffs against vanilla
- Use `./scripts/config ...` plus `make olddefconfig` for config changes
