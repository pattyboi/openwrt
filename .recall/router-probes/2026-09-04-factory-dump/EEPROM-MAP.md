# E8450 factory volume — EEPROM map (MT7622 WMAC + MT7915 V1)

Source dump: `factory-ubi0_1.bin` (md5 `b23391d1db51f9298547b1595c8aef44`),
UBI volume `ubi0_1` ("factory"), 524288 B used of 634880 B capacity.
Ground truth from the dump itself + mt76 headers (`mt7915/eeprom.h`,
`mt7615/eeprom.h`) + driver code (`mt7915/eeprom.c`, `mt7615/eeprom.c`,
`init.c` txpower paths). Companion tool: `scripts/e8450/eeprom.sh`
(view / check / set / apply).

## Volume layout (512 KB, ~95 % empty)

| offset | size | content |
|---|---|---|
| 0x0000 | ~0x180 used | MT7622 WMAC eeprom (2.4G, mt7615e) — dts `eeprom@0` ("actual length 0x400") |
| 0x0000–0x4FFF | — | zero-filled (no data, no hidden backup) |
| 0x5000 | 0xE00 | MT7915 eeprom (5G, mt7915e, V1 layout, = `MT7915_EEPROM_SIZE` 3584) — dts `eeprom@5000` |
| 0x5E00–0x7FFF3 | — | zero-filled |
| 0x7FFF4 | 6 B | LAN MAC (`macaddr@7fff4` → gmac0) |
| 0x7FFFA | 6 B | WAN MAC (`macaddr@7fffa` → wan) |

No checksums exist over these fields (mt76 reads none; u-boot boots a
modified volume — verified by flashing `factory-final.bin`/`factory-24g-final.bin`).

## MAC allocation (sequential from WAN base)

`80:69:1a:1e:85:82` WAN · `…:83` LAN · `…:84` 2.4G (wmac eeprom 0x4) ·
`…:85` 5G (mt7915 eeprom 0x4). mt7915 `MT_EE_MAC_ADDR2` @0x00a is cal
data, not a MAC.

## MT7622 WMAC island @0x0 (2.4G only — all 5G fields zeroed)

| off | field (mt7615/eeprom.h) | value | notes |
|---|---|---|---|
| 0x00 | CHIP_ID | `22 76` | = 0x7622 |
| 0x02 | VERSION | `02 00` | 0x0002 |
| 0x04 | MAC_ADDR | `…:84` | |
| 0x10 | (flags) 0x81; 0x11-12 | `55 53` | "US" country string |
| 0x34 | NIC_CONF_0 | `44` | 4 TX + 4 RX paths |
| 0x36/37 | NIC_CONF_1 / +1 | `00` / `20` | bit5 = TSSI_2G on |
| 0x3e | WIFI_CONF | `20` | |
| 0x52 | CALDATA_FLASH | `00` | no DPD/RX-cal flags |
| 0x58 + c*6 | TX0_2G_TARGET_POWER chain c | **0x26** (→0x2A patched) | c=0..3: 0x58/5e/64/6a. **TSSI branch** (`ext_pa_enabled` false — proven: EXT-PA formula would derive 32, observed 28) |
| 0xbe | 2G_RATE_POWER (delta) | `c6` | EN+sign+mag6 → +6 |
| 0xd5 | 5G_RATE_POWER | 0 (unused) | |
| 0xf2 | EXT_PA_2G_TARGET | `2e` | present but branch not taken |
| 0x70-0xad | TX0/1_5G targets | all 0 | wmac is 2.4G-only on E8450 |

**Per-device calibration** (mt7615 `ical[]`, applied at init, do NOT
touch): 0x53-0x57 (`bb 40 ae c3 c3`), 0x5c/5d (`41 c4`), 0x62/63, 0x68/69,
0x6e/6f, 0x82-0x9c, 0xa0-a1, 0xaa-ba, 0xf4 (`9b`), 0xf7 (`87`), 0xff —
interleaved *between* the chain-target bytes; our patch offsets
(0x58/5e/64/6a) are NOT in `ical[]` (verified safe). Stray nonzero:
0x15e/15f (`77 07`), 0x120-0x123 (`0b 00 00 09`).

## MT7915 island @0x5000 (5G, V1 layout)

