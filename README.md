# Linksys E8450 / Belkin RT3200 — Hardware-Validated Performance Fork

**MediaTek MT7622 · NETSYSv1 · WED-v1 · OpenWrt 25.12 / Linux 6.12**

A from-source, hardware-validated OpenWrt fork for the Linksys E8450
(also sold as Belkin RT3200). Every fix, every "this doesn't work on
this chip," and every performance number in this repo was reached by
**reading the actual driver source in this tree and confirming the
result on a live, in-production router** — not copied from a vendor
changelog, a forum post, or assumed by analogy with a different chip
generation. Where something turned out to be a hardware dead end
(no second QDMA scheduler, no hardware airtime fairness, no usable PSE
queue-depth registers), that's recorded as a decisive negative result
with the register readback to prove it, not silently dropped.

This is not a fork that adds features by importing vendor SDK patches
wholesale. Most of what's here **doesn't exist upstream at all** for
this chip — MediaTek's NETSYSv1 generation has no vendor QoS/AQM
reference implementation, so the shaping stack below was designed and
built from the raw register map up.

## Hardware supported

| | |
|---|---|
| Device | Linksys E8450, Belkin RT3200 (UBI flash layout) |
| SoC | MediaTek MT7622 — **dual-core** Cortex-A53 (not quad — corrected during this fork's own CPU-overhead investigation) |
| Packet engine | NETSYSv1 (QDMA + PPE/HNAT hardware flow offload, 16 TX queues) |
| 5 GHz radio | MT7915, PCIe, WED-v1 DMA-offload attached |
| 2.4 GHz radio | MT7615/WMAC, SoC-integrated, own WPDMA ring — **no WED path**, always PPE + software forwarding |
| Switch | MT7531 DSA, 4× LAN + 1× WAN |

## Current milestone — as of 2026-09-04

| | |
|---|---|
| Kernel | Linux 6.12.94, revision `r33075-4dfd876771`, live-flashed and hardware-verified |
| Local patch count | 36 (`target/linux/mediatek/patches-6.12/999-*.patch`) + 2 mt76-specific + 3 custom packages |
| Radio config | 5 GHz ch157 (UNII-3, non-DFS) / 2.4 GHz ch6, both radios at **30 dBm — the US legal ceiling**, factory-eeprom calibration raised and documented (reversible) |
| QoS/AQM | Production HQoS+AQM profile live: hardware leaky-bucket WAN shaping (`q7`/`q8`) + software occupancy-driven eviction, byte-accurate, flow-aware, `grace_ms=1000` |
| Bufferbloat control | `sqm-autorate-rust` (adaptive CAKE rate controller) deployed with a local upstream-overshoot bug found and patched same-day |
| Open work | One precisely-scoped, non-urgent question remains: does a real Wi-Fi client's PPE-hardware-offloaded download bypass CAKE shaping the same way it's proven to bypass the WAN-egress queue shaper. Everything needed to answer it (harness, telemetry points) exists; the test itself is deliberately deferred. See [`docs/e8450-download-shaping-handoff.md`](docs/e8450-download-shaping-handoff.md). |
| Hardware capability audits | **Closed.** QDMA (every register with a plausible shaping role), WED (entire 815-line register file), and PSE (per-port buffer thresholds) have all been exhaustively read from source and confirmed either already-in-use or definitively inert on this silicon — with live register readback proof, not just source inference. |

## What's different from stock OpenWrt

- **A working hardware+software AQM for a chip nothing upstream shapes.** NETSYSv1 has no vendor or upstream bufferbloat control. Built one from the ground up: a persistent per-queue leaky-bucket cap on the WAN-egress hardware queue, plus a software watchdog that evicts flows from hardware offload back to CAKE when the queue's byte rate crosses threshold — with flow-aware eviction (targets the actual congesting flow via the PPE's own hardware byte counters, not walk order). Reduced saturating-load p95 latency from 196 ms to 22-34 ms.
- **A real WED-v1 DMA desync bug, found and fixed.** A busy-path reset in the WED reset routine skipped the WED-side ring index reset, permanently desyncing the RX ring after a radio-recovery event under load. Confirmed stuck before the fix, confirmed clean afterward, on the same hardware.
- **A NETSYSv1 PSE port-mapping bug in a vendor patch, found and fixed.** The vendor's own WDMA-during-recovery gating patch used the newer-chip-generation port formula unmodified; on this chip it silently wrote to the wrong register and gated nothing. Corrected.
- **A radio-crash outage bounded, not just logged.** MT7915's firmware occasionally never acknowledges a specific recovery command — confirmed unfixable from host driver source (independently, twice). A watchdog detects the driver's own terminal failure message and self-reboots, turning a previously indefinite outage into a bounded ~65 s one.
- **2.4 GHz CPU overhead measurably reduced.** Found all three device IRQs with real per-packet cost statically stacked on one CPU core (this chip has two); rebalanced. Found and fixed an mt76-core inefficiency taking a lock and an MMIO read for up to 5 TX queues every status event regardless of whether they had anything queued.
- **An upstream adaptive-rate-control bug, found and patched same-day.** The vendored `sqm-autorate-rust` never enforced its own documented rate ceiling — verified against its actual pinned source, not assumed — letting the shaped rate silently drift to 6-7× real sustained capacity. One-line fix, cross-compiled, deployed, verified holding exactly at the ceiling under genuine saturating load.
- **Radio transmit power raised to the legal ceiling**, via direct factory-eeprom calibration (not just `iw`/regdomain config) — full register map, per-device calibration regions flagged do-not-touch, one-command apply/revert tool, and RSSI-measured real-world gain (+4 dB far-field on 5 GHz).
- **Every "could this chip do more" question answered with evidence, including the negative ones.** A second QDMA scheduler, hardware airtime fairness, `HRED2`/`fc_th` depth thresholds, and PSE per-port buffer thresholds are all wired in the register map (inherited from a shared template with newer chip generations) but confirmed — by register readback, not documentation — to have no enforcement circuit behind them on this chip. That's a real answer, not a gap in the investigation.

