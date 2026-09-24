#
# WRT2JB -- PS4 jailbreak host: serve the RAW GAME chain (raw13g / "mansoor0x") from the router.
#
# The console opens http://<router>:8000/ in its browser and the page runs the chain and
# installs GoldHEN.  A second uhttpd instance serves it, so LuCI's instance on :80 is not
# touched.  What this package changes about the upstream tree, why, and full credits/
# attribution for the third-party content it serves are in README.md.
#
include $(TOPDIR)/rules.mk

PKG_NAME:=wrt2jb
PKG_VERSION:=2026.09.22
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/raw13g/raw13g.github.io.git
PKG_SOURCE_VERSION:=ef1670a8db0beb49b942dfacced6edbc5225f47c
PKG_SOURCE_DATE:=2026-09-22
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=pattyboi

include $(INCLUDE_DIR)/package.mk

# The payload the LuCI binload control (luci-app-wrt2jb) pushes to the console: ps4debug-NG
# v1.3.2 (GPL-3.0, https://github.com/Pharaoh2k/ps4debug-NG), hash-pinned to the release
# asset.  Not vendored into this tree -- 3.1 MB of binary that upstream publishes and
# hashes itself.
define Download/ps4debug
  FILE:=ps4debug-ng_v1.3.2_release_2026-09-20.bin
  URL:=https://github.com/Pharaoh2k/ps4debug-NG/releases/download/1.3.2
  HASH:=28829f48465d3dfdf97afc15f01edafd8802f8213c44635af6f21e0e8b48c8f6
endef
$(eval $(call Download,ps4debug))

define Package/wrt2jb
  SECTION:=net
  CATEGORY:=Network
  TITLE:=WRT2JB -- PS4 jailbreak host (RAW GAME chain + GoldHEN)
  URL:=https://github.com/raw13g/raw13g.github.io
  DEPENDS:=+uhttpd
  PKGARCH:=all
endef

define Package/wrt2jb/description
  Serves the RAW GAME browser chain from the router on port 8000, so a PS4 on the LAN can
  be jailbroken with GoldHEN without a PC and without internet access.  The chain's stage
  log is captured at POST /t and shown at http://<router>:8000/t.

  Also installs the binload mechanism (usr/libexec/wrt2jb/binload, the ps4debug-NG payload)
  that luci-app-wrt2jb drives: it hands a payload to a console's GoldHEN PayLoader.
endef

define Package/wrt2jb/conffiles
/etc/config/wrt2jb
endef

# Everything the chain fetches, except the two payload blobs (see below).
WRT2JB_ASSETS:=index.html jb.html jb.js core.js mem.js int64.js rpc_worker.js ps4_offsets.js logo_raw.png
WRT2JB_PATCHES:=1302 1350 1352

ifneq ($(WRT2JB_PAYLOAD),)
# Advanced: serve a payload we built instead of the one upstream ships, e.g.
#   make package/wrt2jb/compile WRT2JB_PAYLOAD=/mnt/.../payload_kdump.bin
# It is installed under both names the chain may ask for.
define Package/wrt2jb/install-payload
	$(INSTALL_DATA) $(WRT2JB_PAYLOAD) $(1)/www/wrt2jb/goldhen.bin
	$(INSTALL_DATA) $(WRT2JB_PAYLOAD) $(1)/www/wrt2jb/payload2.bin
endef
else
define Package/wrt2jb/install-payload
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/goldhen.bin $(1)/www/wrt2jb/goldhen.bin
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/payload2.bin $(1)/www/wrt2jb/payload2.bin
endef
endif

# Nothing to compile: the source tree is the artifact.  Without this, the default
# Build/Compile runs make in a directory that has no Makefile.
define Build/Compile
endef

# The served tree is upstream's, minus the AppCache (patches/001) and minus cache.appcache,
# which is never installed.  Both halves of that removal are deliberate: a served chain that
# keeps its cache manifest makes the console run a stale jb.js and a stale payload, which is
# a measured failure, not tidiness -- see README.md.
define Package/wrt2jb/install
	$(INSTALL_DIR) $(1)/www/wrt2jb/patches
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	for f in $(WRT2JB_ASSETS); do \
		$(INSTALL_DATA) $(PKG_BUILD_DIR)/$$$$f $(1)/www/wrt2jb/$$$$f || exit 1; \
	done
	for f in $(WRT2JB_PATCHES); do \
		$(INSTALL_DATA) $(PKG_BUILD_DIR)/patches/$$$$f.bin $(1)/www/wrt2jb/patches/$$$$f.bin || exit 1; \
	done
	$(call Package/wrt2jb/install-payload,$(1))
	$(INSTALL_BIN) ./files/www/wrt2jb/t $(1)/www/wrt2jb/t
	$(INSTALL_BIN) ./files/etc/uci-defaults/50-wrt2jb $(1)/etc/uci-defaults/50-wrt2jb
	$(INSTALL_DIR) $(1)/usr/libexec/wrt2jb
	$(INSTALL_BIN) ./files/usr/libexec/wrt2jb/binload $(1)/usr/libexec/wrt2jb/binload
	$(INSTALL_DIR) $(1)/usr/share/wrt2jb/payloads
	$(INSTALL_DATA) $(DL_DIR)/ps4debug-ng_v1.3.2_release_2026-09-20.bin \
		$(1)/usr/share/wrt2jb/payloads/ps4debug-ng_v1.3.2_release_2026-09-20.bin
	# what each payload is, so the status page can say whether the file it is about to
	# push is the one this package was built against
	( \
		cd $(1)/usr/share/wrt2jb/payloads && for f in *; do \
			[ -f "$$$$f" ] || continue; \
			[ "$$$$f" = MANIFEST ] && continue; \
			echo "sha256 $$$$(sha256sum "$$$$f" | cut -d' ' -f1) $$$$f"; \
		done \
	) > $(1)/usr/share/wrt2jb/payloads/MANIFEST
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/wrt2jb $(1)/etc/config/wrt2jb
	( \
		echo "package wrt2jb $(PKG_VERSION)-$(PKG_RELEASE)"; \
		echo "source https://github.com/raw13g/raw13g.github.io"; \
		echo "source_revision $(PKG_SOURCE_VERSION)"; \
		echo "source_date $(PKG_SOURCE_DATE)"; \
		cd $(1)/www/wrt2jb && for f in $(WRT2JB_ASSETS) patches/1302.bin patches/1350.bin patches/1352.bin goldhen.bin payload2.bin; do \
			[ -f "$$$$f" ] || continue; \
			echo "sha256 $$$$(sha256sum "$$$$f" | cut -d' ' -f1) $$$$f"; \
		done \
	) > $(1)/www/wrt2jb/MANIFEST
endef

$(eval $(call BuildPackage,wrt2jb))
