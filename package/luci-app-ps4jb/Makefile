#
# LuCI control for the PS4 jailbreak host (ps4jb): status, and binload.
#
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-ps4jb
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=NOASSERTION
PKG_MAINTAINER:=pattyboi

LUCI_TITLE:=PS4 jailbreak host control
LUCI_DESCRIPTION:=Shows what the router's PS4 jailbreak host is serving and what the last \
chain run did, and hands a payload to a console's GoldHEN PayLoader.  The push is the real \
HTTP POST (200 means loaded); the port is never probed with a bare connect, which was \
measured to take the PayLoader listener down.
LUCI_DEPENDS:=+luci-base +ps4jb
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# The line below is not decoration: the buildroot's package scan finds a package by grepping
# its Makefile for `call BuildPackage`, and luci.mk is what makes that call for LuCI apps.
# call BuildPackage - OpenWrt buildroot signature
