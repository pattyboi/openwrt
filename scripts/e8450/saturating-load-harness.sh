#!/bin/sh
# Saturating-load latency harness, formalized from the methodology in
# docs/research/qos-aqm-lab-notes.md (SS22.12, SS23.3, SS33-35):
# an iperf3 upload through the WAN egress (saturates queue 7's ~8300kbps
# QDMA cap) concurrent with a fixed-interval ping, repeated 3x per
# configuration. Run from a LAN workstation behind the E8450 (this
# project's convention: 192.168.1.6), not from the router itself.
#
# Usage: scripts/e8450/saturating-load-harness.sh [reps] [duration_s] [ping_target] [streams]
#   reps          default 3
#   duration_s    default 20 (iperf3 -t and ping sample count both derive from this)
#   ping_target   default 8.8.8.8
#   streams       default 1 (iperf3 -P N parallel streams — use >1 to test under
#                 heavier multi-flow congestion instead of a single saturating flow)
#
# Primary server fra.speedtest.clouvider.net, falls back to iperf.he.net
# on failure/"server is busy" (documented flakiness of the public server).
# A rep whose iperf3 transfer clearly did not saturate (< 1 Mbit/s sent)
# is discarded and retried once, matching the doc's own correction for
# false "AQM never triggered" reps.

set -eu

REPS="${1:-3}"
DUR="${2:-20}"
TARGET="${3:-8.8.8.8}"
STREAMS="${4:-1}"
SERVERS="fra.speedtest.clouvider.net iperf.he.net"

run_one() {
	server="$1"
	iperf_out="$(mktemp)"
	ping_out="$(mktemp)"

	iperf3 -c "$server" -P "$STREAMS" -t "$DUR" -J >"$iperf_out" 2>&1 &
	iperf_pid=$!

	# give iperf3 a moment to ramp before sampling ping, matching the
	# documented harness's concurrent-load intent
	sleep 1
	ping -i 0.2 -c "$((DUR * 5 - 5))" "$TARGET" >"$ping_out" 2>&1 || true

	wait "$iperf_pid" || true

	sent_bps=$(python3 -c "
import json
try:
    d = json.load(open('$iperf_out'))
    print(d['end']['sum_sent']['bits_per_second'])
except Exception:
    print(0)
")
	retransmits=$(python3 -c "
import json
try:
    d = json.load(open('$iperf_out'))
    print(d['end']['sum_sent'].get('retransmits', 'NA'))
except Exception:
    print('NA')
")
	rm -f "$iperf_out"
	python3 - "$ping_out" "$sent_bps" "$server" "$retransmits" <<'PYEOF'
import re, sys, statistics

ping_out, sent_bps, server, retransmits = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4]
times = []
transmitted = received = 0
with open(ping_out) as f:
    for line in f:
        m = re.search(r"time=([\d.]+) ms", line)
        if m:
            times.append(float(m.group(1)))
        m = re.search(r"(\d+) packets transmitted, (\d+) (?:packets )?received", line)
        if m:
            transmitted, received = int(m.group(1)), int(m.group(2))

import os
os.remove(ping_out)

if not times or sent_bps < 1_000_000:
    print("RESULT DISCARD sent_mbit=%.2f samples=%d" % (sent_bps / 1e6, len(times)))
    sys.exit(1)

times.sort()
def pct(p):
    idx = min(len(times) - 1, int(round(p / 100.0 * (len(times) - 1))))
    return times[idx]

loss = 100.0 * (transmitted - received) / transmitted if transmitted else 100.0
print(
    "RESULT OK server=%s sent_mbit=%.2f avg=%.1f p50=%.1f p95=%.1f p99=%.1f max=%.1f loss=%.2f%% retransmits=%s n=%d"
    % (server, sent_bps / 1e6, statistics.mean(times), pct(50), pct(95), pct(99), max(times), loss, retransmits, len(times))
)
PYEOF
}

i=1
while [ "$i" -le "$REPS" ]; do
	ok=0
	for server in $SERVERS; do
		echo "--- rep $i/$REPS (server=$server) ---"
		if run_one "$server"; then
			ok=1
			break
		fi
		echo "rep $i discarded/failed on $server, trying next"
	done
	if [ "$ok" -eq 0 ]; then
		echo "rep $i FAILED on all servers, retrying same rep"
		continue
	fi
	i=$((i + 1))
done
