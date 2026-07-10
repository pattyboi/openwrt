#!/bin/sh
# Cache the compiled OpenWrt host tools + target toolchain so a cleaned or
# freshly cloned tree skips the multi-hour tools/toolchain build, and publish
# the cache as a GitHub release asset tagged in this repo.
#
#   save     tar staging_dir/host + staging_dir/toolchain-* into
#            bin/toolchain-cache/ with a fingerprint of the toolchain inputs
#   restore  unpack the newest matching cache (local file, or downloaded from
#            the GitHub release when missing locally) and refresh stamp
#            mtimes so make does not rebuild
#   upload   git tag toolchain-<date>-<fp> and create a GitHub release with
#            the tarball attached (requires `gh auth login` once)
#   refresh  no-op when the fingerprint still matches the last save;
#            otherwise rebuild tools+toolchain, save, upload (cron entry
#            point for the monthly check)
#
# The tarballs contain binaries with absolute paths: restore only works with
# the tree at the same TOPDIR path it was saved from.
set -eu

TOPDIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$TOPDIR"
CACHE_DIR=$TOPDIR/bin/toolchain-cache
JOBS=${JOBS:-$(nproc)}

fingerprint() {
	# Toolchain outputs are determined by the tools/ and toolchain/ source
	# trees (committed state; a dirty tree gets a -dirty fingerprint that
	# refresh treats as changed but upload refuses).
	fp=$( { git rev-parse HEAD:tools HEAD:toolchain; echo "$TOPDIR"; } \
		| sha256sum | cut -c1-12)
	if [ -n "$(git status --porcelain tools toolchain)" ]; then
		fp="$fp-dirty"
	fi
	echo "$fp"
}

toolchain_dir() {
	set -- staging_dir/toolchain-*
	[ -d "$1" ] || { echo "no compiled toolchain in staging_dir" >&2; exit 1; }
	echo "$1"
}

tarball_name() {
	echo "$CACHE_DIR/toolchain-$(fingerprint).tar.zst"
}

do_save() {
	tc=$(toolchain_dir)
	mkdir -p "$CACHE_DIR"
	out=$(tarball_name)
	echo "saving $tc + staging_dir/host -> $out"
	tar -I "zstd -T0 -8" -cf "$out.tmp" staging_dir/host "$tc"
	mv "$out.tmp" "$out"
	fingerprint > "$CACHE_DIR/last-saved.fingerprint"
	ls -lh "$out"
}

do_restore() {
	out=$(tarball_name)
	if [ ! -f "$out" ]; then
		echo "no local cache for fingerprint $(fingerprint); trying GitHub"
		mkdir -p "$CACHE_DIR"
		gh release download "toolchain-latest" \
			--pattern "toolchain-$(fingerprint).tar.zst" \
			--dir "$CACHE_DIR" || {
			echo "no release asset matches fingerprint $(fingerprint)" >&2
			echo "(toolchain sources changed since last save: rebuild needed)" >&2
			exit 1
		}
	fi
	echo "restoring $out"
	tar -I zstd -xf "$out"
	# tar keeps original mtimes; a fresh checkout's source files would look
	# newer than the stamps and make would rebuild everything, so bump them
	find staging_dir/host/stamp staging_dir/toolchain-*/stamp \
		-type f -exec touch {} +
	echo "restored; make will skip tools/ and toolchain/"
}

do_upload() {
	fp=$(fingerprint)
	case $fp in *-dirty)
		echo "tools/ or toolchain/ has uncommitted changes; commit first" >&2
		exit 1
	esac
	out=$(tarball_name)
	[ -f "$out" ] || { echo "run save first: $out missing" >&2; exit 1; }
	tag="toolchain-$(date +%Y%m%d)-$fp"
	echo "tagging $tag and uploading $(basename "$out")"
	git tag -f -a "$tag" -m "toolchain cache $fp (gcc $(ls -d staging_dir/toolchain-* | sed 's/.*gcc-//;s/_.*//'))"
	git push -f origin "$tag"
	gh release create "$tag" "$out" \
		--title "$tag" \
		--notes "Compiled host tools + target toolchain cache.
Fingerprint: $fp (sha256 of tools/ + toolchain/ tree hashes + TOPDIR).
Restore with: ./scripts/toolchain-cache.sh restore (tree must live at $TOPDIR)."
	# stable alias release so restore can fetch without knowing the date
	gh release delete toolchain-latest --yes 2>/dev/null || true
	git push origin :refs/tags/toolchain-latest 2>/dev/null || true
	git tag -f toolchain-latest "$tag"
	git push -f origin toolchain-latest
	gh release create toolchain-latest "$out" \
		--title "toolchain-latest (alias of $tag)" \
		--notes "Always points at the newest toolchain cache. Current: $tag ($fp)."
}

do_refresh() {
	fp=$(fingerprint)
	last=$(cat "$CACHE_DIR/last-saved.fingerprint" 2>/dev/null || echo none)
	if [ "$fp" = "$last" ]; then
		echo "$(date -Is) toolchain unchanged ($fp); nothing to do"
		return 0
	fi
	echo "$(date -Is) fingerprint $last -> $fp; rebuilding toolchain"
	nice make tools/install toolchain/install -j"$JOBS"
	do_save
	do_upload
}

case ${1:-} in
save)    do_save ;;
restore) do_restore ;;
upload)  do_upload ;;
refresh) do_refresh ;;
fingerprint) fingerprint ;;
*) echo "usage: $0 save|restore|upload|refresh|fingerprint" >&2; exit 2 ;;
esac
