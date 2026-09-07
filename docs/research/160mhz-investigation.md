# 160 MHz on 5 GHz — investigated and rejected

> **Status: closed, do not reopen without new upstream driver evidence.**
> This board's 5 GHz radio is MT7915 (PCIe, non-DBDC/single-band M.2 card).
> Runtime guidance remains in the [ROM handbook](../README.md).

## Result

160 MHz (HE160) is technically negotiable on this hardware but is rejected
for production use. Three independent reasons, any one of which is
sufficient on its own:

1. No DFS-free 160 MHz channel exists under the US regulatory table.
2. This board cannot do background DFS CAC (single 5 GHz PHY), so any
   in-service radar hit on a 160 MHz channel is a harder outage than the
   existing DFS exposure on a 40/80 MHz channel.
3. MT7915 has a known, currently unresolved real-world throughput collapse
   at 160 MHz, independent of the client's own capability.

## Driver capability (mt76, `mt7915/`)

Sourced from `openwrt/mt76` (`mt7915/init.c`, `mt7915/eeprom.c`,
`mt76_connac.h`), master @ `be5ce7910521` (2026-08-13 snapshot):

- MT7915 never advertises `IEEE80211_VHT_CAP_SUPP_CHAN_WIDTH_160MHZ`
  (802.11ac VHT160). That bit was added, found redundant/wrong alongside
  `EXT_NSS_BW`, and removed upstream (commit `3ec5ac12ac8a`,
  "remove VHT160 capability on MT7915").
- MT7915 does advertise HE PHY `CAP0_CHANNEL_WIDTH_SET_160MHZ_IN_5G`
  (802.11ax HE160), but only when `dev->dbdc_support == false` — the case
  for this board's single-band 5 GHz M.2 card — and only at
  `nss_160 = nss / 2` spatial streams (`mt7915_init_he_caps()`,
  `mt7915_set_stream_he_txbf_caps()`). A DBDC MT7915 card cannot do 160 MHz
  at all (`nss_160 = 0`).
- `dbdc_support` is read from a hardware strap register
  (`MT_HW_BOUND`, offset `0x70010020`, bit 5), not EEPROM, devicetree, or a
  module parameter. There is no user-facing switch for any of this.
- The actual RF/MCU channel-bandwidth programming path
  (`mt76_connac_chan_bw()`, `CMD_CBW_160MHZ` in `mt7915/mcu.c`) is **not**
  chip-gated — only the mac80211 capability-advertisement layer in
  `init.c` restricts what widths ever get negotiated. If mac80211 selects a
  160 MHz chandef, the hardware will be programmed for it regardless of
  chip variant.
- EEPROM's `WIFI_CONF` `band_sel` field (`eeprom.c` around line 163)
  controls `has_2ghz`/`has_5ghz` and antenna/path counts, which feed `nss`
  indirectly. It carries no dedicated "160 MHz capable" bit.

## Regulatory reality (US)

From `wireless-regdb` `db.txt`, `country US: DFS-FCC`:

```text
(5150 - 5250 @ 80), (23), AUTO-BW
(5250 - 5350 @ 80), (24), DFS, AUTO-BW
(5470 - 5730 @ 160), (24), DFS
(5730 - 5850 @ 80), (30), AUTO-BW
(5850 - 5895 @ 40), (27), NO-OUTDOOR, AUTO-BW, NO-IR
```

The only rule wide enough for a 160 MHz channel is `5470–5730 @ 160`
(control channel 114, spanning channels 100–144) — entirely DFS. Channel 50
(36–64) is **not** a valid 160 MHz block: UNII-1 and UNII-2A are two
separate 80 MHz-capped rules with no combined 160 MHz entry, so cfg80211
rejects a 160 MHz chandef spanning them. UNII-3 (channel 163, 149–177) is
also unreachable: the US UNII-4 extension (5850–5895) is capped at 40 MHz
and flagged `NO-IR`. There is no DFS-free path to 160 MHz on this board, in
this regulatory domain.

Channels 100–144 fall in this record's own [channel-group
table](eeprom-calibration.md#5-ghz-channel-groups) (groups 3–5), all DFS,
24 dBm ceiling.

## Why that matters on this board specifically

`mt7622-linksys-e8450.dtsi` sets `mediatek,disable-radar-background;` on the
5 GHz `wifi@0,0` node — this board has exactly one 5 GHz PHY and cannot
pre-clear a fallback DFS channel while serving clients. The existing
production channel choice already accepts foreground DFS CAC on boot
(observed directly: `DFS-CAC-COMPLETED success=1 radar_detected=0` after a
sysupgrade, ~60 s, see the lab notes). A 160 MHz channel sits entirely
inside 100–144, so it does not add new *kinds* of DFS risk beyond what's
already accepted — but it does turn every radar event into a wider-band
outage with no smaller fallback already cleared, on a channel set with less
real-world spectrum availability than 149–165.

## Known throughput regression, MT7915-specific

`openwrt/mt76` issue [#617](https://github.com/openwrt/mt76/issues/617)
(explicitly discusses a Belkin RT-3200): 160 MHz was removed from MT7915
after throughput complaints, later re-added (commit `f9ca70d6367a`, "add
back 160MHz channel width support for MT7915") because it worked for some
users. As of the thread's most recent reproduction (mt76 snapshot
2025-10-20), it still negotiates and passes traffic, but real-world
throughput collapses to ~100 Mbps at 160 MHz vs. >500 Mbps at 80 MHz on the
same link, independent of the client's own 80/160 MHz capability. No fix
for that regression exists in the driver logic checked here (`init.c` /
`mac.c` / `mcu.c` / `eeprom.c` show no throughput-specific special-casing
around 160 MHz as of this investigation).

Combined with the halved spatial-stream count at HE160 (`nss_160 = nss/2`),
160 MHz on this specific chip is a throughput and capacity downgrade versus
80 MHz, not an upgrade — before even weighing the DFS exposure.

## Decision

Do not enable `HE160` in `files/etc/config/wireless`. Keep the 5 GHz radio
at `HE40`/`HE80` on a channel chosen by RF survey. Revisit only if upstream
mt76 lands a fix for the #617 throughput regression *and* a use case
specifically needs channels 100–144.
