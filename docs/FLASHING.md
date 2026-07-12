# Flashing the E8450

The canonical entry point is:

```sh
./scripts/flashing/flash.sh
```

It interactively selects the E8450 SSH/SCP sysupgrade path or one of the
legacy TFTP paths. The E8450 path copies the image with legacy SCP and invokes
`sysupgrade`; it asks for the router target and password without storing either
in the repository. `sshpass` is required for that path.

For an E8450 UBI image, the script requires the matching sysupgrade ITB,
preloader, BL31/U-Boot FIP, and initramfs recovery artifact in the same output
directory, and verifies them against `sha256sums` before flashing. SSH
`sysupgrade` writes only the sysupgrade ITB. It intentionally does not raw-write
the preloader or FIP; initial migration and bootloader updates must use the
supported UBI installer/recovery procedure.

The legacy TFTP modes are retained for the historical Asus, Linksys, and
Toshiba workflows. They require the host `tftp` client, a direct LAN
connection, and a static address on the router's bootloader subnet. The script
always asks for confirmation before transmitting an image.

For automation, the E8450 helper remains available:

```sh
E8450_TARGET=root@192.168.1.1 ./scripts/flash-e8450-sysupgrade.sh IMAGE
```

Never remove power while a router is writing flash. Verify the image target and
the router address before confirming a transfer.

## USB recovery sysupgrade

E8450 images include an automatic USB recovery path for the case where the
router is otherwise booted but SSH is unavailable. Format a USB drive as
FAT/FAT32 and place the E8450 sysupgrade ITB at its filesystem root with this
exact name:

```text
e8450-sysupgrade.itb
```

Insert the drive into the router. The hotplug handler mounts it read-only,
copies the image to RAM, runs `sysupgrade -T` compatibility validation, then
immediately runs `sysupgrade` while preserving the existing configuration.
It accepts no other filesystem or filename, does not use `--force`, and logs
under the `e8450-usb-sysupgrade` tag. Inserting a drive with that exact file is
therefore an intentional flash action; remove or rename the file before using
the drive for anything else.

## Post-flash boot verification

After any flash, verify the boot over SSH before drawing conclusions
(checklist proven on the 2026-07-12 reflash, recorded in
`docs/E8450-hardware-software-reference.md` §2026-07-12 reflash):

1. `ubus call system board` — revision must exactly match the repo's
   `bin/targets/mediatek/mt7622/version.buildinfo`, board `linksys,e8450-ubi`.
2. `dmesg | head -1` — the kernel banner names the build host and GCC
   revision, confirming it is our image and not an official one.
3. `dmesg | grep -E "wed|mt7915"` — expect the `wed-breadcrumb` reserved-mem
   line and `mt7915e` probed at boot (modules.d load; never load it later).
4. `ls /sys/fs/pstore/` — must be empty, otherwise u-boot's `pstore check`
   will boot the recovery volume on the next reboot (save then delete dumps).
5. `apk list --installed | wc -l` — a healthy image carries ~150+ packages;
   `opkg` reporting 0 is expected on 25.12 (apk-based), not a stripped image.
   A near-empty apk list means the stale-targetinfo failure mode recurred —
   see the CLAUDE.md build notes.
6. Confirm liveness from a second, independent path per CLAUDE.md rule 5.
7. Reapply CPU/IRQ tuning if this was a *sysupgrade* over an existing
   config (not a fresh flash): `/etc/rc.local` and
   `network.globals.packet_steering` are both preserved as user config
   across sysupgrade, so if the box was ever recovered to a stock image
   first, the stock empty `rc.local` and default `packet_steering` value
   silently ride along and shadow this repo's `files/etc/rc.local` —
   confirmed recur on 2026-07-12 (see reference doc §Net-infrastructure
   audit). Check: `cat /etc/rc.local` should match the repo file, and
   `uci get network.globals.packet_steering` should read `2`; if not,
   `cat files/etc/rc.local | ssh root@<ip> "cat > /etc/rc.local && sh
   /etc/rc.local"` and `uci set network.globals.packet_steering='2';
   uci commit network; /etc/init.d/network reload` fix it live, no
   rebuild needed.
