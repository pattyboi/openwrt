#!/bin/sh
set -eu

TOPDIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
JOBS=${JOBS:-$(nproc)}
GOOGLE_CLANG=${GOOGLE_CLANG:-1}

cd "$TOPDIR"

cp configs/e8450-ubi.config .config
make defconfig

if [ "${CLEAN:-0}" = 1 ]; then
	make clean
fi

if [ "$GOOGLE_CLANG" = 1 ]; then
	GOOGLE_CLANG_DIR=${GOOGLE_CLANG_DIR:-$($TOPDIR/scripts/fetch-google-clang20.sh)}
	exec make -j"$JOBS" KERNEL_LLVM="$GOOGLE_CLANG_DIR/bin" "$@"
fi

exec make -j"$JOBS" "$@"