## Patch inventory

All local patches carry a commit message explaining *why* they exist;
several document an `Upstream commit:` line where a hand-backport has
since landed in mainline (checked and pruned when it does — ten local
patches were deleted this way after an mt76 pin bump). Full writeups
are linked per group below; this table is the map.

### WED-v1 (WiFi DMA offload)

| Patch | Fixes |
|---|---|
| `999-wed-13-mtk_wed-disable-wdma-during-ser.patch` | Corrects a vendor patch's port-mapping formula for this chip generation (was silently gating the wrong register) |
| `999-wed-14-mtk_wed-reset-wdma-rx-idx-on-busy-reset.patch` | Fixes the WDMA RX ring permanently desyncing after a busy-path reset under load |

### QoS / AQM (built from scratch — no upstream equivalent for this chip)

| Patch | Purpose |
|---|---|
| `999-qos-01` | Read-only QDMA scheduler/queue register debugfs (diagnostic foundation) |
| `999-qos-02` | Disposable QDMA rate-write interface (step-2 experiment tooling) |
| `999-qos-03` | Persistent NETSYSv1 WAN queue-rate override, survives link events/reboot |
| `999-qos-04` | NETSYSv1 HQoS debugfs (scheduler/queue live control) |
| `999-qos-05`, `999-qos-11` | QDMA MIB packet/byte counter readout |
| `999-qos-06` | Occupancy-driven flow-table eviction — the core software AQM: evicts congesting flows from hardware offload back to CAKE |
| `999-qos-07` | skb-mark → software TX queue steering |
| `999-qos-08` | AQM state re-prime after a radio-recovery event |
| `999-qos-09` | `HRED2` gap-probe (register-capability test — result: inert) |
| `999-qos-10` | Priority DSCP → queue-ID mapping in the PPE |
| `999-qos-12` | Byte-accurate AQM trigger threshold (was a fixed 1400-byte packet-count assumption) |
| `999-qos-13` | Flow-aware eviction — targets the actual congesting flow via the PPE's own hardware byte counters, not arbitrary walk order |
| `999-qos-14`, `999-qos-15`, `999-qos-16` | AQM eviction-path code-quality pass: dedup, drop a doubled lock-guarded walk, fix a latent overflow |
| `999-qos-17` | Read-only PSE per-port buffer-threshold debugfs — closes the "is there a usable PSE queue-depth register" question with live readback (answer: no, never initialized on this chip) |

