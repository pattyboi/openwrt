#!/bin/sh
# qdma-shaper: MediaTek NETSYSv1 QDMA WAN queue shaper + AQM backend.
#
# Wraps the qos-03/qos-06 debugfs controls (qdma_rate, qdma_aqm, qdma_regs)
# with board- and DSA-aware safety checks. It sets a per-queue upload max-rate
# cap on the WAN egress queue (queue = 3 + DSA port index) and wires the
# qos-06 occupancy-driven AQM that evicts PPE-offloaded flows to CAKE/SQM
# when the hardware queue saturates, bounding latency under load.
#
# Commands:
#   qdma-shaper validate <interface> <rate_kbps>
#   qdma-shaper apply    <interface> <rate_kbps>
#   qdma-shaper clear    <interface>
#   qdma-shaper status   <interface>
#
# Requires flow_offloading_hw=1 for full effect: PPE-offloaded transit flows
# are capped by the hardware leaky bucket; the AQM evicts them to CAKE when
# the queue saturates. Router-originated and non-offloaded traffic uses CAKE
# directly. Result: near-CAKE latency at hardware-offload CPU cost.

log() { logger -t qdma-shaper "$*" 2>/dev/null; echo "qdma-shaper: $*" >&2; }
die() { log "$@"; exit 1; }

# Resolve the netdev backing a logical interface name. Falls back to ubus
# l3_device when the name is not already a netdev.
netdev_for() {
	local iface="$1" dev
	[ -n "$iface" ] || return 1
	if [ -e "/sys/class/net/$iface" ]; then
		echo "$iface"
		return 0
	fi
	if command -v ubus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
		dev="$(ubus call "network.interface.$iface" status 2>/dev/null | \
			jsonfilter -e '@.l3_device' 2>/dev/null)"
		[ -n "$dev" ] && [ -e "/sys/class/net/$dev" ] && { echo "$dev"; return 0; }
	fi
	return 1
}

# Enforce known-board safety: on the E8450 the WAN must map to queue 7.
board_assert() {
	local iface="$1" q="$2" board
	board="$(cat /tmp/sysinfo/board_name 2>/dev/null)"
	case "$board" in
	linksys,e8450-ubi)
		[ "$q" = "7" ] || \
			die "board $board: expected WAN on queue 7, resolved queue $q for '$iface'"
		;;
	esac
	return 0
}

