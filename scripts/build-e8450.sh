#!/bin/sh
set -eu

TOPDIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
JOBS=${JOBS:-$(nproc)}
GOOGLE_CLANG=${GOOGLE_CLANG:-1}

cd "$TOPDIR"

# Pin the CPU governor for build speed (Pi 5 defaults to schedutil, which
# ramps late under bursty compile load). Best-effort: needs root, ignored
# otherwise.
for p in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
	echo performance > "$p" 2>/dev/null || true
done

cp configs/e8450-ubi.config .config
make defconfig

if [ "${CLEAN:-0}" = 1 ]; then
	make clean
fi

exec make -j"$JOBS" "$@"
