# Phase 3 — SDK Patch Compatibility Verdicts (hardware-evidence driven)

Board: **Linksys E8450 (UBI)** · SoC **MediaTek MT7622** (NETSYSv1, WED v1) ·
kernel 6.12.87 · OpenWrt 25.12.4 vanilla baseline (`ba915c2ee7`).

Verdicts derived **only** from the hardware profile captured in Phase 2
(`/home/pat/staging/router-hw-profile/`). 176 SDK-only patches evaluated
(SDK set 327 − vanilla 151 = 176 added by the SDK bundle).

## Decisive hardware evidence (the axes that settle most verdicts)

| Fact | Evidence (saved profile) | Kills these patch classes |
|---|---|---|
| SoC = MT7622, NETSYSv1 | `compatible = mediatek,mt7622`; FE at `1b100000.ethernet` (v1 base, not `15100000`) | all MT7986/7987/7988/NETSYSv2-3 code |
| WED = v1 (2 units) | `1020a000.wed` + `1020b000.wed`; wed0/wed1 debugfs | RRO, HW-AMSDU, MLO (all v2+) |
| No 10G / XGMAC / USXGMII | no XGMAC/USXGMII/xfi/2500base-x-autoneg in iomem+dmesg; only `1b100000` GMAC | XGMAC, USXGMII, pcs-usxgmii |
| CPU port = fixed 2500base-x → MT7531 | dmesg `configuring for fixed/2500base-x`, `Link is Up 2.5Gbps/Full` | SerDes/pextp/phya tuning, polarity fixes |
| DSA = MT7531 only | dmesg `MediaTek MT7531 PHY` ×5 on `mdio-bus:1f` | AN8855, MXL862, MT7988 int-GSW |
| PHYs = MT7531 internal GbE only | no aqr/an88xx/as21xxx/en8811/gpy/i2p5g in dmesg/mdio | all `ephy-*` |
| No SFP cage | no sfp/sfp-bus in dmesg | all `sfp-*` |
| Thermal = mtk-thermal | `1100b000.thermal` (not lvts) | `lvts-*` |
| PCIe = gen2 mtk-pcie | `1a143000.pcie`/`1a145000.pcie` (not gen3 controller) | `pcie-*` (gen3 driver) |
| No crypto engine | no crypto/safexcel/eip19x block in iomem/dmesg | `crypto-*`, all xfrm/IPsec offload |
| Flash = SPI-NAND only | `/proc/mtd` bl2+ubi; Winbond mtk-snand | `spi-nor-*` |
| Firewall = **nftables (fw4)** | `nft_flow_offload` loaded; **zero** xt_FLOWOFFLOAD/iptables | **all `xt_FLOWOFFLOAD` patches** |
| Single-image UBI boot | dmesg normal `ubi0:5(fit)` boot, no dual-boot infra | `dual-boot-*`, `fitblk-*` |
| RNG = mtk-rng @1020f000 | dmesg `mtk_rng 1020f000.rng: registered` | `trng-02` (removes v1 cfg → would break RNG) |

**Goal reminder:** keep working WED v1 + PPE hw-NAT (both already present in
vanilla), and add **PPPQ QoS**. Optional: DSCP classification / per-queue shaping.

---

## APPLY (hardware present + relevant to goal)

