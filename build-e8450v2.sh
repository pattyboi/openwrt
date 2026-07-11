#!/bin/sh
set -eu

TOPDIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
cd "$TOPDIR"

die() {
	printf 'Error: %s\n' "$*" >&2
	exit 2
}

require_config_symbol() {
	_symbol=$1
	_config=${2:-.config}
	grep -Fqx "$_symbol" "$_config" || die "required configuration is missing: $_symbol ($_config)"
}

ask_yes_no() {
	_question=$1
	_default=$2
	while :; do
		printf '%s (y/n) [%s]: ' "$_question" "$_default"
		IFS= read -r _answer || exit 1
		_answer=${_answer:-$_default}
		case $_answer in
			y|Y|yes|YES) return 0 ;;
			n|N|no|NO) return 1 ;;
			*) printf 'Please answer y or n.\n' ;;
		esac
	done
}

case ${1:-} in
	-h|--help) printf 'Usage: %s [MAKE_TARGET]\n' "$0"; exit 0 ;;
esac

command -v make >/dev/null 2>&1 || die 'make is required'
[ -f configs/e8450-ubi.config ] || die 'configs/e8450-ubi.config is missing'
# SSH is the only normal remote recovery path after a sysupgrade.  Keep this
# explicit in the board seed rather than relying on target default packages.
require_config_symbol 'CONFIG_PACKAGE_dropbear=y' configs/e8450-ubi.config
require_config_symbol 'CONFIG_PACKAGE_kmod-fs-vfat=y' configs/e8450-ubi.config
require_config_symbol 'CONFIG_PACKAGE_kmod-usb-storage=y' configs/e8450-ubi.config
require_config_symbol 'CONFIG_PACKAGE_kmod-usb-xhci-mtk=y' configs/e8450-ubi.config
require_config_symbol 'CONFIG_PACKAGE_kmod-usb3=y' configs/e8450-ubi.config

detected_jobs=$(command -v nproc >/dev/null 2>&1 && nproc || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
printf '%s\n' '===========================================' '   Linksys E8450 Build Assistant' '==========================================='
printf 'Parallel jobs [%s]: ' "$detected_jobs"
IFS= read -r jobs || exit 1
jobs=${jobs:-$detected_jobs}
case $jobs in *[!0-9]*|'') die 'jobs must be a positive integer' ;; esac
[ "$jobs" -gt 0 ] || die 'jobs must be greater than zero'

SYSTEM_CLANG=0
GOOGLE_CLANG=0
if command -v clang >/dev/null 2>&1; then
	clang_version=$(clang --version 2>/dev/null | sed -n '1p')
	printf 'Found system Clang: %s\n' "$clang_version"
	if ask_yes_no 'Use system Clang for the kernel' n; then
		SYSTEM_CLANG=1
		export SYSTEM_CLANG
	fi
else
	printf 'System Clang not found; system-Clang option is unavailable.\n'
fi

if [ "$SYSTEM_CLANG" -eq 0 ] && [ "$(uname -m)" = x86_64 ]; then
	if ask_yes_no 'Use the pinned Google Clang toolchain for the kernel' y; then
		GOOGLE_CLANG=1
		export GOOGLE_CLANG
	fi
else
	printf 'Pinned Google Clang is only available for x86_64 hosts; it will remain disabled.\n'
fi

KERNEL_LTO=none
if [ "$SYSTEM_CLANG" -eq 1 ] || [ "$GOOGLE_CLANG" -eq 1 ]; then
	if [ "$SYSTEM_CLANG" -eq 1 ]; then
		clang_provider='system Clang'
	else
		clang_provider='Google Clang'
	fi
	printf 'Clang LTO is available through %s.\n' "$clang_provider"
	printf '%s\n' 'Kernel LTO mode:' '  1) None' '  2) ThinLTO (experimental; recommended for iteration)' '  3) Full LTO (experimental; highest link cost)'
	while :; do
		printf 'Select LTO mode [1]: '
		IFS= read -r lto_choice || exit 1
		case ${lto_choice:-1} in
			1) KERNEL_LTO=none; break ;;
			2) KERNEL_LTO=thin; break ;;
			3) KERNEL_LTO=full; break ;;
			*) printf 'Please select 1, 2, or 3.\n' ;;
		esac
	done
else
	printf 'LTO is unavailable without a Clang kernel toolchain; using no LTO.\n'
