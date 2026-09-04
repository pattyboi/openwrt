# 2.4 GHz vendor VHT20/QAM-256 experiment

Date: 2026-09-04

Status: applied to the live Linksys E8450 and retained after hardware
validation.

## Scope

The experiment adds an explicit, opt-in path for vendor QAM-256 VHT
operation on the integrated MT7622/MT7615 2.4 GHz radio. The PCIe MT7915
5 GHz radio and its WED-v1 path are unchanged.

The default remains legacy 2.4 GHz HT behavior. VHT20 is enabled only when
both of these are true:

- the radio configuration sets `vht2g=1`; and
- the selected radio advertises the new mac80211 vendor capability.

## Source changes

- `package/kernel/mac80211/patches/subsys/200-mac80211-introduce-support-for-vendor-QAM-256-in-2.4.patch`
  adds `vendor_qam256_supported` to the VHT station capability path and
  enables the 2.4 GHz VHT capability handling.
- `package/kernel/mac80211/patches/subsys/201-mac80211-add-logic-to-skip-useless-VHT-cap-check-in.patch`
  avoids rejecting VHT operation when the HT capability set cannot use a
  40 MHz channel.
- `package/kernel/mt76/patches/200-mt76-allow-VHT-rate-on-2.4GHz.patch`
  threads the 2.4 GHz VHT capability through mt76 and marks only the MT7615
  2.4 GHz path as vendor-QAM-256 capable. It does not alter MT7915.
- `package/network/config/wifi-scripts/files-ucode/usr/share/ucode/wifi/hostapd.uc`
  and the legacy `mac80211.sh` path gate 2.4 GHz `ieee80211ac` on `vht2g`.
- `package/network/config/wifi-scripts/files-ucode/usr/share/schema/wireless.wifi-device.json`
  exposes `vht2g` as a boolean with a default of `false`.

## Build and flash

The relevant package, kernel, target, and image stages completed
successfully. The final image was staged with `make package/install`, then
rebuilt with `make target/install`; `make checksum` validated the complete
E8450 artifact bundle.

Image flashed:

```text
bin/targets/mediatek/mt7622/openwrt-mediatek-mt7622-linksys_e8450-ubi-squashfs-sysupgrade.itb
```

The existing E8450 SSH sysupgrade helper was used. It writes only the
sysupgrade ITB; preloader and FIP artifacts were not raw-written. A local,
non-versioned configuration backup was captured before flashing.

Build gotcha: the first image was generated before the rebuilt
`wifi-scripts` package had been installed into the image root. Live-file
verification caught that omission. After `make package/install`, the staged
rootfs contained the new `vht2g` plumbing, checksums were regenerated, and
the corrected image was flashed.

## Live configuration

The final live configuration is:

```text
radio0: band=2g channel=6 htmode=VHT20 vht2g=1 txpower=30 country=US
radio1: band=5g channel=157 htmode=HE40 txpower=30 country=US
```

Generated hostapd configuration for radio0 contained:

```text
ieee80211ac=1
vht_oper_chwidth=0
```

MT7915 WED remained boot-only and healthy:

```text
options mt7915e wed_enable=Y
mt7915e ... attaching wed device 0 version 1
```

## Hardware result

The router booted the corrected image and remained reachable. The router
itself reached `1.1.1.1` with 3/3 successful probes after the flash.

Before the change, the PS4 client identified by its DHCP hostname negotiated
non-VHT 2.4 GHz rates, including 26 Mbps RX at MCS 3. After enabling VHT20,
the same client negotiated VHT rates:

- observed `VHT-MCS 3` through `VHT-MCS 4`, NSS 1;
- observed RX rates from 26 to 39 Mbps;
- expected throughput reached 53.2 Mbps in a later sample.

Rates varied with the client's weak, approximately -75 dBm signal. The
result proves VHT negotiation, not a controlled throughput improvement.

The initial reload briefly reduced the associated-client count while
stations reconnected. All seven 2.4 GHz clients were associated again and
remained present through a 60-second soak. DHCP leases remained present and
the WAN probe stayed successful. No panic markers were found; the persisted
boot console was saved before being cleared from pstore.

A controlled iperf throughput comparison was not possible in this session:
the router had no iperf endpoint and the available local Wi-Fi adapter was
HT-only. A dedicated 2.4 GHz VHT client and controlled wired endpoint are
required for that measurement.

## Rollback

If a client regression appears, restore the default path on the router:

```sh
uci set wireless.radio0.htmode='HT20'
uci delete wireless.radio0.vht2g
uci commit wireless
wifi reload
```

The 5 GHz configuration and WED boot rule must remain untouched during any
rollback or follow-up test.
