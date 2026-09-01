# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=qdma-shaper
PKG_VERSION:=1
PKG_RELEASE:=2

PKG_MAINTAINER:=OpenWrt E8450 investigation <noreply@example.invalid>
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/qdma-shaper
  SECTION:=net
  CATEGORY:=Network
  TITLE:=MediaTek NETSYSv1 QDMA WAN queue shaper (experimental)
  DEPENDS:=@TARGET_mediatek_mt7622
  PKGARCH:=all
endef

define Package/qdma-shaper/description
  Experimental board- and DSA-aware control for the qos-03 NETSYSv1 QDMA
  per-queue max-rate override on MT7622. Sets a single upload cap on the WAN
  egress queue via the mtk_eth_soc debugfs qdma_rate interface, with
  fail-closed identity and readback checks. Upload-only token bucket; not an
  AQM and does not shape download.
endef

define Package/qdma-shaper/conffiles
/etc/config/qdma-shaper
endef

Build/Prepare:=:
Build/Configure:=:
Build/Compile:=:

define Package/qdma-shaper/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/etc/init.d $(1)/etc/config $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./files/qdma-shaper.sh $(1)/usr/sbin/qdma-shaper
	$(INSTALL_BIN) ./files/qdma-shaper.init $(1)/etc/init.d/qdma-shaper
	$(INSTALL_CONF) ./files/qdma-shaper.config $(1)/etc/config/qdma-shaper
	$(INSTALL_DATA) ./files/qdma-shaper.hotplug $(1)/etc/hotplug.d/iface/30-qdma-shaper
endef

$(eval $(call BuildPackage,qdma-shaper))
