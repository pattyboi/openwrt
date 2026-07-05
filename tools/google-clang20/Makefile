# SPDX-License-Identifier: GPL-2.0-only
include $(TOPDIR)/rules.mk

PKG_NAME    := google-clang20
FETCH_SCRIPT := $(TOPDIR)/scripts/fetch-google-clang20.sh

STAMP    := $(STAGING_DIR_HOST)/stamp/.$(PKG_NAME)_installed
BINDIR   := $(STAGING_DIR_HOST)/.$(PKG_NAME)-bindir

compile: $(STAMP)

# Stamp depends on the fetch script so a script update triggers re-fetch.
# Order-only dep on $(STAGING_DIR_HOST)/stamp ensures the directory exists.
$(STAMP): $(FETCH_SCRIPT) | $(STAGING_DIR_HOST)/stamp
	clang_dir=$$($(FETCH_SCRIPT)) && printf '%s/bin\n' "$$clang_dir" > "$(BINDIR)"
	touch $@

$(STAGING_DIR_HOST)/stamp:
	mkdir -p $@

# 'download' target participates in 'make download' so the toolchain can be
# pre-fetched on build hosts without running a full build.
download:
	$(FETCH_SCRIPT) > /dev/null

clean:
	rm -f $(STAMP) $(BINDIR)

.PHONY: compile download clean
