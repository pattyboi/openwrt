#!/bin/sh
# Simple flash script: scp the latest sysupgrade image to the router and
# flash it with sysupgrade -c, keeping all changed /etc config settings.
#
# Router credentials are never hardcoded here. Provide them via either:
#   - the ROUTER_PASS environment variable, or
#   - a local, gitignored .router-credentials file (see .router-credentials.example)
set -e

ROUTER="root@192.168.1.1"
IMAGE="bin/targets/mediatek/mt7622/openwrt-mediatek-mt7622-linksys_e8450-ubi-squashfs-sysupgrade.itb"
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

if [ -z "$ROUTER_PASS" ] && [ -f "$(dirname "$0")/.router-credentials" ]; then
	# shellcheck disable=SC1091
	. "$(dirname "$0")/.router-credentials"
fi

if [ -z "$ROUTER_PASS" ]; then
	echo "ROUTER_PASS not set: export ROUTER_PASS=... or create .router-credentials" >&2
	echo "(see .router-credentials.example)" >&2
	exit 1
fi

[ -f "$IMAGE" ] || { echo "image not found: $IMAGE" >&2; exit 1; }

echo "Copying $IMAGE -> $ROUTER:/tmp/"
sshpass -p "$ROUTER_PASS" scp $SSHOPTS -O "$IMAGE" "$ROUTER:/tmp/"

echo "Flashing (config retained, sysupgrade -c)..."
sshpass -p "$ROUTER_PASS" ssh $SSHOPTS "$ROUTER" "sysupgrade -c -v /tmp/$(basename "$IMAGE")"
