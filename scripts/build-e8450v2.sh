#!/bin/sh
# Compatibility entry point; the canonical assistant lives at the tree root.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
exec "$SCRIPT_DIR/../build-e8450v2.sh" "$@"