fi
export KERNEL_LTO

FASTLD=0

if [ "$KERNEL_LTO" != none ]; then
	command -v ld.lld >/dev/null 2>&1 || die "KERNEL_LTO=$KERNEL_LTO requires ld.lld"
	FASTLD=1
	export FASTLD
	printf 'LTO requires LLD; FASTLD is enabled automatically.\n'
elif command -v ld.lld >/dev/null 2>&1; then
	if ask_yes_no 'Use LLD for the kernel link (iteration builds only)' n; then FASTLD=1; export FASTLD; fi
else
	printf 'Host ld.lld not found; FASTLD will remain disabled.\n'
fi
if ask_yes_no 'Run make clean before building' n; then CLEAN=1; else CLEAN=0; fi

if [ "$#" -gt 0 ]; then
	target=$1
else
	printf 'Make target [all]: '
	IFS= read -r target || exit 1
	target=${target:-all}
fi

[ "$CLEAN" -eq 0 ] || make clean
cp configs/e8450-ubi.config .config
make defconfig

# This repository's generated target metadata does not preserve these hidden
# string symbols during defconfig, even though the selector symbols remain.
# Restore them before invoking any target build so KERNEL_PATCHVER and the
# E8450 device profile resolve deterministically.
sed -i \
	-e '/^CONFIG_TARGET_mediatek=/d' \
	-e '/^CONFIG_TARGET_mediatek_mt7622=/d' \
	-e '/^CONFIG_TARGET_mediatek_mt7622_DEVICE_linksys_e8450-ubi=/d' \
	-e '/^CONFIG_TARGET_BOARD=/d' \
	-e '/^CONFIG_TARGET_SUBTARGET=/d' \
	-e '/^CONFIG_TARGET_PROFILE=/d' \
	-e '/^CONFIG_ARCH=/d' \
	-e '/^CONFIG_TARGET_ARCH_PACKAGES=/d' \
	-e '/^CONFIG_CPU_TYPE=/d' \
	-e '/^CONFIG_PACKAGE_dropbear=/d' \
	-e '/^CONFIG_PACKAGE_kmod-fs-vfat=/d' \
	-e '/^CONFIG_PACKAGE_kmod-usb-storage=/d' \
	-e '/^CONFIG_PACKAGE_kmod-usb-xhci-mtk=/d' \
	-e '/^CONFIG_PACKAGE_kmod-usb3=/d' \
	.config
cat >> .config <<'EOF'
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_mt7622=y
CONFIG_TARGET_mediatek_mt7622_DEVICE_linksys_e8450-ubi=y
CONFIG_TARGET_BOARD="mediatek"
CONFIG_TARGET_SUBTARGET="mt7622"
CONFIG_TARGET_PROFILE="DEVICE_linksys_e8450-ubi"
CONFIG_ARCH="aarch64"
CONFIG_TARGET_ARCH_PACKAGES="aarch64_cortex-a53"
CONFIG_CPU_TYPE="cortex-a53"
CONFIG_PACKAGE_dropbear=y
CONFIG_PACKAGE_kmod-fs-vfat=y
CONFIG_PACKAGE_kmod-usb-storage=y
CONFIG_PACKAGE_kmod-usb-xhci-mtk=y
CONFIG_PACKAGE_kmod-usb3=y
EOF

# Generated target Kconfig also drops this explicit package selection during
# defconfig. Reapply it with the restored target metadata, then fail closed if
# a future config change removes the SSH daemon from a flash image.
require_config_symbol 'CONFIG_PACKAGE_dropbear=y'
require_config_symbol 'CONFIG_PACKAGE_kmod-fs-vfat=y'
require_config_symbol 'CONFIG_PACKAGE_kmod-usb-storage=y'
require_config_symbol 'CONFIG_PACKAGE_kmod-usb-xhci-mtk=y'
require_config_symbol 'CONFIG_PACKAGE_kmod-usb3=y'

printf '%s\n' '==========================================='
printf 'Building target %s with -j%s (system Clang=%s, Google Clang=%s, LTO=%s, FASTLD=%s)\n' \
	"$target" "$jobs" "$SYSTEM_CLANG" "$GOOGLE_CLANG" "$KERNEL_LTO" "$FASTLD"
printf '%s\n' '==========================================='
if [ "$target" = all ]; then exec make -j"$jobs"; fi
exec make -j"$jobs" "$target"
