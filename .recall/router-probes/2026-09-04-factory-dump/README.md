# E8450 factory dump + 5 GHz TX-power raise — 2026-09-04

See **EEPROM-MAP.md** in this directory for the full field-by-field map of
both radio eeproms (offsets, values, cal regions, channel-group mapping,
power model). Tooling: `scripts/e8450/eeprom.sh` (view/check/set/apply;
`apply max30` reproduces the flashed image byte-for-byte).

## Access
Live box: `ssh root@192.168.1.1` (ARP `80:69:1a:1e:85:83`, eth0 direct,
pw `Braxtonb112218!`), kernel 6.12.94 (root@DietPi, 2026-09-01), OpenWrt
25.12-style apk image. Factory = UBI volume `ubi0_1` (5 LEBs, 634880 B
capacity, 524288 B used). `dd if=/dev/ubi0_1 bs=126976 count=5`.

## Files (md5)
- `factory-ubi0_1.bin`            b23391d1db51f9298547b1595c8aef44  — pristine stock
- `factory-patched-canary.bin`    43f8da69f4f9852b706f3908484eac03  — 5G 0x26→0x29
- `factory-final.bin`             226895bb9a794ea3907790e332d9ef4c  — 5G 0x26→0x2B (live)
- `factory-24g-final.bin`         2b8a9e0dc98f3d02664102e4e778cb36  — + 2.4G 0x26→0x2A (live)
- On-box pristine backup: `/root/factory-pristine-20260904.bin` (same md5 as above)

## Eeprom map (both radios in one volume)
- 0x0000 MT7622 WMAC eeprom (mt7615e, 2.4G, chip `22 76`, MAC …:84), ~0x400 used
- 0x5000 MT7915 eeprom (mt7915e, 5G, chip `15 79`, MAC …:85), V1 layout (0xe00)
- 0x7fff4/0x7fffa MAC addresses — do not disturb
- mt7915 V1 5G TX0 power @ rel 0x34b, 4 chains × 12 B:
  bytes +0..+7 = channel groups (ch≤48 g1, ≤64 g2, ≤96 g3, ≤112 g4,
  ≤128 g5, ≤144 g6, >144 g7), +8 = TSSI-off backoff, +9..+11 unused
- All groups stock = 0x26 (38); 5G rate delta V1 @ rel 0x29d = 0xc4; TSSI on
- The mt7981/7976 V2 layout (0x441/0x445/0x465) does NOT apply — MT7915 PCIe
  part, V1 offsets only (`mt7915_check_adie` = 0 off mt798x)

## Change — 5 GHz (wl1, MT7915)
4 bytes abs 0x5352/0x535e/0x536a/0x5376 (rel 0x34b + c*12 + 7, c=0..3:
UNII-3 group-7) 0x26 → 0x2B (0x29 canary first). Writes via
`ubiupdatevol /dev/ubi0_1` + reboot (eeprom read at driver probe only).

Mapping (validated 3 points): `chan->max_power = roundup((target + rate_delta(4) + path_delta(12))/2)`:
0x26→27.0, 0x29→29.0, 0x2B→30.0 dBm. 0.5 dBm/byte.

## Change — 2.4 GHz (wl0, MT7622 WMAC / mt7615e)
4 bytes abs 0x058/0x05e/0x064/0x06a (rel 0x058 + c*6, c=0..3, TSSI branch
of `mt7615_eeprom_get_target_power_index`) 0x26 → 0x2A.
2G rate delta byte @0x0be = 0xc6 (+6, EN|SIGN). Same structure:
`max_power = roundup((target + 6 + 12)/2)`: stock 0x26→28.0 (observed, and
ext-PA branch excluded — it would derive 32), 0x2A→30.0 exact.

## Result (verified post-reboot, both bands)
- 5 GHz `iw phy` 5745-5825 (149-165): 30.0 dBm max (was 27.0)
- 2.4 GHz `iw phy` 2412-2462 (ch 1/6/11): 30.0 dBm max (was 28.0)
- uci txpower=30 both radios, country US — US reg ceilings (30 both bands)
  are now the binding caps (legal max reached); txpower_sku bbp 42→47 (5G)