| off (rel) | field | value | notes |
|---|---|---|---|
| 0x000 | CHIP_ID | `15 79` | = 0x7915 |
| 0x002 | VERSION | `00 00` | layout chosen by chip, not this byte |
| 0x004 | MAC_ADDR | `…:85` | |
| 0x00a | MAC_ADDR2 | `00 0c 43 26 59 97` | cal, not a MAC |
| 0x050 | DDIE_FT_VERSION | `01 00` | |
| 0x05c-5d | | `55 53` | "US" |
| 0x062 | DO_PRE_CAL | `00` | no precal → runtime cal only |
| 0x190-197 | WIFI_CONF | `24 52 06 00 28 00 00 15` | 4x4 paths; byte7 0x15: TSSI 2G/5G bits set |
| 0x252 | RATE_DELTA_2G | `c6` | +6 (unused, 5G-only band) |
| 0x29d | RATE_DELTA_5G | `c4` | +4 |
| 0x2fc + c*3 | TX0_POWER_2G | `28 00 02` ×4 | unused (5G-only) |
| 0x34b + c*12 | TX0_POWER_5G chain c | 8 group bytes + backoff + 3 tail | group byte +0..+7; +8 = TSSI-off backoff (0); +9..+11 = `03 03 03` (chain3: `00 00 00`) |
| — | 5G group-7 byte (ch>144) | **0x26** (→0x2B patched) | off 0x352 + c*12 = abs 0x5352/535e/536a/5376 |
| 0x9a0 | ADIE_FT_VERSION | `02 a9 00 00` | |

Dense tables NOT read by the mainline V1 TX-power path (presumed WM
firmware / TSSI per-rate reference — safe from edits, not binding caps;
measured gains prove firmware honors raised SKU targets):
0x252-0x2fc (141 B), 0x441-0x560 (223 B, 6-byte records
`42 51 51 63 74 08 …`), 0x7d3-0x884 (V2-layout delta fields present),
0x884-0x9a0 (152 B), 0xa00-0xdbf (747 B).

## Channel-group map (mt7915, non-7976) — which byte to patch

| group | channels | reg cap (US) |
|---|---|---|
| 0 | 184-196 | n/a |
| 1 | ≤48 (36-48) | 23 |
| 2 | ≤64 (52-64) | 24, DFS |
| 3 | ≤96 | 24, DFS |
| 4 | ≤112 | 24, DFS |
| 5 | ≤128 | 24, DFS |
| 6 | ≤144 | 30 (149 is 40 MHz-lower edge) |
| 7 | >144 (149-165) | **30** |

Only group 7 (UNII-3) can exceed the reg cap on other groups, so only it
was raised. 2.4G reg cap 30.

## TX-power model (validated empirically, 2026-09-04)

`chan->max_power = DIV_ROUND_UP((target + rate_delta + path_delta)/2)`,
path_delta = 12 (4 chains); 5G delta 4, 2.4G delta 6. → **0.5 dBm per
byte**. Measured: 5G 0x26→27.0, 0x29→29.0, 0x2B→30.0; 2.4G 0x26→28.0,
0x2A→30.0. Final clamp = regdomain (`min(max_reg_power, derived)`).
RSSI-verified gains: 5G +4 dB far-field (S23), +5 dB near-field (Pi);
2.4G +2.2 dB (Pi). See README.md in this directory.

## State & revert

- Stock: 0x26 / 0x26 (both fields) — `factory-ubi0_1.bin`, also
  `/root/factory-pristine-20260904.bin` on the router.
- Live (2026-09-04): 0x2A (2.4G) / 0x2B (5G g7) — `factory-24g-final.bin`
  (md5 `2b8a9e0dc98f3d02664102e4e778cb36`).
- Tool: `scripts/e8450/eeprom.sh apply FILE stock|max30` reproduces both
  states byte-for-byte.
- Flash: backup → push file → `ubiupdatevol /dev/ubi0_1 /tmp/file` →
  reboot (eeprom read at driver probe; NEVER runtime-reload mt7915e).

## Open questions / not derivable from this dump

- Per-unit vs common calibration (ical/TSSI table semantics) — needs a
  second RT3200/E8450 dump to compare.
- Long-run thermal behavior at 30 dBm (TSSI loop active; thermal zone has
  no cooling device bound) — needs a soak test, not a dump.
