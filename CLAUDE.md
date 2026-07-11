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
   As of 2026-07-10 the build host sits on the router's LAN: reach it
   at 192.168.1.1 (br-lan). The old WAN check address (192.168.3.15)
   is no longer reachable from the build host (WAN is now DHCP
   upstream).

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

See `docs/cacheline-audit.md` for the full record (layout survey,
patches, cycle-1/2 measurements). Patches 999-zzzzzz-cacheline-01/-02
and 999-zzzzzz-perf-01 (-O2 datapath) are live in `patches-6.12/` and
stay. Verdict: GbE line rate is not cache-limited on this box; don't
reopen struct-reorg work unless a workload binds on l1d refills/CPU.

## Hash replacement investigation

The experimental UMASH port was removed after correctness and benchmark
review. See `docs/umash-port-task.md` for the closed-investigation verdict,
reasons it must not be restored as-is, and the benchmark gate for any future
hash replacement or PMULL experiment.
