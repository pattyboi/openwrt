#!/bin/sh
# Runtime toggle for the PPE hardware-offload bypass primitive added by
# 999-ppe-93-mtk_ppe-add-binding-bypass-by-ct-mark-0x99.patch: any flow
# whose conntrack entry carries ct mark 0x99 is refused PPE hardware
# binding (mtk_flow_offload_replace() returns -EOPNOTSUPP) and stays on
# the software/CAKE path for its whole lifetime.
#
# This tool never touches fw4's own generated ruleset. It adds/removes
# a small standalone nftables table with its own forward-hook chain at
# priority -1 (i.e. runs BEFORE fw4's own "forward" chain, priority 0,
# where `flow add @ft` and the flowtable offload decision happen), so
# marking is in place before a NEW flow is ever considered for offload.
# Already-offloaded (already-bound) flows are unaffected until they are
# re-established (existing conntrack entries keep their existing mark).
#
# Usage:
#   ppe-offload-bypass.sh mark HOST_IP    mark new flows to/from HOST_IP
#   ppe-offload-bypass.sh unmark          remove the bypass table entirely
#   ppe-offload-bypass.sh status          show the table if present
#
# Router credentials: $ROUTER_PASS or .router-credentials (see flash.sh).
set -e

ROUTER="root@192.168.1.1"
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
TABLE="e8450_ppe_bypass"

if [ -z "${ROUTER_PASS:-}" ] && [ -f "$(dirname "$0")/../../.router-credentials" ]; then
	# shellcheck disable=SC1091
	. "$(dirname "$0")/../../.router-credentials"
fi
[ -n "${ROUTER_PASS:-}" ] || { echo "ROUTER_PASS not set: export ROUTER_PASS=... or create .router-credentials" >&2; exit 1; }

run() { sshpass -p "$ROUTER_PASS" ssh $SSHOPTS "$ROUTER" "$@"; }

case "${1:-}" in
mark)
	[ -n "${2:-}" ] || { echo "usage: $0 mark HOST_IP" >&2; exit 1; }
	ip="$2"
	run "nft delete table inet $TABLE 2>/dev/null; nft -f -" <<-EOF
		table inet $TABLE {
			chain forward {
				type filter hook forward priority -1; policy accept;
				ip daddr $ip ct mark set 0x99
				ip saddr $ip ct mark set 0x99
			}
		}
	EOF
	echo "marking new flows to/from $ip with ct mark 0x99 (PPE offload refused)"
	;;
unmark)
	run "nft delete table inet $TABLE 2>/dev/null" || true
	echo "bypass table removed; normal PPE offload eligibility restored"
	;;
status)
	run "nft list table inet $TABLE 2>/dev/null" || echo "no bypass table present"
	;;
*)
	echo "usage: $0 {mark HOST_IP|unmark|status}" >&2
	exit 1
	;;
esac
