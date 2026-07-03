# E8450 / MT7622 — Project Summary & Reference

**Authoritative consolidated reference (2026-07-02).** Basis for future patch
investigation. Every claim here was cross-checked against saved hardware profile,
git state, and built `build_dir` source. Companion doc:
[`PHASE3-patch-verdicts.md`](PHASE3-patch-verdicts.md) (per-patch verdicts).

---

## 1. Hardware ground truth (Linksys E8450, from `~/staging/router-hw-profile/`)

| Fact | Value / evidence |
|---|---|
| SoC | **MT7622**, NETSYSv1, 2× Cortex-A53 aarch64 (`compatible=mediatek,mt7622`) |
| Base FW | OpenWrt **25.12.4 r32933-4ccb782af7**, kernel **6.12.87** |
| Frame engine | `1b100000.ethernet` (NETSYSv1 base; NOT 15100000 v2/v3) |
| WED | **v1**, 2 units `1020a000.wed`+`1020b000.wed`; wed0/wed1 debugfs bind |
| DSA switch | **MT7531** (`mt7530-mdio`), single GMAC `eth0`, CPU port **fixed 2500base-x** |
| Wi-Fi | **MT7915E** (PCIe `[14c3:7915]`, Wi-Fi 6) + MT7622 `18000000.wmac`; 2 PHYs |
| Flash | **SPI-NAND** 128 MiB Winbond, UBI; volumes: fip/factory/ubootenv{,2}/recovery/**fit**(12.9M)/boot_backup/rootfs_data |
| Firewall | **nftables / fw4** (`nft_flow_offload`; **zero** xt_FLOWOFFLOAD/iptables) |
| RAM | 512 MiB; `nf_conntrack_max`=31744 |
| **Absent HW** | no 10G/XGMAC/USXGMII, no SFP cage, no Aquantia/2.5G ext-PHY, no crypto engine, thermal=**mtk-thermal** (not lvts), PCIe=**gen2** mtk-pcie (not gen3), no SPI-NOR |
| Constraints | **No UART.** Recovery = power-cycle only. `mtk-wdt` 31s; ramoops@42ff0000 |
| Router access | SSH `root@192.168.1.1`, passwordless root (empty authorized_keys, `none` auth); survives `-n` wipe. Build host `enp1s0`=192.168.1.2 |

These filters decide almost every patch verdict: anything scoped to
MT7981/7986/7987/7988, NETSYSv2/v3, 10G/XGMAC, crypto/xfrm, lvts, gen3-PCIe, or
iptables is inert here.

---

## 2. Branch map

| Branch | Head | Role |
|---|---|---|
| **`e8450-hw-driven`** | `5857dfd386` | **CANONICAL.** Vanilla 25.12.4 (`ba915c2ee7`) + curated 7-patch set. Build from here. |
| `e8450-mainline-pppq` | `00a71ef3e5` | Superseded. Carries ppe-04/11/36 with the **broken 3-arg ppe-11** (see §5). Kept for history only. |
| `e8450-custom-sdk-patches` | origin `71d5d16c3f` | The original **327-patch SDK bundle** (176 SDK-only vs vanilla). Reference for patch bodies; **do not build/flash** (WED bundle breaks the box). |

Repo: `github.com/pattyboi/openwrt` (all three pushed).

---

## 3. Applied set on `e8450-hw-driven` (7 patches) — what & why

All GNU-`patch` verified fuzz≤2 against real source; all compiled & (except eth-07)
flashed+validated.

| Patch | Effect | Status |
|---|---|---|
| `999-ppe-04` internal QoS mode | Core PPPQ: writes per-DSA-port queue-id into FOE `ib2` (`queue = 3 + dsa_port`), sets PSE_QOS | **validated in HW** |
| `999-ppe-36` enable PPPQ netsysv1 | Sets `eth->qos_toggle=2` at probe; dmesg `PPPQ QoS mode enabled` | **validated** |
| `999-ppe-11` TCP-ACK → high queue | Re-adapted to real **4-arg** `mtk_flow_entry_match`; small TCP-ACKs `queue+=6`. Guarded `IS_REACHABLE(CONFIG_NF_CONNTRACK)` | **FUNCTIONAL + HW-VALIDATED** (QID 9=3+6 observed) with conntrack builtin (§5d) |
| **config: `CONFIG_NF_CONNTRACK=y`** (target/linux/mediatek/config-6.12) | Builds conntrack into vmlinux → TCP-ACK guard flips true (§5d) | **default, commit b80f868961** |
| **`files/etc/sysctl.d/30-mediatek-ppe.conf`** | `net.netfilter.nf_conntrack_acct=1` by default → ACK heuristic gets counters | default (build9) |
| `999-ppe-10` MIB-cache typo | Fixes a real vanilla bug (`MTK_PPE_MIB_CFG_RD_CLR`→`_CACHE_CTL_EN`); perf under accounting | applied |
| `999-eth-91` MT7622 RX ring | RX DMA ring 512→1024 (`MTK_DMA_SIZE(1K)`), mt7622-anchored | applied |
| `999-zz` lookup prefetch | Prefetch next entry `->data` in `__mtk_ppe_check_skb` (pre-offload SW window; the one genuinely per-packet spot) | applied |
| `999-eth-07` napi_enable panic fix | Reorders `register_netdev` after `netif_napi_add`; boot-race hardening. SoC-agnostic | **built (build7), NOT flashed** |

**Flash state:** router now runs **build9** (`sha256 1f9e771bd5…`, = `~/staging/
latest-image/`): all 7 patches + eth-07 + **conntrack builtin + TCP-ACK
functional-by-default** — flashed & HW-validated 2026-07-02 (PPPQ + PPE hw-NAT +
TCP-ACK queue+6 all confirmed live; WED off; clean boot). Prior images (build5
`80f1ff462c`, build7 `8f763f7344`, build8 `167199fe37`) are superseded.

---

## 4. CONFIRMED WORKING (hardware-validated 2026-07-02)

Test rig: netns+macvlan LAN client (192.168.1.50 on macvlan over enp1s0) →
E8450 NAT → http server on build-host wlp2s0 (192.168.3.12 = E8450's WAN side).
Real forwarded LAN→WAN NAT flow through the router. (Firewall needs
`flow_offloading` + `flow_offloading_hw=1`; the `-n` default has them OFF.)

- **PPE hardware NAT offload:** flows go **`BND`** (bound) both directions, NAT +
  MAC rewrite in silicon, packet/byte counters climbing (CPU out of datapath).
- **PPPQ queue assignment:** `ib2` decode (V1 masks `QID=GENMASK(3,0)`,
  `PSE_QOS=BIT(4)`): LAN-egress **QID=3** (dsa_port 0), WAN-egress **QID=7**
  (dsa_port 4=wan), `PSE_QOS=1` both → `queue = 3 + dsa_port` live in hardware.
- Clean boot, no traces, Wi-Fi up, stable, WED off.

This reproduces the SDK build's real MT7622 value (core PPPQ + hw-NAT) on a clean
mainline base, minus the WED fault and 169 unused SDK patches.

---

## 5. RULED OUT — findings that constrain future work

### 5a. WED is OFF THE TABLE (empirically, both mainline & SDK)
On the **live stock 25.12.4** image, `mt7915e wed_enable=Y` + PCI unbind/rebind
**hard-faulted** the box (ethernet dropped, LED dark, unreachable; the 31s `mtk-wdt`
did **not** recover it → manual power cycle). **Same failure as the SDK build** →
it's a mainline mt7915/MT7622 driver/HW problem, NOT SDK-induced. The vanilla DTS
wifi node has no `mediatek,wed` phandle yet `wed_enable` alone still triggers the
faulting attach (WED resolved via hif/PCIe path, not the wifi node). **Do not apply
any `wed-*` patch; do not enable `wed_enable`.**

### 5b. ppe-11 3-arg vs 4-arg (why mainline-pppq is superseded)
Real 25.12.4 `mtk_flow_entry_match` is **4-arg** `(eth, entry, data, len)` with a
separate `mtk_flow_entry_match_len`. The old adaptation (on `e8450-mainline-pppq`)
assumed a nonexistent 3-arg form → wouldn't apply/compile. hw-driven's ppe-11
un-statics both funcs, declares them in mtk_ppe.h, and detects v4/v6 via
`nf_ct_l3num` (avoids static `mtk_get_ib1_pkt_type`).

### 5c. CLAUDE.md PPE micro-opts are MOOT on mainline
- **DSA-port cache** ("highest priority"): mainline `dsa_port_from_netdev()` is
  already **O(1)** (ops-ptr check + `netdev_priv->dp`). No chain walk. And it runs
  **once per flow at offload setup**, not per packet — offloaded flows forward in
  hardware. A cache = pure risk, zero gain.
- **Eligibility / IPv4-only fast-paths:** `CONFIG_IPV6=y` (WAN uses DHCPv6) →
  IPv4-only guard DCEs nothing; the IPsec/bridge-nf exits it describes aren't in
  the mainline offload path. Moot.
- The only *real* CLAUDE.md opts (DMA ring, prefetch) are already in (eth-91, zz).

### 5d. conntrack-builtin — SOLVED (2026-07-02, commit b80f868961)
**This unblocks functional TCP-ACK (and the whole DSCP-qos class).** The correct
lever is NOT `NF_KMOD` (that's a "is-conntrack-a-kmod-package" switch — empty just
*removes* it → disabled → build broke). The real lever is the **kernel config
symbol** `CONFIG_NF_CONNTRACK=y`, set persistently in
`target/linux/mediatek/config-6.12` (the `kernel_menuconfig` equivalent). It
**overrides the kmod `=m` cleanly**; kmod-nf-conntrack becomes a builtin/empty
package (now carries only `nf_defrag_ipv4/6.ko`), `nf_conntrack` goes into vmlinux.
`NF_FLOW_TABLE`/`NF_NAT` stay `=m` (modules can call builtin symbols — fine).
Result: `__nf_ct_ext_find` is linkable from the built-in `mtk_eth_soc`, so
ppe-11's `IS_REACHABLE(CONFIG_NF_CONNTRACK)` guard flips **true** and TCP-ACK
`queue+6` compiles in. Accounting (`nf_conntrack_acct.o`) is compiled into
conntrack unconditionally; enabled at runtime by `net.netfilter.nf_conntrack_acct=1`
(baked in via `files/etc/sysctl.d/30-mediatek-ppe.conf`). Cost: slightly larger
vmlinux, conntrack no longer modular. Core PPPQ + hw-NAT unaffected.
**Status: HW-VALIDATED (2026-07-02, build9 flashed).** Under an ACK-heavy download
through the E8450, the offloaded flow's LAN-egress entry showed **QID=9 = base 3 +
6** (`ib2=007c0439`, PSE_QOS=1) vs the build5 baseline of 3 — the `queue+6` bump
fires, programmed into hardware. `nf_conntrack_acct=1` confirmed set by default,
`nf_conntrack` confirmed builtin (not a module). Clean boot, WED off, stable. (The
bump lands on the LAN-egress direction per the SDK's get_ct_dir mapping, not WAN —
a heuristic detail, not an enablement issue.)

### 5e. DSCP-qos class — BUILT, FLASHED, LIVE ON HARDWARE (2026-07-02)
Two patches added on `e8450-hw-driven` (commit `3864949077`) and flashed:
- **`999-ppe-12`** (= SDK ppe-05) — the frontend-agnostic apply/consume half:
  `nf_conntrack_qos` ct-extension + core flowtable `tos` plumbing +
  `mtk_foe_entry_set_dscp()` writing DSCP into FOE **`ib2[31:24]`**
  (`MTK_FOE_IB2_DSCP`, netsysv1 layout, distinct from ppe-04 QID/PSE_QOS bits).
  **Renumbered 05→12 to apply AFTER ppe-11**: both edit
  `mtk_flow_set_output_device()`; ppe-05-before-ppe-11 breaks ppe-11's hunk#1
  context (`,int dscp` added to the signature). Clean-build order = **C-locale
  numeric filename sort** (NOT the build_dir apply order a dry-run on the
  finished tree shows). A `11a` letter suffix is ambiguous (locale collation
  ignores `-`); a numeric bump is not.
- **`999-ppe-17`** — the nft-path learn/seed (`nft_flow_offload.c`). This box is
  fw4/nftables so the `xt_FLOWOFFLOAD` twin never runs; ppe-17 is mandatory.
  Re-adapted to real 6.12.87 `nft_flow_offload_eval()`: `dir` hoisted above the
  qos block, `nft_flow_route()` path (no is_bridging), and `#include
  <net/dsfield.h>` added for `ipv6_get_dsfield()` (not otherwise reachable;
  `CONFIG_IPV6=y`).

**HW-confirmed live** (SSH, fresh boot, stable, WED off, pstore empty):
`/proc/sys/net/netfilter/nf_conntrack_qos` = **3** (on by default); every
`/proc/net/nf_conntrack` line now carries a `tos=` field (the `seq_print_qos`
from ppe-12 → qos ext is attached); nft `flowtable ft { flags offload }` on
lan1-4+wan is the active offload path (ppe-17 hook). **Not yet observed:** a
*nonzero* DSCP in a **bound** FOE entry — needs sustained DSCP-marked transit
traffic from a LAN client (same style as the TCP-ACK QID=9 test), not
router-originated traffic (locally-terminated flows show `UNB`, never offload).

**PPE FOE inspection tooling (for that validation):** `/sys/kernel/debug/ppe0/`
has `bind` and `entries`. Entry line format:
`<idx> <BIND|UNB> IPv4 5T orig=.. new=.. eth=.. ib1=<hex> ib2=<hex> packets=.. bytes=..`.
Decode the top byte of `ib2` for DSCP (`ib2[31:24]`), low nibble region for QID.
LAN topology seen live: mgmt `192.168.1.1`, admin host `.254`, a downstream
client subnet `192.168.3.0/24` (e.g. `192.168.3.15`) that generates real transit
flows — the place to drive a DSCP-marked test.

---

## 6. THE GATING WALL — conntrack modularity

`CONFIG_NF_CONNTRACK=m` but `CONFIG_NET_MEDIATEK_SOC=y` (built-in). A built-in
driver **cannot link** module-exported conntrack symbols (`__nf_ct_ext_find` via
`nf_conn_acct_find`/`nf_conn_qos_find`). So any feature that reads conntrack
extensions from the eth driver is either **compiled out** (our `IS_REACHABLE`
guard → returns false) or **won't link**. This gates:
- **TCP-ACK prioritization** (ppe-11's `queue+=6`) — present but **inert**.
- **All DSCP/conntrack-qos** SDK patches (ppe-05/17/23/26/27, eth-27, ppe-35).

The SDK build hit the exact same wall (commit `7d39162e` used IS_REACHABLE guards;
its own `0fd28370` admits ACK detection "silently never fires"). **So these were
inert on the SDK too** — the SDK's shipped MT7622 value was core PPPQ + hw-NAT.

**UPDATE (§5d, commit b80f868961): the wall is now BROKEN.** `CONFIG_NF_CONNTRACK=y`
makes conntrack builtin → `__nf_ct_ext_find` linkable → the IS_REACHABLE guards
flip true. **TCP-ACK is now functional-by-default** (with the acct sysctl baked
in). This goes BEYOND what the SDK ever shipped functional on MT7622. The
DSCP/conntrack-qos class is likewise **no longer gated** — see §7.

---

## 7. Guidance for the NEXT patch investigation

Given §1–§6, the remaining SDK-only patch space (176 patches, per PHASE3 doc)
breaks down as:

- **Dead on v1 / wrong SoC:** ~all `eth-*` v2/v3, `ppe-09/20/22`, ephy/sfp/pcs/
  lvts/gen3-pcie/xgmac/usxgmii, spi-nor/CASN, dsa-an8855/mxl862. Nothing to gain.
- **WED bundle:** off the table (§5a). All `wed-*`, `94x-mtk_wed`, `198-dts-wed`.
- **iptables (`xt_FLOWOFFLOAD`) variants:** dead (box is nftables). Only `nft_`
  twins could ever matter.
- **DSCP / conntrack-qos class — NOW UNBLOCKED (§5d done):** with conntrack
  builtin these can link & function. **This is the clear next target** if more QoS
  is wanted: `ppe-05` (nf_conntrack_qos ext + DSCP learning — the foundation; also
  needs `net.netfilter.nf_conntrack_qos=1`), then consumers `ppe-17/23/27` (nft
  DSCP learning / keep-dscp / vlan-egress-qos) and `eth-27` (skb-mark→queue);
  `ppe-35` (conntrack-ext IS_REACHABLE) may be a build prereq. Expect the same
  4-arg / real-source re-adaptation ppe-11 needed — read against build_dir.
- **Genuinely applicable & not-yet-taken (non-qos):** `eth-07` (done); possibly
  `wdt-01` (trivial clamp, ~0 value).

**Bottom line for next session:** core value (PPPQ + hw-NAT) is done & HW-proven;
**TCP-ACK is now functional-by-default** (built, pending HW validation). The
netfilter-builtin wall that gated the QoS-conntrack class is **broken** (§5d), so
the **highest-value remaining thread is the DSCP-qos class** (start at `ppe-05`).
Otherwise SDK mining stays low-yield (dead-on-v1, WED-dependent, or redundant with
mainline). Don't re-mine the bulk set; start from the PHASE3 verdicts + this
summary. Reserve the higher-risk driver patches (ppe-14 cache, ppe-08 roam,
eth-18/19 link-flap) for a *specific measured symptom*.
