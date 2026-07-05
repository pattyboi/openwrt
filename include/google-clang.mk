# SPDX-License-Identifier: GPL-2.0-only
#
# Set KERNEL_LLVM to Google Clang 20 when GOOGLE_CLANG=1.
#
# The fetch script sparse-checks-out the toolchain on first use and caches it
# in $(GOOGLE_CLANG_CACHE) (default: ~/.cache/openwrt-toolchains/google-clang-r547379).
# Subsequent calls complete in under a second (version check + path print only).
#
# Integrated as a tools/ dependency so 'make tools/compile' pre-fetches the
# toolchain; 'make target/linux' also works standalone (fetch is on-demand).

ifeq ($(GOOGLE_CLANG),1)
  ifeq ($(KERNEL_LLVM),)
    KERNEL_LLVM := $(patsubst %,%/bin,$(shell $(TOPDIR)/scripts/fetch-google-clang20.sh 2>/dev/null))
    ifeq ($(KERNEL_LLVM),)
      $(error GOOGLE_CLANG=1 but fetch-google-clang20.sh failed — check network or set GOOGLE_CLANG_CACHE)
    endif
  endif
endif
