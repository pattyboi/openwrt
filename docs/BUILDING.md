# Building the E8450 image

- Canonical build seed: `configs/e8450-ubi.config`. Run
  `./scripts/build-e8450.sh`, or `CLEAN=1 ./scripts/build-e8450.sh` for a
  clean build; set `JOBS` to override the default `nproc` parallelism. The
  wrapper defaults to pinned Google Clang 20 (`clang-r547379`) for the kernel
  and kernel modules while retaining GCC for userspace; set `GOOGLE_CLANG=0`
  for the GCC kernel baseline. The toolchain is cached outside the tree.
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
  `FASTLD=1 ./scripts/build-e8450.sh target/linux/compile` (hook in
  `target/linux/mediatek/Makefile` passes `LD=ld.lld` to kbuild).
  It requires the host `lld` package and fails explicitly if `ld.lld` is
  unavailable; verify with `ld.lld --version` before relying on it.
  mold was tried first and is a dead end for the kernel: 6.12's
  `scripts/Kconfig.include` hard-rejects it ("Sorry, this linker is
  not supported") — kbuild accepts only GNU ld and LLD. mold 2.37
  stays installed for potential host-side use. Deliberately NOT the
  default: the linker is a validated variable — build anything you
  intend to FLASH with the default binutils ld.
- **Governor**: `build-e8450.sh` pins all CPUs to `performance`
  (best-effort; Pi 5 default schedutil ramps late under bursty
  compile load).
- Tree and ccache dir live on the NVMe root — keep it that way.

## E8450 image scope

The seed deliberately omits iptables/xt-offload, GRE/PPTP/L2TP/UDP-tunnel,
macvlan, netconsole, conntrack-event userspace, DNS auth/nftset extensions,
TFTP, and OpenSSL's legacy algorithms/engine support. The hardware and
live-path audit establishes fw4/nft as the firewall, no crypto engine or
exposed USB port, no tunnel requirement, no active nft sets, and a broken
netconsole path. Keep the retained IPv6, DNSSEC, conntrack, `perf`, pstore,
and Wi-Fi/RPC support: each has an active operational or validation use
documented for this target. DNSSEC pulls `libnettle`/`libgmp`; the selected
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
