# Claude Handoff — E8450 / MT7622

**START HERE:** `docs/E8450-hardware-software-reference.md` — condensed
hardware map, software-path status, operating rules, closed investigations,
ranked next directions. Then `docs/HANDOFF-codex.md` (historical record).
Also run `bd prime` and check `bd remember` memories.

## Critical operating rules (violating these hard-locks or strands the box)

1. NEVER runtime-load mt7915e; NEVER PCI unbind/rebind it (AXI fabric lock,
   watchdog + reboot -f defeated; all kernels). WED goes on ONLY via
   modules.d at boot.
2. kmodloader ignores modprobe argv params — modules.d file only.
3. After a panic: save then `rm /sys/fs/pstore/dmesg-*` or u-boot's
   `pstore check` boots the recovery volume forever (tmpfs root, no wifi).
4. Fast power-replug (1–2 s) preserves ramoops. `setsid` survives dropbear;
   `nohup &` doesn't. Netconsole is broken (netpoll drops silently).
5. Verify router life from a second, independent path — the build
   laptop's r8169 NIC is flaky and caused historical misdiagnoses.
   Which IP reaches the router and whether it's currently online drifts
   (it has flipped more than once) — check MEMORY.md's e8450-router-access
   note for the live state rather than trusting a stale snapshot here.

This is the single source of truth for these hard-locks — the reference
doc's "Operating rules" section points back here; don't fork a second copy.

## Build notes

See `docs/BUILDING.md` (canonical seed `configs/e8450-ubi.config`, run the
interactive `./build-e8450v2.sh`).

## Status

PROJECT GOALS MET: full offload stack (PPE hw-NAT, PPPQ QoS, WED v1,
bridged-flow offload, fwmark→queue steering) live and hardware-verified.
Current status, pending validation, and ranked next directions: see
reference doc §Software paths — status / §Next-direction candidates. The
actionable investigation order and safety gates are in
`docs/OPTIMIZATION-ROADMAP.md`.

## Cache line audit task — CLOSED 2026-07-10

Not cache-limited; don't reopen struct-reorg work unless a workload binds
on l1d refills/CPU. Full record: `docs/cacheline-audit.md`.

## Hash replacement investigation — CLOSED

UMASH port removed (correctness + benchmark issues). Any future hash
replacement or PMULL experiment must clear the gate in
`docs/umash-port-task.md` before reopening.