Full writeup, every register offset, every measurement:
[`docs/netsys-qos-port-investigation.md`](docs/netsys-qos-port-investigation.md).

### PPE / hardware flow offload

| Patch | Purpose |
|---|---|
| `999-ppe-04` | Switch to internal QoS mode |
| `999-ppe-10` | Fix a typo disabling the MIB cache |
| `999-ppe-11` | Dispatch short packets (e.g. ACKs) to a high-priority path |
| `999-ppe-12` (×2) | TCP/UDP flow aging-out tuning; DSCP-learning core for conntrack |
| `999-ppe-14` | PPE cache preserved-line lock (hot flow-table entries stay cache-resident) |
| `999-ppe-17` | DSCP-learning flow-offload propagation |
| `999-ppe-36` | Enable PPPQ QoS mode by default on NETSYSv1 |
| `999-ppe-89`, `999-ppe-90`, `999-ppe-91` | Flow-offload core plumbing, bridging support, a memory-leak fix |
| `999-ppe-92` | Seeded xxh32 tuple hashing for the flow table |
| `999-zz-mtk_ppe-prefetch-flow-lookup` | Prefetch on the flow-table hot lookup path |

### Hashing

| Patch | Purpose |
|---|---|
| `999-ppe-92`, `999-xxhash-01-nft-set-large-keys` | Seeded xxh32 for PPE tuple hashing and large nft set keys — measured against real A53 hardware and this router's actual call-site sizes; `rapidhash` benchmarked and rejected (xxh32 wins at every tested length). See [`docs/selective-xxhash-plan.md`](docs/selective-xxhash-plan.md). |

### mt76 (WiFi driver)

| Patch | Purpose |
|---|---|
| `package/kernel/mt76/patches/901` | Header compatibility fixups for the pinned upstream snapshot |
| `package/kernel/mt76/patches/902` | Skip TX-status cleanup work (lock + MMIO read) for empty queues — confirmed live: all 5 WMAC hardware queues were reading empty even under 8 active 2.4 GHz clients |

### Misc kernel/Ethernet

| Patch | Purpose |
|---|---|
| `999-eth-07` | Fix a panic on `napi_enable` |
| `999-eth-91` | RX DMA ring size 1024 |
| `999-hwrng-mtk...` | Device-context correctness + resume-error handling for the hardware RNG |

## Custom packages

