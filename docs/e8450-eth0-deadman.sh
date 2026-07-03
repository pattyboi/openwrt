#!/bin/sh
# eth0 down/up reproduction with self-recovering deadman.
# Deploy to /tmp/t2.sh on the router, then:
#   setsid /tmp/t2.sh </dev/null >/dev/null 2>&1 &
# Requires debug kernel (DETECT_HUNG_TASK) for automatic stack dumps.

rm -f /tmp/t2.done

# fast hung-task reporting into the ramoops console
echo 30 > /proc/sys/kernel/hung_task_timeout_secs 2>/dev/null
dmesg -n 8

(
	sleep 3
	echo "T2-DOWN t=$(cat /proc/uptime)" > /dev/kmsg
	ip link set eth0 down
	sleep 3
	echo "T2-UP-START t=$(cat /proc/uptime)" > /dev/kmsg
	ip link set eth0 up
	echo "T2-UP-DONE t=$(cat /proc/uptime)" > /dev/kmsg
	touch /tmp/t2.done
) &

(
	# deadman: give khungtaskd time for 2+ dump cycles, then warm-reset.
	sleep 180
	if [ ! -e /tmp/t2.done ]; then
		echo "T2-DEADMAN-FIRING reboot -f" > /dev/kmsg
		sync
		reboot -f
	fi
) &
wait
