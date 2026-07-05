# Claude Handoff — E8450 / MT7622

**START HERE:** `docs/E8450-hardware-software-reference.md` — condensed
hardware map, software-path status, operating rules, closed investigations,
ranked next directions. Then `docs/HANDOFF-codex.md` (historical record).
Also run `bd prime` and check `bd remember` memories.

## Status (2026-07-05): PROJECT GOALS MET

Custom vanilla-based 25.12.4 (kernel 6.12.87) on the Linksys E8450 with the
full offload stack live and hardware-verified:
PPE hw-NAT + PPPQ QoS + TCP-ACK prio (conntrack builtin) + DSCP learning +
**WED v1** (boot-load via `/etc/modules.d/mt7915e`, persisted in
sysupgrade.conf) + bridged-flow offload capability (999-ppe-89/90/91) +
fwmark→queue steering (999-eth-27).

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

## Pending validation

- Packet steering live check: fresh installs now default
  `network.globals.packet_steering=1` on `linksys,e8450-ubi` /
  `belkin,rt3200-ubi` via `files/etc/uci-defaults/99-e8450-packet-steering`,
  but this still needs real hardware confirmation and does not retroactively
  change existing preserved configs.
- Bridged LAN↔WLAN offload E2E (needs two LAN clients) and eth-27
  mark→queue functional check.
  Bridged validation helper now exists:
  `files/usr/sbin/e8450-bridge-offload-bench`
  with procedure in `docs/e8450-bridged-offload-validation.md`.
- WED perf soak (upstream hop currently ~5 Mbps — too slow for numbers).
- SER / `wed_v1_txbm_quiesce` A/B (harness in tree, now unblocked).

## Next-direction shortlist (see reference doc for full ranked list)

1. IRQ/RPS spread — all net IRQs on CPU0 today, CPU1 idle.
2. cpufreq governor A/B (ondemand 437 MHz floor vs performance).
3. Real SSIDs/PSKs (currently open "OpenWrt"). Fresh installs now default
   firewall4 flow offload + hardware flow offload ON via
   `files/etc/uci-defaults/99-e8450-flow-offload`; existing configs keep
   their setting.

## Build notes

- Canonical build seed: `configs/e8450-ubi.config`. Run
  `./scripts/build-e8450.sh`, or `CLEAN=1 ./scripts/build-e8450.sh` for a
  clean build; set `JOBS` to override the default `nproc` parallelism. The
  wrapper defaults to pinned Google Clang 20 (`clang-r547379`) for the kernel
  and kernel modules while retaining GCC for userspace; set `GOOGLE_CLANG=0`
  for the GCC kernel baseline. The toolchain is cached outside the tree.
- Patches: `target/linux/mediatek/patches-6.12/999-*` (diffs vs vanilla;
  quilt applies in filename order — 999-ppe-90/91 are rebased ON ppe-17/21).
- Kernel debug/size flags are buildroot symbols in the UNTRACKED `.config`:
  `KERNEL_MAGIC_SYSRQ`, `KERNEL_DETECT_HUNG_TASK`,
  `KERNEL_CC_OPTIMIZE_FOR_SIZE` (target config-6.12 cannot override these).
- Detached builds: `nohup setsid sh -c 'make ... ' &`, log + `BUILD-EXIT=`.
