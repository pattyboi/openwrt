#!/bin/sh
set -eu

TOPDIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

cd "$TOPDIR"

echo "==========================================="
echo "   Linksys E8450 Build Assistant           "
echo "==========================================="
echo ""

# 1. Determine CPU Jobs interactively
DETECTED_CORES=$(nproc)
printf "Number of CPU cores to use [Default: %s]: " "$DETECTED_CORES"
read -r INPUT_JOBS
JOBS=${INPUT_JOBS:-$DETECTED_CORES}

# 2. Ask about Google Clang compiler toolchain
while true; do
	printf "Would you like to use the Google Clang toolchain? (y/n) [Default: y]: "
	read -r INPUT_CLANG
	INPUT_CLANG=${INPUT_CLANG:-y}
	
	case "$INPUT_CLANG" in
		[Yy]*) GOOGLE_CLANG=1; break ;;
		[Nn]*) GOOGLE_CLANG=0; break ;;
		*) echo "Please answer yes (y) or no (n)." ;;
	esac
done

export GOOGLE_CLANG

# 3. Check for LLD and ask about Fast Kernel Link (FASTLD)
FASTLD=0
if command -v ld.lld >/dev/null 2>&1; then
	while true; do
		printf "Enable Fast Kernel Link (FASTLD=1)? (y/n) [Default: y]: "
		read -r INPUT_FASTLD
		INPUT_FASTLD=${INPUT_FASTLD:-y}
		
		case "$INPUT_FASTLD" in
			[Yy]*) FASTLD=1; break ;;
			[Nn]*) FASTLD=0; break ;;
			*) echo "Please answer yes (y) or no (n)." ;;
		esac
	done
else
	echo "-> Host 'ld.lld' not found. Skipping Fast Kernel Link option."
fi

# Export FASTLD if enabled
if [ "$FASTLD" = 1 ]; then
	export FASTLD=1
fi

# 4. Ask about cleaning the build environment
while true; do
	printf "Do you want to run 'make clean' before building? (y/n) [Default: n]: "
	read -r INPUT_CLEAN
	INPUT_CLEAN=${INPUT_CLEAN:-n}
	
	case "$INPUT_CLEAN" in
		[Yy]*) CLEAN=1; break ;;
		[Nn]*) CLEAN=0; break ;;
		*) echo "Please answer yes (y) or no (n)." ;;
	esac
done

# 5. Ask for specific make targets
echo ""
echo "Enter any specific make targets (e.g., 'target/linux/compile')."
printf "Leave blank for a standard full build: "
read -r TARGETS

# --- Execution Setup ---

cp configs/e8450-ubi.config .config
make defconfig

if [ "${CLEAN:-0}" = 1 ]; then
	echo "-> Cleaning build directory..."
	make clean
fi

echo "-> Starting build with -j$JOBS..."
echo "   [Google Clang: $GOOGLE_CLANG | FASTLD: $FASTLD]"
echo "==========================================="

exec make -j"$JOBS" $TARGETS
