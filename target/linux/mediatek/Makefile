# Copyright (c) 2015 OpenWrt.org
#
include $(TOPDIR)/rules.mk

ARCH:=arm
BOARD:=mediatek
BOARDNAME:=MediaTek ARM
SUBTARGETS:=filogic mt7622 mt7623 mt7629
FEATURES:=dt-overlay emmc fpu gpio nand pci pcie rootfs-part separate_ramdisk squashfs usb

KERNEL_PATCHVER:=6.12

include $(INCLUDE_DIR)/target.mk
DEFAULT_PACKAGES += \
	kmod-leds-gpio kmod-gpio-button-hotplug

# Opt-in fast kernel link for iteration builds: FASTLD=1 make target/linux/compile
# Uses host ld.lld — the only fast linker kbuild accepts (6.12's
# scripts/Kconfig.include hard-rejects mold: "Sorry, this linker is not
# supported"). Keep release/flash images on binutils ld (default) — the
# linker is a validated variable on this box.
ifneq ($(strip $(FASTLD)),)
  FAST_LD:=$(shell command -v ld.lld 2>/dev/null)
  ifeq ($(FAST_LD),)
    $(error FASTLD=1 requires ld.lld in PATH; install the host lld package)
  endif
  KERNEL_MAKE_FLAGS += LD=$(FAST_LD)
endif

$(eval $(call BuildTarget))
