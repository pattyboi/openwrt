#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf 'Usage: %s [IMAGE [e8450|asus|linksys|toshiba]]\n' "$0"
    printf 'Run without arguments for the interactive flashing assistant.\n'
}

require_file() {
    local path=$1
    [[ -f $path ]] || {
        printf 'Required artifact is missing: %s\n' "$path" >&2
        exit 2
    }
}

validate_e8450_bundle() {
    local image_path=$1
    local dir name sums
    dir=$(CDPATH= cd -- "$(dirname "$image_path")" && pwd)
    name=$(basename "$image_path")
    [[ $name == *linksys_e8450-ubi-squashfs-sysupgrade.itb ]] || {
        printf 'E8450 flashing requires the linksys_e8450-ubi sysupgrade ITB.\n' >&2
        printf 'For initial migration, use the supported UBI installer/recovery workflow.\n' >&2
        exit 2
    }

    require_file "$dir/${name%-squashfs-sysupgrade.itb}-preloader.bin"
    require_file "$dir/${name%-squashfs-sysupgrade.itb}-bl31-uboot.fip"
    require_file "$dir/${name%-squashfs-sysupgrade.itb}-initramfs-recovery.itb"

    sums=$dir/sha256sums
    if [[ -f $sums ]]; then
        (cd "$dir" && sha256sum -c "$sums" --ignore-missing >/dev/null) || {
            printf 'E8450 artifact checksum verification failed.\n' >&2
            exit 2
        }
    else
        printf 'Warning: sha256sums is missing; artifact presence was checked only.\n' >&2
    fi

    printf '%s\n' \
        'Verified complete E8450 UBI artifact set:' \
        "  sysupgrade: $image_path" \
        "  preloader:  $dir/${name%-squashfs-sysupgrade.itb}-preloader.bin" \
        "  FIP:        $dir/${name%-squashfs-sysupgrade.itb}-bl31-uboot.fip" \
        "  recovery:   $dir/${name%-squashfs-sysupgrade.itb}-initramfs-recovery.itb"
    printf '%s\n' \
        'The SSH sysupgrade path flashes the sysupgrade ITB only.' \
        'The preloader/FIP are not raw-written over SSH; use the supported UBI' \
        'installer/recovery procedure for initial migration or bootloader updates.'
}

[[ ${1:-} != -h && ${1:-} != --help ]] || { usage; exit 0; }
command -v tftp >/dev/null 2>&1 || tftp_missing=1

image=${1:-}
vendor=${2:-}
if [[ -z $image ]]; then
    printf 'Firmware image: '
    read -r image
fi
[[ -f $image ]] || { printf 'Image not found: %s\n' "$image" >&2; exit 2; }

if [[ -z $vendor ]]; then
    printf '%s\n' 'Flash method:' '  1) Linksys E8450 sysupgrade (SSH/SCP)' \
        '  2) Asus legacy TFTP' '  3) Linksys legacy TFTP' '  4) Toshiba legacy TFTP'
    printf 'Select [1]: '
    read -r choice
    case ${choice:-1} in
        1) vendor=e8450 ;; 2) vendor=asus ;; 3) vendor=linksys ;; 4) vendor=toshiba ;;
        *) printf 'Invalid selection.\n' >&2; exit 2 ;;
    esac
fi

if [[ $vendor == e8450 ]]; then
    validate_e8450_bundle "$image"
    helper=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)/flash-e8450-sysupgrade.sh
    [[ -x $helper ]] || { printf 'Missing executable helper: %s\n' "$helper" >&2; exit 2; }
    if [[ -z ${E8450_TARGET:-} ]]; then
        printf 'Router SSH target [root@192.168.1.1]: '
        read -r E8450_TARGET
        export E8450_TARGET=${E8450_TARGET:-root@192.168.1.1}
    fi
    exec "$helper" "$image"
fi

[[ ${tftp_missing:-0} -eq 0 ]] || { printf 'tftp is required for legacy TFTP flashing.\n' >&2; exit 2; }
case $vendor in
    asus|linksys|toshiba) ;;
    *) printf 'Unknown flash method: %s\n' "$vendor" >&2; usage >&2; exit 2 ;;
esac

case $vendor in
    asus|linksys) host=192.168.1.1 ;;
    toshiba) host=192.168.10.1 ;;
esac

cat <<EOF
Connect the computer directly to a LAN port and set a static address on the
same subnet as $host. Do not interrupt power while the router writes flash.
EOF
printf 'Ready to send %s to %s? (y/N): ' "$image" "$host"
read -r confirm
[[ $confirm == y || $confirm == Y ]] || { printf 'Cancelled.\n'; exit 0; }

if [[ $vendor == asus ]]; then
    printf 'get ASUSSPACELINK\x01\x01\xa8\xc0 /dev/null\nquit\n' | tftp "$host"
    printf 'binary\nput %q ASUSSPACELINK\nquit\n' "$image" | tftp "$host"
else
    printf 'rexmt 1\ntrace\nbinary\nput %q\nquit\n' "$image" | tftp "$host"
fi
printf 'Transfer complete. Follow the router LEDs and keep power connected until it reboots.\n'
