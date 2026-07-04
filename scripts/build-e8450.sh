#!/bin/sh
set -eu

TOPDIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
JOBS=${JOBS:-$(nproc)}

cd "$TOPDIR"

cp configs/e8450-ubi.config .config
make defconfig

if [ "${CLEAN:-0}" = 1 ]; then
	make clean
fi

exec make -j"$JOBS" "$@"
