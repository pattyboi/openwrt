# SPDX-License-Identifier: GPL-2.0-only
#
# Set KERNEL_LLVM to a selected Clang toolchain for the kernel.
# SYSTEM_CLANG=1 uses the host's clang; GOOGLE_CLANG=1 uses the pinned
# Linux-x86 Google prebuilt. They are intentionally mutually exclusive.
#
# The fetch script sparse-checks-out the toolchain on first use and caches it
# in $(GOOGLE_CLANG_CACHE) (default: ~/.cache/openwrt-toolchains/google-clang-r547379).
# Subsequent calls complete in under a second (version check + path print only).
#
# Integrated as a tools/ dependency so 'make tools/compile' pre-fetches the
# toolchain; 'make target/linux' also works standalone (fetch is on-demand).

ifeq ($(SYSTEM_CLANG),1)
  ifeq ($(GOOGLE_CLANG),1)
    $(error SYSTEM_CLANG=1 and GOOGLE_CLANG=1 are mutually exclusive)
  endif
  SYSTEM_CLANG_BIN ?= $(shell command -v clang 2>/dev/null)
  ifeq ($(strip $(SYSTEM_CLANG_BIN)),)
    $(error SYSTEM_CLANG=1 but clang was not found in PATH)
  endif
  KERNEL_LLVM := $(patsubst %/,%,$(dir $(SYSTEM_CLANG_BIN)))
endif

ifeq ($(GOOGLE_CLANG),1)
  ifneq ($(SYSTEM_CLANG),1)
  ifeq ($(KERNEL_LLVM),)
    KERNEL_LLVM := $(patsubst %,%/bin,$(shell $(TOPDIR)/scripts/fetch-google-clang20.sh 2>/dev/null))
    ifeq ($(KERNEL_LLVM),)
      $(error GOOGLE_CLANG=1 but fetch-google-clang20.sh failed — check network or set GOOGLE_CLANG_CACHE)
    endif
  endif
  endif
endif