| Patch | Rationale / evidence |
|---|---|
| `999-eth-91-mt7622-rx-dma-ring-1024` | **MT7622-named**; doubles RX DMA ring 512→1024. Matches CLAUDE.md DMA-ring-sizing objective. Board is MT7622. |
| `999-ppe-04-...internal-QoS-mode` | Core PPPQ: writes queue-id into FOE ib2. Already adapted to mainline (`e8450-mainline-pppq`). |
| `999-ppe-11-...dispatch-short-packets-high-priority` | PPPQ TCP-ACK prioritization (queue+=6). Already adapted. |
| `999-ppe-36-...enable-pppq-by-default-for-netsysv1` | **NETSYSv1-named** — explicitly our SoC. Sets `qos_toggle=2`. Already adapted. |
| `999-ppe-37-...offload-enabled-printk` | Diagnostic printk; restores the dmesg offload confirmation the SDK build had. Harmless. |
| `999-ppe-33-...fix-mtk_eth_offload_init-memory-leak` | Real memleak fix in offload init path that runs on v1. |
| `999-ppe-10-...fix-typo-for-enabling-MIB-cache` | Trivial correctness fix in `mtk_ppe.c`, v1-relevant. |
| `999-zz-mtk_ppe-prefetch-flow-lookup` | Our own lookup-hotpath prefetch (prior session). Low risk, v1 path. |

---

## INVESTIGATE (touches shared driver code that DOES run on MT7622 — read diff before deciding)

### PPPQ / DSCP-classification candidates (relevant to optional goals)
| Patch | Question to resolve |
|---|---|
| `999-ppe-03-keep-sp-in-info1` | Does PPPQ DSA-port queue mapping need the source-port field kept? Small FOE change. |
| `999-ppe-17-nft_flow_offload-DSCP-learning-flow` | DSCP classification (nft path). Needs conntrack_qos infra — check dependency chain. |
| `999-ppe-23-mtk_ppe-add-keep-dscp-toggle` | DSCP preserve toggle; pairs with ppe-17. |
| `999-ppe-27-nft_flow_offload-vlan-egress-qos-learning` | Per-VLAN egress QoS (nft). Only if VLAN-tagged WAN QoS wanted. |
| `999-ppe-35-...IS_REACHABLE-guards-conntrack-ext` | Likely a build-prereq for the conntrack_qos ext used by DSCP patches. |
| `999-eth-27-mtk_eth_soc-add-skb-mark-support-for-qos` | skb->mark → queue. Needed for mark-based classification. |
| `999-ppe-15-nft_flow_offload-bridging-support` | nft bridge offload — verify vs mainline's existing bridge offload (may be redundant). |
| `999-ppe-16-nft_flow_offload-DEV_PATH_MTK_WDMA` | WDMA path for **WED** offload via nft — relevant if driving WED through flowtable. |
| `999-ppe-19-nft_flow_offload-memory-leak-fix` | Pairs with nft offload patches if any nft patch is taken. |
| `999-ppe-24-nft_flow_offload-vlan-passthrough` | VLAN passthrough offload (nft). |
| `999-ppe-08-mtk_ppe-add-roaming-handler` | Wi-Fi roam → FOE flush. Correctness for WiFi offload; verify v1-safe. |
| `999-ppe-09-enable-CS0_PIPE-and-SRH_CACHE_FIRST` | PPE cache/pipe tuning — confirm v1 register-safe (touches ppe_regs). |
| `999-ppe-14-add-PPE-cache-preserved-line-lock` | Cache line lock — confirm v1-safe. |

### WED v1 (see strategic note — may be unnecessary on mainline)
| Patch | Question |
|---|---|
| `999-wed-02-refactor-mtk_wed_assign-not-base-on-pci-domain` | Plan Group-3 known fix. Confirm still needed vs mainline WED. |
| `999-wed-10-add-mt7987-hwpath-support` | Plan lists as known fix, but subject = MT7987. **Reconcile**: which hunks touch shared v1 code vs MT7987-only? |
| `999-wed-13-add-WDMA-disable-flow-to-WiFi-L` | Plan Group-3 known fix. Confirm v1 relevance. |
| `999-wed-04-fix-reinsert-wifi-module-memleak` | Relevant — we reload mt7915e (wed-toggle). Verify v1. |
| `999-wed-14-refactor-mtk_wed_irq_get` | IRQ status false-positive fix — near the attach/crash surface. |
| `999-wed-16-refactor-wdma-init-avoid-double-init` | WDMA init ordering — attach surface. |
| `999-wed-03-fix-wdma-rx-hang-on-wed1-after-SER` | wed1 SER recovery; v1 has wed1. Verify guard. |
| `999-wed-07-mtk-wed-add-hwpath-wmm-support` | CLAUDE.md: verify v1-compatible vs v2+. |
| `999-wed-11-net-ethernet-mtk_wed-add-ppe-drop` | PPE-drop feature; verify v1. |

