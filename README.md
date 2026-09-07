# E8450 Performance ROM

Hardware-validated OpenWrt for the **Linksys E8450 / Belkin RT3200 UBI**
(MediaTek MT7622, NETSYSv1, WED-v1).

This is a focused custom ROM, not another general-purpose OpenWrt distribution.
It keeps OpenWrt's build system and userland, then adds board-specific fixes,
hardware offload, queue management, radio recovery, and measured performance
tuning. Changes are tested on the target router and kept only when they solve a
real problem or survive an A/B test.

> **Scope:** only the UBI-flashed E8450/RT3200. Do not use these images or
> hardware settings on another MT7622 board.

## At a glance

| Component | Current baseline |
|---|---|
| Base | OpenWrt 25.12 |
| Kernel | Linux 6.12.103 |
| CPU / packet engine | Dual-core Cortex-A53 / MediaTek NETSYSv1 |
| 5 GHz | MT7915 over PCIe with WED-v1 DMA offload |
| 2.4 GHz | Integrated MT7615/WMAC; PPE offload, no WED path |
| Traffic management | Hardware HQoS + PPPQ, software AQM, CAKE, adaptive rates |
| Hardware flow offload | Enabled by default |
| Package philosophy | Small fixed image; customize at build time |

## Why use this ROM?

### Fast forwarding without abandoning latency control

Stock choices are usually either:

- send traffic through CAKE for good latency but spend more CPU; or
- enable hardware flow offload for throughput but bypass most software queue
  management.

This fork combines both paths:

1. **PPPQ** assigns hardware-offloaded WAN flows to QDMA queues.
2. **HQoS** gives bulk traffic a capped queue and latency-sensitive traffic a
   higher-priority queue.
3. **AQM** watches the capped hardware queue. When it stays busy, the heaviest
   flows are removed from hardware offload and sent through CAKE.
4. A short hold prevents an evicted flow from immediately jumping back into
   hardware while congestion is still present.

The result keeps PPE offload for ordinary traffic and invokes CAKE where it is
useful. In the initial controlled A/B, saturating-load p95 latency fell from
196 ms to 33.8 ms while upload throughput retained 98.5%. A later hardened-AQM
run measured 30.5 ms p95.

![AQM loaded-latency and upload-throughput comparison](docs/assets/aqm-latency-throughput.svg)

### Adaptive CAKE rates

`sqm-autorate-rust` adjusts CAKE to the connection's measured delay instead of
assuming a fixed ISP rate. This tree also fixes a bug in the pinned upstream
version which allowed the calculated rate to exceed its configured ceiling.

### Hardware and driver fixes

- Fixes a WED-v1 receive-ring desynchronization during Wi-Fi recovery.
- Corrects a vendor PSE port mapping that targeted the wrong NETSYS generation.
- Rebalances the real per-packet IRQ load across both CPU cores.
- Avoids unnecessary mt76 lock and MMIO work for empty transmit queues.
- Carries targeted Ethernet, DSA, PPE, MDIO, RNG, and flowtable correctness
  fixes rather than importing an entire vendor SDK.

### Bounded 5 GHz recovery

The MT7915 firmware can stop replying during full recovery. Host-driver changes
cannot recover that terminal firmware state. `mt7915-ser-watchdog` recognizes
the driver's failure signature and reboots the router, changing an indefinite
outage into a bounded one of about 65 seconds.

### Optional radio work

- Default-off 2.4 GHz VHT20/QAM-256 support for compatible clients.
- A reversible EEPROM inspection/calibration tool.
- Non-DFS production channel selection and measured IRQ/radio tuning.

EEPROM data is partly unit-specific. Never copy calibration bytes from this
router to another unit. Use `scripts/e8450/eeprom.sh check` first; the
[calibration evidence record](docs/research/eeprom-calibration.md) documents
the tested offsets, measurements, and limitations.

## Feature status

| Feature | Default | Status |
|---|---:|---|
| PPE hardware flow offload | On | Production |
| PPPQ queue assignment | On | Production |
| HQoS bulk/priority scheduling | On | Production |
| Queue-triggered AQM v2 | On | Production |
| CAKE + `sqm-autorate-rust` | On | Production |
| MT7915 recovery watchdog | On | Production mitigation |
| 2.4 GHz VHT20/QAM-256 | Off | Opt-in; client compatibility varies |
| EEPROM power calibration | Manual | Per-device operation |
| WED busy-poll reduction | Not applied | Candidate; needs controlled A/B |

