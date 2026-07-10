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
- Toolchain cache: `./scripts/toolchain-cache.sh save|restore|upload|refresh`
  tars `staging_dir/host` + `staging_dir/toolchain-*` (~172M zstd) keyed by
  the tools/ + toolchain/ tree-hash fingerprint, published as a GitHub
  release asset on tags `toolchain-<date>-<fp>` / `toolchain-latest`
  (`upload` needs one-time `gh auth login`). After `make dirclean` or a
  fresh clone at the SAME path, `restore` skips the toolchain rebuild.
  `refresh` is manual by choice (no cron): run it after bumping anything
  under tools/ or toolchain/.