### Ethernet core (verify NETSYSv1 applicability)
| Patch | Question |
|---|---|
| `999-eth-07-fix-panic-with-napi_enable` | CLAUDE.md-flagged NAPI/IRQ-ordering fix. Read fully — may be a genuine v1 fix. |
| `999-eth-10-add-hw-lro-support` + `999-eth-08` (regs) + `999-eth-16` (GLO_MEM) + `999-eth-35` (learning info) | MT7622 **has** `MTK_HWLRO` cap. Determine if SDK HW-LRO improves on mainline or duplicates it. |
| `999-eth-18-refactor-PSE-PPE-port-link-down` + `999-eth-19` | PPE port link-down handling — offload-correctness; verify v1 register scope. |
| `999-eth-90-support-proprietary-debugfs` (mtk_eth_dbg) | SDK diagnostic debugfs — useful for offload bring-up, but proprietary. Optional. |
| `999-wdt-01-add-clamp-to-set-timeout` | mtk_wdt (we use it). Low-risk safety clamp. |

---

## SKIP (hardware absent / wrong SoC gen / wrong subsystem — with evidence)

**Firewall backend mismatch — box is nftables/fw4 (evidence: `nft_flow_offload`
loaded, no `xt_FLOWOFFLOAD`):**
`ppe-01, ppe-05, ppe-06, ppe-18, ppe-21, ppe-25, ppe-26, ppe-30` — all
`xt_FLOWOFFLOAD` (iptables/fw3). Dead on this box. *(Note: ppe-05/26 also carry
conntrack_qos core infra needed by DSCP — if DSCP is pursued, cherry-pick only
the conntrack_qos hunks, not the xt_ hunks.)*

**No crypto engine (evidence: no crypto block in iomem/dmesg):**
`crypto-01..05`, `ppe-29, ppe-30, ppe-31, ppe-32` (xfrm/IPsec HW offload),
`eth-39` (crypto tx).

**NETSYSv2/v3 / MT7987 / MT7988 only (evidence: SoC=mt7622, no XGMAC/USXGMII):**
`eth-02, eth-03, eth-06, eth-13, eth-14, eth-15, eth-22, eth-23, eth-24, eth-25,
eth-28, eth-36, eth-37, eth-38`, `ppe-20` (adaptive PPPQ needs NETSYSv3 shaper),
`ppe-22` (MT7988 tport_idx), `eth-26` (PPPQ-in-qdma_shaper — shaper is v3),
`dts-06` (mt7988a).

**SER/forced-reset chain (not needed — baseline stable, no SER events):**
`eth-04, eth-05, eth-11, eth-32`. *(Revisit only if instability observed.)*

**Tuning not required for goal (revisit only if a specific need appears):**
`eth-12` (EEE), `eth-17` (napi weight 256), `eth-29` (tx-full counter),
`eth-30, eth-33` (rx buffer tuning), `eth-31` (9k jumbo), `ppe-12` (aging —
CLAUDE.md: do **not** touch aging/GC), `ppe-13` (ib2 mcast bit — FOE risk).

**Wrong PHY / no such PHY (evidence: only MT7531 internal GbE PHYs):**
all `ephy-*` (an8801sb, an8811hb, aqr113c×3, as21xxx, cux3410, en8811h, gbe-01/02,
gpy211, i2p5g), `sfp-01..07`, `pcs-01..08` (SGMII links fine at 2.5G without them),
`eth-01` + `dsa-01` (SGMII polarity — link already correct).

