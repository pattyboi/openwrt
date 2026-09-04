#!/bin/sh
# E8450 factory-volume eeprom tool (MT7622 WMAC + MT7915 V1 layouts)
#
# Ground-truth offsets from .recall/router-probes/2026-09-04-factory-dump/
# (EEPROM-MAP.md) and mt76 mt7915/mt7615 eeprom.h. Only ever edits a FILE
# copy; flashing to the live volume is a separate, explicit step (see
# 'flash' output below). No checksums exist over these fields (verified:
# mt76 reads none, u-boot boots patched volumes).
#
# Usage:
#   eeprom.sh view  FILE                 annotated decode of both radios
#   eeprom.sh check FILE                 sanity + diff vs stock bytes
#   eeprom.sh set   FILE 24g-tx|5g-g7 HEX  set a field to a hex byte
#   eeprom.sh apply FILE stock|max30     apply a preset (validated combo)
#
# Fields (single byte written to N chain slots):
#   24g-tx  MT7622 wmac 2.4G chain targets @0x58 + c*6   (c=0..3)
#   5g-g7   MT7915 5G channel-group 7 (ch>144, UNII-3)   @0x5352 + c*12
#
# Presets: stock = 0x26/0x26  |  max30 = 0x2A (24g) / 0x2B (5g-g7)
# Implied per-channel ceiling: max_power = roundup((target + delta + 12)/2)
#   with delta 4 (5G) / 6 (2.4G); result clamps to the regdomain cap.

set -u

E_7915=0x5000   # mt7915 eeprom island base (volume offset)
CHK_7915="15 79"
E_7622=0x0      # mt7622 wmac eeprom island base
CHK_7622="22 76"

die() { echo "eeprom.sh: $*" >&2; exit 1; }

# byte reader: od where present (host), hexdump fallback (OpenWrt busybox)
rd() {
    if command -v od >/dev/null 2>&1; then
        od -A n -t x1 -j "$2" -N "$3" "$1"
    else
        hexdump -s "$2" -n "$3" -v -e '1/1 "%02x "' "$1"
    fi | tr -s ' ' | sed 's/^ //; s/ $//'
}
# byte writer: octal escape (POSIX printf; dash/busybox lack \xHH)
wb() { oct=$(printf '%03o' $((0x$2))); printf "\\$oct" | dd of="$1" bs=1 seek=$(( $3 )) conv=notrunc 2>/dev/null; }

STOCK_24=26    # stock 2.4G chain target byte (wmac island)
STOCK_5G=26    # stock 5G group-7 target byte (mt7915 island)

sanity() { # FILE -> prints island chips, dies on mismatch
    f=$1
    [ -f "$f" ] || die "no such file: $f"
    [ $(wc -c < "$f") -ge 524288 ] || die "file too small for a factory volume ($(wc -c < "$f") B)"
    c7915=$(rd "$f" $((E_7915)) 2); [ "$c7915" = "$CHK_7915" ] || die "mt7915 chip id mismatch at 0x5000: got '$c7915' (expect '$CHK_7915') — not an E8450 factory dump?"
    c7622=$(rd "$f" $((E_7622)) 2); [ "$c7622" = "$CHK_7622" ] || die "mt7622 chip id mismatch at 0x0: got '$c7622' (expect '$CHK_7622')"
}

ceil2() { echo $(( ($1 + 1) / 2 )); }

view() { # FILE
    f=$1; sanity "$f"
    mac=$(rd "$f" 0x4 6 | tr -d ' ' | sed 's/\(..\)/&:/g;s/:$//')
    echo "== MT7622 WMAC island @0x0 (2.4G, mt7615e) =="
    echo "  chip $c7622  MAC $mac"
    nic0=$(rd "$f" 0x34 1); tssi=$(rd "$f" 0x37 1)
    echo "  NIC_CONF_0 0x34=0x$nic0 (TX/RX paths: $(echo $((0x$nic0)) | awk '{printf "%d", 0x$nic0}') bitmask), TSSI_2G@0x37 bit5: $([ $(( 0x$tssi & 0x20 )) -ne 0 ] && echo on || echo off)"
    dt2=$(rd "$f" 0xbe 1)
    echo "  2G rate-delta 0xbe=0x$dt2 (EN=$([ $((0x$dt2 & 0x80)) -ne 0 ] && echo y || echo n), sign=$([ $((0x$dt2 & 0x40)) -ne 0 ] && echo + || echo -), mag=$((0x$dt2 & 0x3f)))"
    echo "  2.4G chain TX targets @0x58+c*6 (patched bytes; implied dBm = roundup((t+6+12)/2), reg cap 30):"
    for c in 0 1 2 3; do
        v=$(rd "$f" $((0x58 + c*6)) 1)
        echo "    ch$c: 0x$v  -> ~$(ceil2 $((0x$v + 18))) dBm"
    done
    echo "== MT7915 island @0x5000 (5G, mt7915e, V1 layout) =="
    mac5=$(rd "$f" $((E_7915+0x4)) 6 | tr -d ' ' | sed 's/\(..\)/&:/g;s/:$//')
    wc=$(rd "$f" $((E_7915+0x190)) 8)
    echo "  chip $c7915  MAC $mac5"
    echo "  WIFI_CONF 0x190: $wc (byte0 TX/RX, byte7 TSSI: $([ $(( 0x$(rd "$f" $((E_7915+0x197)) 1) & 0x04 )) -ne 0 ] && echo 5G-on || echo 5G-off))"
    d5=$(rd "$f" $((E_7915+0x29d)) 1)
    echo "  5G rate-delta 0x29d=0x$d5 (EN=$([ $((0x$d5 & 0x80)) -ne 0 ] && echo y || echo n), sign=$([ $((0x$d5 & 0x40)) -ne 0 ] && echo + || echo -), mag=$((0x$d5 & 0x3f)))"
    echo "  5G TX targets @0x34b+c*12, 8 channel groups/chain (implied dBm = roundup((t+4+12)/2)):"
    echo "    group map: 0=184-196 1=ch<=48 2=<=64 3=<=96 4=<=112 5=<=128 6=<=144 7=>144(UNII-3)"
    for c in 0 1 2 3; do
        row=""
        for g in 0 1 2 3 4 5 6 7; do
            v=$(rd "$f" $((E_7915+0x34b + c*12 + g)) 1)
            row="$row g$g=0x$v(~$(ceil2 $((0x$v + 16)))dBm)"
        done
        echo "    chain$c:$row"
    done
    echo "== volume tail =="
    lan=$(rd "$f" 0x7fff4 6 | tr -d ' ' | sed 's/\(..\)/&:/g;s/:$//')
    wan=$(rd "$f" 0x7fffa 6 | tr -d ' ' | sed 's/\(..\)/&:/g;s/:$//')
    echo "  LAN MAC @0x7fff4: $lan   WAN MAC @0x7fffa: $wan"
}

