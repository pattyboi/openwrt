# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=sqm-autorate-rust
PKG_VERSION:=0.4.1
PKG_RELEASE:=3

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/Lochnair/sqm-autorate-rust
PKG_SOURCE_VERSION:=33169182be8cc8ca9d3c7edb4791b1407641abe3
PKG_MAINTAINER:=Nils Andreas Svee <me@lochnair.net>
PKG_LICENSE:=MPL-2.0
PKG_BUILD_DEPENDS:=rust/host
RUST_PKG_FEATURES:=uci

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/rust/rust-package.mk

CARGO_PKG_VARS += UCI_DIR=$(STAGING_DIR)/usr \
	LIBCLANG_PATH=$(STAGING_DIR_HOST)/llvm-bpf/lib \
	BINDGEN_EXTRA_CLANG_ARGS="-I$(STAGING_DIR)/usr/include --sysroot=$(TOOLCHAIN_DIR)"

define Build/Compile
	$(call Build/Compile/Cargo,,)
endef

define Package/sqm-autorate-rust
	SECTION:=utils
	CATEGORY:=Utilities
	TITLE:=Adaptive CAKE rate controller
	DEPENDS:=$(RUST_ARCH_DEPENDS) +libuci
	URL:=https://github.com/Lochnair/sqm-autorate-rust
endef

define Package/sqm-autorate-rust/description
	Rust adaptive CAKE rate controller for variable WAN capacity.
endef

define Package/sqm-autorate-rust/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/etc/sqm-autorate-rust
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/bin/sqm-autorate-rust $(1)/usr/sbin/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/reflectors-icmp.csv \
		$(1)/etc/sqm-autorate-rust/reflectors-icmp.csv
endef

$(eval $(call RustBinPackage,sqm-autorate-rust))
$(eval $(call BuildPackage,sqm-autorate-rust))