**Wrong switch (evidence: DSA=MT7531):** `dsa-03` (an8855), `dsa-04, dsa-05`
(mxl862), `ppe-28` (mxl862 tag offload), `gsw-02` (an8855). `gsw-01` (mt7531 gsw
swconfig driver) — SKIP: box uses standard DSA (`swconfig list` → none).
`dsa-02` (mt7531 netlink app) — SKIP: no swconfig app.

**Wrong controller/subsystem (evidence cited inline):**
`lvts-01/02` (thermal=mtk-thermal not lvts), `pcie-01..04` (gen3 driver; ours is
gen2), `tphy-01` (PCIe 2-lane; ours single-lane) `tphy-02/03` (USB SSC tuning;
USB works), `spi-nor-01/02` (no NOR flash), `spi-nand-01/02/03` (CASN — Winbond
128MiB works with std addressing), `spi-01`, `spi-mt65xx-01`, `xHCI-01/02/03`
(USB works; compliance/OTG toolkits), `i2c-01/02` (zts pressure sensors absent),
`pwm-02` (unused), `trng-02` (**would disable our working RNG**).

**Tunnel HW offload (not a stated goal; PPE v1 tunnel-offload support unverified):**
`tnl-01..06, tnl-90`, `hnat-10` (l2tp tnl check). Revisit only if PPTP/L2TP/GRE
**hardware** offload is explicitly wanted (SW modules already load fine).

**HNAT netfilter glue — mainline already offloads DSA/bridge/VLAN/PPPoE:**
`hnat-03..11`. Mainline `mtk_ppe_offload.c` + nf_flow_table already resolves
DEV_PATH for DSA/bridge/pppoe. SKIP to avoid re-introducing SDK offload framework
that conflicts with the working mainline path. *(hnat-06 PPPoE / hnat-07 DSA →
promote to INVESTIGATE only if a PPPoE-WAN offload gap is measured.)*

**SDK-proprietary / debug scaffolding:**
`ppe-02` (internal ppe debugfs — mainline debugfs works, ppe0 present),
`ppe-07` (ftnetlink SDK app), `wed-08` (extended wed debugfs — verify not v2/v3),
`wed-17` (our staged-attach debug gate — SDK-crash tool, not for mainline).

**Dead on v1 (v2+ features):** `wed-05` (MLO/Wi-Fi7 — MT7915E is Wi-Fi6),
`wed-09` (RRO_RX_D_DRV — RRO is v2+), `wed-15` (HW-AMSDU init — v2+),
`wed-01` (HWRRO double-free — RRO is v2+; SKIP unless it also touches v1 SER).

---

## Strategic note — WED patches may be unnecessary under the mainline strategy

The Phase-4 Group-3 instruction (apply wed-02/10/13 first) originates from the
**old** strategy of fixing the SDK's broken WED. Under the **new** mainline
strategy, vanilla OpenWrt 25.12.4 already ships working WED v1
(`940/942/943/944-net-ethernet-mtk_wed-*`, `wed0`/`wed1` debugfs bind on this
box). **Recommendation:** flash the vanilla baseline and test mainline WED
attach *as-is* (mt7915e `wed_enable` + PCI rebind) **before** applying any SDK
`wed-*` patch. Only add wed patches if mainline WED demonstrably fails on this
hardware — otherwise we risk re-importing the exact breakage we left the SDK to
escape.

## Suggested minimal first build (Phase 4 Group 2, PPPQ only)
`ppe-04` + `ppe-11` + `ppe-36` (already adapted on `e8450-mainline-pppq`) +
`ppe-37` (printk) + `ppe-33` (memleak) + `ppe-10` (typo) + `eth-91` (RX ring).
Build → flash → confirm `dmesg | grep -i "PPPQ\|offload"` and that WED still
attaches, before touching DSCP/shaping or any wed-*.