check() { # FILE: sanity, show current vs stock
    f=$1; sanity "$f"
    cur_24=$(rd "$f" 0x58 1); cur_5g=$(rd "$f" $((E_7915+0x34b+7)) 1)
    echo "field     current  stock   state"
    echo "24g-tx    0x$cur_24    0x$STOCK_24    $([ "$cur_24" = "$STOCK_24" ] && echo stock || echo PATCHED)"
    echo "5g-g7     0x$cur_5g    0x$STOCK_5G    $([ "$cur_5g" = "$STOCK_5G" ] && echo stock || echo PATCHED)"
    if [ "$cur_24" = "$STOCK_24" ] && [ "$cur_5g" = "$STOCK_5G" ]; then
        echo "no TX-power edits present"
    fi
}

set_field() { # FILE FIELD HEX  (writes chain slots, prints diff + flash steps)
    f=$1; field=$2; val=$3
    case "$val" in
        [0-9a-fA-F][0-9a-fA-F]) ;;
        *) die "value must be a 2-digit hex byte, got '$val'" ;;
    esac
    sanity "$f"
    case "$field" in
        24g-tx) offs="0x58 0x5e 0x64 0x6a";;
        5g-g7)  offs="0x5352 0x535e 0x536a 0x5376";;
        *) die "unknown field '$field' (24g-tx | 5g-g7)";;
    esac
    before=$(rd "$f" $(echo $offs | cut -d' ' -f1) 1)
    for o in $offs; do wb "$f" "$val" $o; done
    after=$(rd "$f" $(echo $offs | cut -d' ' -f1) 1)
    echo "wrote $field = 0x$val to: $offs"
    echo "field byte changed 0x$before -> 0x$after"
    flash_hint "$f"
}

apply() { # FILE PRESET
    f=$1; preset=$2; sanity "$f"
    case "$preset" in
        stock)  v24=26; v5=26 ;;
        max30)  v24=2a; v5=2b ;;
        *) die "unknown preset '$preset' (stock | max30)" ;;
    esac
    echo "== applying preset '$preset': 24g-tx=0x$v24 5g-g7=0x$v5 =="
    set_field "$f" 24g-tx "$v24"
    set_field "$f" 5g-g7 "$v5"
}

flash_hint() { # FILE
    f=$1
    echo "--"
    echo "Flash this file to the live factory volume ONLY with a backup in hand:"
    echo "  router: dd if=/dev/ubi0_1 of=/root/factory-backup-\$(date +%F).bin bs=126976 count=5"
    echo "  host:   scp/ssh-push $f to /tmp on the router, then:"
    echo "          ubiupdatevol /dev/ubi0_1 /tmp/$(basename "$f") && reboot"
    echo "  revert: ubiupdatevol /dev/ubi0_1 /root/factory-backup-*.bin && reboot"
    echo "  (eeprom is read at driver probe only; reboot is mandatory. Never runtime-reload mt7915e.)"
}

cmd=${1-}; [ $# -ge 1 ] && shift
case "$cmd" in
    view)  [ $# -eq 1 ] && view "$1" || die "usage: eeprom.sh view FILE" ;;
    check) [ $# -eq 1 ] && check "$1" || die "usage: eeprom.sh check FILE" ;;
    set)   [ $# -eq 3 ] && set_field "$1" "$2" "$3" || die "usage: eeprom.sh set FILE 24g-tx|5g-g7 HEX" ;;
    apply) [ $# -eq 2 ] && apply "$1" "$2" || die "usage: eeprom.sh apply FILE stock|max30" ;;
    *) die "usage: eeprom.sh view|check|set|apply FILE ..." ;;
esac
