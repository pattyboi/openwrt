# Building the E8450 image

- Canonical build seed: `configs/e8450-ubi.config`. Run the interactive
  `./build-e8450v2.sh`; it asks for jobs, optional system Clang, optional
  Google Clang where the host supports the pinned x86_64 bundle, optional LLD,
  clean build, and the make target. `./scripts/build-e8450v2.sh` is a compatibility
  entry point for callers that expect the script under `scripts/`.
- System Clang and Google Clang affect the kernel and kernel modules; userspace
  remains GCC. The options are opt-in on unsupported or unvalidated hosts.
  LLD is opt-in and should not be used for an image intended for hardware
  flashing until that image has been validated.
- The equivalent manual build-tree switch is
  `make target/linux/compile SYSTEM_CLANG=1`; it fails clearly if `clang` is
  not in `PATH`. Do not combine `SYSTEM_CLANG=1` with `GOOGLE_CLANG=1`.
- When either system Clang or the pinned Google Clang toolchain is selected, the
  assistant offers kernel `LTO_NONE`, experimental `ThinLTO`, or experimental
  `Full LTO`. ThinLTO is the sensible iteration candidate; Full LTO can consume
  substantially more memory and link time. Either LTO mode automatically
  enables the LLD fast-link path and fails if `ld.lld` is unavailable. GCC
  builds remain LTO-free.
- The current build host is `aarch64` and cannot run the pinned Linux-x86
  Google prebuilt; the assistant detects this and disables that option. System
  Clang (Debian clang 19.1.7 + LLD 19.1.7) is installed and **hardware-validated
  on 2026-07-12**: a full `SYSTEM_CLANG=1` `KERNEL_LTO=none` image built, passed
  the manifest gate, flashed over SSH sysupgrade, and booted clean on the E8450
  (see the reference doc §2026-07-12 reflash). Note `LLVM=` kernel builds link
  with LLD implicitly even when the FASTLD prompt is answered "n" — the
  binutils-ld caution below applies to GCC kernel builds only.
- Clang's `-Werror=uninitialized` is stricter than GCC's: it caught a real
  uninitialized-pointer bug in stock OpenWrt's mac80211 patch 350 (fixed by our
  `package/kernel/mac80211/patches/subsys/351-mac80211-fix-uninitialized-scan-
  req-use-in-start_roc.patch`). Expect a clang build to surface warnings GCC
  passed; treat new `-Wuninitialized` errors as likely-genuine bugs, not noise.
- Patches: `target/linux/mediatek/patches-6.12/999-*` (diffs vs vanilla;
  quilt applies in filename order — 999-ppe-90/91 are rebased ON ppe-17/21).
- Kernel debug/size flags are buildroot symbols in the UNTRACKED `.config`:
  `KERNEL_MAGIC_SYSRQ`, `KERNEL_DETECT_HUNG_TASK`,
  `KERNEL_CC_OPTIMIZE_FOR_SIZE` (target config-6.12 cannot override these).
- Detached builds: `nohup setsid sh -c 'make ... ' &`, log + `BUILD-EXIT=`.
## Build-speed setup (Pi 5 host, tuned 2026-07-11)

- **ccache** (the big lever for the clean-rebuild-per-patch workflow):
  `CONFIG_CCACHE=y` + `CONFIG_CCACHE_DIR=/home/pat/.cache/openwrt-ccache`
  are in the seed config; the dir's `ccache.conf` is set to
  `max_size = 30G` (the default 5G evicts under kernel+packages and
  tanks the hit rate). ccache hashes with BLAKE3 — collision-resistant
  by design because a collision substitutes a wrong object file;
  do not swap it for a non-crypto hash (see
  `docs/umash-port-task.md` for the closed rapidhash investigation).
- **Fast kernel link — opt-in, iteration builds only**:
  Select the LLD option in `./build-e8450v2.sh` for iteration builds (the hook
  in `target/linux/mediatek/Makefile` passes `LD=ld.lld` to kbuild).
  It requires the host `lld` package and fails explicitly if `ld.lld` is
  unavailable; verify with `ld.lld --version` before relying on it.
  mold was tried first and is a dead end for the kernel: 6.12's
  `scripts/Kconfig.include` hard-rejects it ("Sorry, this linker is
  not supported") — kbuild accepts only GNU ld and LLD. mold 2.37
  stays installed for potential host-side use. Deliberately NOT the
  default: the linker is a validated variable — build anything you
  intend to FLASH with the default binutils ld.
- Tree and ccache dir live on the NVMe root — keep it that way.

## E8450 image scope

The seed deliberately omits iptables/xt-offload, GRE/PPTP/L2TP/UDP-tunnel,
macvlan, netconsole, conntrack-event userspace, DNS auth/nftset extensions,
TFTP, and OpenSSL's legacy algorithms/engine support. The hardware and
live-path audit establishes fw4/nft as the firewall, no crypto engine, no
tunnel requirement, no active nft sets, and a broken netconsole path. Keep
the retained IPv6, DNSSEC, conntrack, `perf`, pstore, USB mass-storage/FAT
support (for the guarded USB sysupgrade recovery path), and Wi-Fi/RPC support:
each has an active operational or validation use documented for this target.
DNSSEC pulls `libnettle`/`libgmp`; the selected
`wpad-openssl` package itself pulls the OpenSSL legacy-provider package even
though all legacy algorithms are disabled. Re-add a removed item only with a
concrete deployment need.

- Toolchain cache: `./scripts/toolchain-cache.sh save|restore|upload|refresh`
  tars `staging_dir/host` + `staging_dir/toolchain-*` (~172M zstd) keyed by
  the tools/ + toolchain/ tree-hash fingerprint, published as a GitHub
  release asset on tags `toolchain-<date>-<fp>` / `toolchain-latest`
  (`upload` needs one-time `gh auth login`). After `make dirclean` or a
  fresh clone at the SAME path, `restore` skips the toolchain rebuild.
  `refresh` is manual by choice (no cron): run it after bumping anything
  under tools/ or toolchain/.