| Package | Purpose |
|---|---|
| `qdma-shaper` | Userspace backend for the NETSYSv1 QDMA WAN queue shaper (`999-qos-03`) — UCI config, decoded register readback, boot/link-event re-application |
| `sqm-autorate-rust` | Adaptive CAKE rate controller ([`Lochnair/sqm-autorate-rust`](https://github.com/Lochnair/sqm-autorate-rust), Rust port of `cake-autorate`), hand-built binary sidecar with a local rate-ceiling-clamp fix on top of the pinned upstream commit |
| `mt7915-ser-watchdog` | procd service: detects the MT7915 firmware's terminal recovery-failure message and self-reboots, bounding an otherwise-indefinite radio outage to ~65 s |

## Radio calibration (factory eeprom)

Both radios' factory calibration was raised from the stock ceiling to
the region's legal maximum (30 dBm) via direct eeprom edits — not just
a software `txpower`/regdomain change, which this project verified was
**not** the binding constraint (the eeprom-calibrated ceiling was below
the legal limit on both bands). Fully documented and reversible:

- Complete field-by-field map of both radio eeproms, per-device
  calibration regions flagged do-not-touch, and the validated power
  model (0.5 dBm per byte): [`.recall/router-probes/2026-09-04-factory-dump/EEPROM-MAP.md`](.recall/router-probes/2026-09-04-factory-dump/EEPROM-MAP.md)
- One-command tool to view, check, or apply/revert:
  [`scripts/e8450/eeprom.sh`](scripts/e8450/eeprom.sh) (`apply stock` /
  `apply max30` reproduce the pristine and maxed images byte-for-byte)
- Real-world gain confirmed by RSSI measurement at a fixed point, not
  just register math: +4 dB far-field on 5 GHz.
- 5 GHz and 2.4 GHz channels re-surveyed and moved off the noisiest/most
  contested channels in range (including off the DFS channel that an
  earlier investigation had flagged as a real instability source).

## Known limitations — permanent, not bugs

Filing an issue about any of these will not find anything new; each was
confirmed by reading the driver source and testing against live
hardware, not assumed:

- **Radio-crash (SER) recovery is sometimes incomplete.** The MT7915
  firmware occasionally never acknowledges a specific command during
  full-reset recovery. This is a firmware bug, confirmed unfixable from
  host driver source. The watchdog above bounds the outage; it cannot
  eliminate it.
- **No hardware airtime fairness, no second QDMA scheduler.** Both are
  wired in the register map (inherited from a template shared with
  newer MediaTek chip generations) but have no enforcement circuit
  behind them on this SoC — proven by register readback under a
  configured, differentiated load, not just documentation.
- **No background DFS CAC.** Not a disabled policy flag — this board
  has one 5 GHz radio and no second PHY to host a background detector.
- **2.4 GHz has no WED path.** The SoC-integrated MT7615/WMAC has its
  own independent DMA ring block with no hardware interconnect to
  WED/PPE. It still gets full PPE flow offload and the software AQM;
  it just never gets WED's zero-CPU DMA bypass, and no patch can add
  that without new silicon.
- **PSE per-port buffer-threshold registers are unusable**, not merely
  undocumented — the driver's own init code has no code path for this
  chip generation at all; the registers hold power-on-reset zero and
  nothing depends on them.

## Documentation map

**Start here for the deeper technical index:** [`docs/README.md`](docs/README.md) —
architecture diagram and links to every full investigation writeup
(WED/PPE validation, the complete QoS/AQM investigation, WiFi CPU/
stability findings, the hashing audit, and the upstream-tracking
roadmap).

## Build & flash

Standard OpenWrt buildsystem (see *Development* below) with
`configs/e8450-ubi.config` as the seed defconfig. Router credentials
for the flash helper are read from `$ROUTER_PASS` or a local,
gitignored `.router-credentials` file — never hardcode a real password
in a tracked file. `files/` is the `/etc` overlay baked into the
image; `files/etc/shadow` and the real WiFi key are excluded via
`.gitignore` — set your own before flashing.

Two hard rules, violating either strands the router (details in
`docs/README.md` and each affected doc):
1. Never runtime-load `mt7915e` and never PCI unbind/rebind it —
   boot-time `modules.d` load only. A live reload or rebind locks the
   AXI fabric; only a power cycle recovers it.
2. After any panic, clear `/sys/fs/pstore/dmesg-*` before the next
   reboot, or the bootloader's pstore check will boot the recovery
   volume indefinitely.

## Methodology

Every claim above is reached the same way: read the actual kernel/
driver source in this tree, form a specific hypothesis, and confirm it
against a live, in-production router — register readback where a
register claim is made, hardware-verified throughput/latency numbers
where a performance claim is made. Where the vendor SDK or an upstream
patch was consulted, it's evidence to test, not something imported and
trusted. Negative results are recorded with the same rigor as positive
ones — this repo tells you what this chip *can't* do as precisely as
what it can.

---

*Everything below this point is the stock upstream OpenWrt README.*

---

![OpenWrt logo](include/logo.png)

OpenWrt Project is a Linux operating system targeting embedded devices. Instead
of trying to create a single, static firmware, OpenWrt provides a fully
writable filesystem with package management. This frees you from the
application selection and configuration provided by the vendor and allows you
to customize the device through the use of packages to suit any application.
For developers, OpenWrt is the framework to build an application without having
to build a complete firmware around it; for users this means the ability for
full customization, to use the device in ways never envisioned.

Sunshine!

## Download

Built firmware images are available for many architectures and come with a
package selection to be used as WiFi home router. To quickly find a factory
image usable to migrate from a vendor stock firmware to OpenWrt, try the
*Firmware Selector*.

* [OpenWrt Firmware Selector](https://firmware-selector.openwrt.org/)

If your device is supported, please follow the **Info** link to see install
instructions or consult the support resources listed below.

## 

An advanced user may require additional or specific package. (Toolchain, SDK, ...) For everything else than simple firmware download, try the wiki download page:

* [OpenWrt Wiki Download](https://openwrt.org/downloads)

## Development

To build your own firmware you need a GNU/Linux, BSD or macOS system (case
sensitive filesystem required). Cygwin is unsupported because of the lack of a
case sensitive file system.

### Requirements

You need the following tools to compile OpenWrt, the package names vary between
distributions. A complete list with distribution specific packages is found in
the [Build System Setup](https://openwrt.org/docs/guide-developer/build-system/install-buildsystem)
documentation.

```
binutils bzip2 diff find flex gawk gcc-6+ getopt grep install libc-dev libz-dev
make4.1+ perl python3.7+ rsync subversion unzip which
```

### Quickstart

1. Run `./scripts/feeds update -a` to obtain all the latest package definitions
   defined in feeds.conf / feeds.conf.default

2. Run `./scripts/feeds install -a` to install symlinks for all obtained
   packages into package/feeds/

3. Run `make menuconfig` to select your preferred configuration for the
   toolchain, target system & firmware packages.

4. Run `make` to build your firmware. This will download all sources, build the
   cross-compile toolchain and then cross-compile the GNU/Linux kernel & all chosen
   applications for your target system.

### Related Repositories

The main repository uses multiple sub-repositories to manage packages of
different categories. All packages are installed via the OpenWrt package
manager called `opkg`. If you're looking to develop the web interface or port
packages to OpenWrt, please find the fitting repository below.

* [LuCI Web Interface](https://github.com/openwrt/luci): Modern and modular
  interface to control the device via a web browser.

* [OpenWrt Packages](https://github.com/openwrt/packages): Community repository
  of ported packages.

* [OpenWrt Routing](https://github.com/openwrt/routing): Packages specifically
  focused on (mesh) routing.

* [OpenWrt Video](https://github.com/openwrt/video): Packages specifically
  focused on display servers and clients (Xorg and Wayland).

## Support Information

For a list of supported devices see the [OpenWrt Hardware Database](https://openwrt.org/supported_devices)

### Documentation

* [Quick Start Guide](https://openwrt.org/docs/guide-quick-start/start)
* [User Guide](https://openwrt.org/docs/guide-user/start)
* [Developer Documentation](https://openwrt.org/docs/guide-developer/start)
* [Technical Reference](https://openwrt.org/docs/techref/start)

### Support Community

* [Forum](https://forum.openwrt.org): For usage, projects, discussions and hardware advise.
* [Support Chat](https://webchat.oftc.net/#openwrt): Channel `#openwrt` on **oftc.net**.

### Developer Community

* [Bug Reports](https://bugs.openwrt.org): Report bugs in OpenWrt
* [Dev Mailing List](https://lists.openwrt.org/mailman/listinfo/openwrt-devel): Send patches
* [Dev Chat](https://webchat.oftc.net/#openwrt-devel): Channel `#openwrt-devel` on **oftc.net**.

## License

OpenWrt is licensed under GPL-2.0