Plain-English explanations, packet-flow diagrams, settings, limitations, and
patch maintenance policy are in [`docs/README.md`](docs/README.md).

## Build

Use a case-sensitive Linux filesystem and install the normal
[OpenWrt build prerequisites](https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem).
Then:

```sh
./scripts/feeds update -a
./scripts/feeds install -a
cp configs/e8450-ubi.config .config
make defconfig
make -j"$(nproc)"
```

The sysupgrade image is written to:

```text
bin/targets/mediatek/mt7622/openwrt-mediatek-mt7622-linksys_e8450-ubi-squashfs-sysupgrade.itb
```

`files/` is copied into the image as its filesystem overlay. Review it before
building: it contains deployment-specific network policy and must not contain
someone else's password, Wi-Fi key, addressing, or port forwards. Secrets are
intentionally gitignored.

## Flash

The helper copies the built image to the router and runs `sysupgrade -c`, which
retains changed configuration:

```sh
cp .router-credentials.example .router-credentials
# Edit the local, gitignored credentials file.
./flash.sh
```

Alternatively, export `ROUTER_PASS` before running `./flash.sh`.

Because `-c` restores existing files under `/etc`, a newly changed file in the
source overlay may be replaced by the router's saved older copy on first flash.
Verify important overlay changes on the live router after upgrading.

Before flashing:

- Confirm the board is the **E8450/RT3200 UBI** variant.
- Keep a known-good recovery path and backup.
- Review the build's `files/etc/config/` overlay.
- Treat EEPROM changes separately from firmware flashing; `sysupgrade` does not
  make one unit's calibration safe for another.

## Day-to-day checks

```sh
# Hardware shaper, resolved WAN queue, CAKE, offload, and AQM state
qdma-shaper status wan

# Service state and recent shaping/recovery events
/etc/init.d/sqm-autorate-rust status
logread -e qdma-shaper
logread -e mt7915-ser-watchdog
```

The shipped production profile is in
`package/qdma-shaper/files/qdma-shaper.config`. Its connection-specific rates
must be retuned for a different ISP link; do not assume the included
8.3/10 Mbit values match yours.

## Safety rules

1. **Never runtime-reload `mt7915e` or PCI unbind/rebind the radio.** On this
   board that can lock the AXI fabric; a cold power cycle is then required.
2. **After a panic, clear `/sys/fs/pstore/dmesg-*` before the next reboot.**
   Otherwise the bootloader's pstore check can repeatedly select recovery.
3. **Do not blindly reuse the included runtime configuration.** Firewall rules,
   rates, interface names, and radio calibration reflect one deployment.
4. **Do not treat every MediaTek vendor patch as applicable.** Most target
   NETSYSv2/v3 or newer WED hardware and are deliberately excluded here.

## Known hardware limits

- NETSYSv1 has no usable hardware AQM. The fork's AQM is a software controller
  around the hardware queue and flow table.
- The apparent second QDMA scheduler, hardware airtime-fairness controls,
  `HRED2`, and PSE per-port thresholds are inert on MT7622.
- The integrated 2.4 GHz radio has no WED interconnect; software cannot add one.
- Background DFS CAC needs a second 5 GHz PHY, which this board does not have.
- MT7915's terminal recovery failure is firmware-owned; the watchdog mitigates
  the outage but does not fix the firmware.
- Whether a real Wi-Fi client's hardware-offloaded download always traverses
  CAKE remains the one open packet-path acceptance test. The wired path has
  already been verified.

## Project policy

- Source and live measurements outrank vendor claims.
- Backport only the smallest applicable change.
- Delete a local patch once the pinned upstream source contains it.
- Keep negative results when they prevent repeated dead-end work.
- Do not claim an optimization without a board-level result.

This fork remains an OpenWrt-derived GPL-2.0 project. See
[`COPYING`](COPYING) and [`LICENSES/`](LICENSES/) for license texts. General
OpenWrt development and user documentation remains available at
[openwrt.org/docs](https://openwrt.org/docs/); it is intentionally not copied
into this fork's project README.
