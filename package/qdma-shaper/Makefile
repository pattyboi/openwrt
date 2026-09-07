# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=qdma-shaper
PKG_VERSION:=1
PKG_RELEASE:=3

PKG_MAINTAINER:=OpenWrt E8450 investigation <noreply@example.invalid>
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/qdma-shaper
  SECTION:=net
  CATEGORY:=Network
  TITLE:=MediaTek NETSYSv1 QDMA WAN queue shaper
  DEPENDS:=@TARGET_mediatek_mt7622
  PKGARCH:=all
endef

define Package/qdma-shaper/description
  Board- and DSA-aware control for the NETSYSv1 QDMA per-queue max-rate,
  PPPQ, and HQoS overrides on MT7622. Caps WAN egress with a hardware token
  bucket while keeping each DSA egress direction on its native port queue.
  Includes fail-closed identity and readback checks. CAKE handles traffic that
  does not enter the hardware flow-offload path.
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