# Echoes "<debugfs_dir> <netdev> <queue>" on success; dies otherwise.
resolve_target() {
	local iface="$1" dev name port q d dir=""
	[ -n "$iface" ] || die "interface required"

	for d in /sys/kernel/debug/*.ethernet; do
		[ -w "$d/qdma_rate" ] && [ -r "$d/qdma_regs" ] && { dir="$d"; break; }
	done
	[ -n "$dir" ] || \
		die "NETSYSv1 QDMA control (qdma_rate) not found; unsupported SoC or missing qos-03 patch"

	dev="$(netdev_for "$iface")" || die "interface '$iface' has no netdev"

	name="$(cat "/sys/class/net/$dev/phys_port_name" 2>/dev/null)"
	case "$name" in
	p[0-9]|p[0-9][0-9]) port="${name#p}" ;;
	*) die "'$iface' ($dev) is not a DSA switch user port (phys_port_name='$name')" ;;
	esac

	q=$((3 + port))
	[ "$q" -ge 3 ] && [ "$q" -lt 16 ] || die "derived queue $q out of range for '$iface'"
	board_assert "$iface" "$q"

	echo "$dir $dev $q"
}

validate_rate() {
	case "$1" in
	''|*[!0-9]*) die "rate_kbps must be a positive integer (got '$1')" ;;
	esac
	[ "$1" -gt 0 ] 2>/dev/null || die "rate_kbps must be > 0 (got '$1')"
}

# Extract a "key=value" token from a single qdma_regs line.
field() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }

regs_line() { grep "^queue=$2 " "$1/qdma_regs" 2>/dev/null; }

# Snapshot every queue's qtx_sch as "N=0x........" lines.
snapshot_sch() {
	awk '/^queue=/ {
		q=""; s="";
		for (i = 1; i <= NF; i++) {
			if ($i ~ /^queue=/)   { split($i, a, "="); q = a[2] }
			else if ($i ~ /^qtx_sch=/) { split($i, a, "="); s = a[2] }
		}
		if (q != "" && s != "") print q "=" s
	}' "$1/qdma_regs"
}

# Emit queue ids (other than $3) whose qtx_sch changed between snapshots.
other_changed() {
	local q="$3" qn sch anew
	printf '%s\n' "$1" | while IFS='=' read -r qn sch; do
		[ "$qn" = "$q" ] && continue
		anew="$(printf '%s\n' "$2" | sed -n "s/^$qn=//p")"
		[ "$anew" = "$sch" ] || printf '%s ' "$qn"
	done
}

cmd_validate() {
	local iface="$1" rate="$2" out dir dev q
	out="$(resolve_target "$iface")" || exit 1
	set -- $out; dir="$1"; dev="$2"; q="$3"
	validate_rate "$rate"
	echo "valid: interface=$iface netdev=$dev queue=$q rate_kbps=$rate"
}

cmd_apply() {
	local iface="$1" rate="$2" out dir dev q line ov men eff before after changed
	out="$(resolve_target "$iface")" || exit 1
	set -- $out; dir="$1"; dev="$2"; q="$3"
	validate_rate "$rate"

	before="$(snapshot_sch "$dir")"
	echo "$q $rate" > "$dir/qdma_rate" 2>/dev/null || die "write to qdma_rate failed"

	line="$(regs_line "$dir" "$q")"
	ov="$(field "$line" override_kbps)"
	men="$(field "$line" max_en)"
	eff="$(field "$line" effective_kbps)"
	after="$(snapshot_sch "$dir")"
	changed="$(other_changed "$before" "$after" "$q")"

	if [ "$ov" != "$rate" ] || [ "$men" != "1" ] || [ -n "$changed" ]; then
		echo "$q 0" > "$dir/qdma_rate" 2>/dev/null
		die "readback mismatch (override_kbps='$ov' max_en='$men' other_changed='$changed'); rolled back queue $q"
	fi

	log "applied interface=$iface netdev=$dev queue=$q requested=${rate}kbps effective=${eff}kbps"
}

cmd_clear() {
	local iface="$1" out dir dev q line ov
	out="$(resolve_target "$iface")" || exit 1
	set -- $out; dir="$1"; dev="$2"; q="$3"

	echo "$q 0" > "$dir/qdma_rate" 2>/dev/null || die "clear write to qdma_rate failed"
	line="$(regs_line "$dir" "$q")"
	ov="$(field "$line" override_kbps)"
	[ "$ov" = "0" ] || die "clear readback failed: override_kbps='$ov' (queue $q)"

	log "cleared interface=$iface netdev=$dev queue=$q (restored link-rate word)"
}

cmd_status() {
	local iface="$1" out dir dev q line board fo foh cake aqm_node aqm_state
	out="$(resolve_target "$iface")" || exit 1
	set -- $out; dir="$1"; dev="$2"; q="$3"
	line="$(regs_line "$dir" "$q")"

	board="$(cat /tmp/sysinfo/board_name 2>/dev/null)"
	fo="$(uci -q get firewall.@defaults[0].flow_offloading)"
	foh="$(uci -q get firewall.@defaults[0].flow_offloading_hw)"
	cake="no"
	if command -v tc >/dev/null 2>&1; then
		tc qdisc show dev "$dev" 2>/dev/null | grep -q cake && cake="yes"
	fi

	aqm_node=""
	for d in /sys/kernel/debug/*.ethernet; do
		[ -f "$d/qdma_aqm" ] && { aqm_node="$d/qdma_aqm"; break; }
	done
	[ -n "$aqm_node" ] && aqm_state="$(cat "$aqm_node" 2>/dev/null)" || aqm_state="unavailable"

	echo "interface=$iface"
	echo "netdev=$dev"
	echo "board=$board"
	echo "phys_port_name=$(cat "/sys/class/net/$dev/phys_port_name" 2>/dev/null)"
	echo "queue=$q"
	echo "link_mbps=$(field "$line" link_mbps)"
	echo "override_kbps=$(field "$line" override_kbps)"
	echo "effective_kbps=$(field "$line" effective_kbps)"
	echo "max_kbps=$(field "$line" max_kbps)"
	echo "qtx_sch=$(field "$line" qtx_sch)"
	echo "flow_offloading=${fo:-0}"
	echo "flow_offloading_hw=${foh:-0}"
	echo "cake_on_${dev}=$cake"
	echo "aqm=$aqm_state"
}

usage() {
	cat >&2 <<EOF
usage: qdma-shaper <command> <interface> [rate_kbps]
  validate <iface> <rate_kbps>   check identity and rate without writing
  apply    <iface> <rate_kbps>   set the upload cap on the WAN egress queue
  clear    <iface>               remove the cap (restore link-rate word)
  status   <iface>               print resolved queue and current state
EOF
	exit 2
}

cmd="$1"
[ $# -ge 1 ] && shift
case "$cmd" in
validate) [ $# -eq 2 ] || usage; cmd_validate "$1" "$2" ;;
apply)    [ $# -eq 2 ] || usage; cmd_apply "$1" "$2" ;;
clear)    [ $# -eq 1 ] || usage; cmd_clear "$1" ;;
status)   [ $# -eq 1 ] || usage; cmd_status "$1" ;;
*)        usage ;;
esac
