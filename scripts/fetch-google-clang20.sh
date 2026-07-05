#!/bin/sh
set -eu

REVISION=2fa77dca376be7be1e51b89fb2e23c792cd6286b
BRANCH=llvm-r547379-release
CACHE_ROOT=${GOOGLE_CLANG_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/openwrt-toolchains/google-clang-r547379}
TOOLCHAIN=$CACHE_ROOT/clang-r547379
REPOSITORY=https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86

if [ -x "$TOOLCHAIN/bin/clang" ]; then
	version=$($TOOLCHAIN/bin/clang --version | sed -n '1p')
	case "$version" in
	*"r547379"*"20.0.0"*)
		printf '%s\n' "$TOOLCHAIN"
		exit 0
		;;
	esac
	printf 'Unexpected compiler in %s: %s\n' "$TOOLCHAIN" "$version" >&2
	exit 1
fi

mkdir -p "$CACHE_ROOT"

if [ ! -d "$CACHE_ROOT/.git" ]; then
	git -C "$CACHE_ROOT" init >&2
	git -C "$CACHE_ROOT" remote add origin "$REPOSITORY" >&2
fi

git -C "$CACHE_ROOT" config core.sparseCheckout true >&2
git -C "$CACHE_ROOT" sparse-checkout set clang-r547379 >&2
git -C "$CACHE_ROOT" fetch --depth=1 --filter=blob:none origin "$BRANCH" >&2

fetched=$(git -C "$CACHE_ROOT" rev-parse FETCH_HEAD)
if [ "$fetched" != "$REVISION" ]; then
	printf 'Google Clang release moved: expected %s, fetched %s\n' \
		"$REVISION" "$fetched" >&2
	exit 1
fi

git -C "$CACHE_ROOT" checkout --detach "$REVISION" >&2

version=$($TOOLCHAIN/bin/clang --version | sed -n '1p')
case "$version" in
*"r547379"*"20.0.0"*) ;;
*)
	printf 'Unexpected fetched compiler: %s\n' "$version" >&2
	exit 1
	;;
esac

printf '%s\n' "$TOOLCHAIN"
