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
