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
5. Verify router life via its WAN (192.168.3.15) — build laptop's r8169 NIC
   is flaky and caused historical misdiagnoses.

This is the single source of truth for these hard-locks — the reference
doc's "Operating rules" section points back here; don't fork a second copy.

## Build notes

See `docs/BUILDING.md` (canonical seed `configs/e8450-ubi.config`, run
`./scripts/build-e8450.sh`).

## Status

PROJECT GOALS MET: full offload stack (PPE hw-NAT, PPPQ QoS, WED v1,
bridged-flow offload, fwmark→queue steering) live and hardware-verified.
Current status, pending validation, and ranked next directions: see
reference doc §Software paths — status / §Next-direction candidates.

## Cache line audit task

See `docs/cacheline-audit.md` — struct layout audit + reorganization
patches (999-zzzzzz-cacheline-01 active; -02 staged in patches-staged/),
flash and perf-verification procedure. Only load it when working on
that task.

## UMASH port task

See `docs/umash-port-task.md` for the experimental UMASH hash-port brief
(objective, port structure, hard constraints, and audit procedure for
finding more call sites). Only load it when actively working on that task.