- dmesg clean (WED v1 attached, no panic/BUG); pstore cleared
- Revert: write pristine dump back with the same ubiupdatevol procedure

## Notes
- Rate deltas (5G @0x252/0x29d, 2.4G @0x0be) and per-rate limit tables also
  gate final power; raising targets scaled the SKU tables up with them.
- mt7915 2G block @0x2fc (0x28) and 6G fields untouched/irrelevant.

## RSSI A/B measurement — 2026-09-04 (Pi wlan0 fixed client, bench ~1-2 m)
Client = this host's wlan0 via NetworkManager (IP-less connections, no
DHCP), samples of `iw dev wlan0 link` signal, 15×/phase @1.2 s.
Power phases toggled via uci txpower + wifi reload (no reflash — uci
emulates the stock eeprom ceilings exactly: 27 = 5G stock, 28 = 2.4G stock).

| band | txpower | mean RSSI | n | raw |
|---|---|---|---|---|
| 5G (ch149) | 30 dBm | -21.0 | 15/15 | all -21 |
| 5G (ch149) | 27 dBm (stock) | -26.0 | 15/15 | all -26 |
| 5G recheck | 30 dBm | -21.0 | 10/10 | all -21 |
| 2.4G (ch1) | 30 dBm | -20.6 | 15 | -22..-18 |
| 2.4G (ch1) | 28 dBm (stock) | -22.8 | 15 | -24..-21 |

Measured gain: 5G **+5.0 dB** for +3 configured (better than nominal —
stock 27 ceiling appears to have delivered ~25 in practice); 2.4G
**+2.2 dB** for +2 configured (matches). Both perfectly reversible.
Raw logs: sig_5g_max.txt / sig_5g_stock.txt / sig_24g_max.txt /
sig_24g_stock.txt. Caveats: bench-close range (-21 dBm), 1 dBm meter
granularity, AP-side only (no spectrum analyzer); S23 at a farther fixed
spot would confirm coverage gain where it matters.

## Channel survey — 2026-09-04 (router radios scan while serving)
`iw dev wl0-ap0/wl1-ap0 scan` works on this box (fresh off-channel scan,
33 BSS 2.4G / 14 BSS 5G). Survey dumps: scan24.txt / scan5.txt.

2.4G: ch1 12 APs incl **-38 dBm co-channel monster** (was our channel);
ch6 6 APs (max -68); ch11 12 APs (max -68); ch4 2 APs (-74, overlaps).
5G: ch149 4 APs incl **hidden -44 dBm** (8e:c8:a0:92:de:90, was our
channel); ch157 3 APs (max -87); ch132 (DFS) 3 APs at -91; ch44 (UNII-1)
4 APs at -85 but 23 dBm cap.

Applied: radio0 ch1→**6** (HT20), radio1 ch149→**157** (HE40, spans
5775-5815, keeps 30 dBm UNII-3). All 8× 2.4G clients rejoined; the lone
5G client reconnects on its own scan cadence. Scan dumps kept for
re-survey comparison.

## S23 far-field A/B — 2026-09-04 (fixed spot, WiFi Analyzer app)
Phone on ch6 (2.4G) + ch157 (5G), both maxed 30 dBm. Stock-emulation
via uci txpower (27 = 5G stock ceiling, 28 = 2.4G stock ceiling).

| band | 30 dBm (raised) | stock-emulation | delta |
|---|---|---|---|
| 5G | -61 dBm | -65 dBm (27) | **+4 dB** clean, reproducible |
| 2.4G | -47..-51 (typ -49/-50) | -45..-49 (typ -47/-48, 28) | **inconclusive** — 2.4G indoor flutter (±3 dB, minutes-apart windows w/ user moving between) exceeds the 2 dB step; two window pairs read ~2 dB inverted vs physics |

2.4G verdict rests on the Pi measurement (+2.2 dB, reversible, 15×
samples/state, sig_24g_*.txt). 5G confirmed far-field at the real spot:
**+4 dB for +3 configured** (matches the Pi's near-field +5 dB direction;
meter granularity accounts for the difference). Final live config:
radio0 ch6 HT20 30 dBm, radio1 ch157 HE40 30 dBm, country US.
