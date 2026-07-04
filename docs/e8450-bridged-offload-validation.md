# E8450 Bridged Offload Validation

Purpose: prove that the `999-ppe-89/90/91` bridged-flow offload path does
more than boot and compile, and that real bridged LAN/WLAN traffic becomes
`BIND` entries in the MT7622 PPE.

## What counts as success

Success is not just:

- `nft list ruleset` showing a flowtable
- normal Linux bridge forwarding working
- traffic counters moving on `br-lan`

Success is:

- a real bridged client-to-client flow across `br-lan`
- matching `BIND` entries appearing in `/sys/kernel/debug/ppe0/entries`
- those entries persisting while traffic is active and packet/byte counters
  climbing in silicon

## Recommended topology

Use two clients on the same subnet behind `br-lan`:

- one wired LAN client on `lan1`..`lan4`
- one Wi-Fi client on `wl0-ap0` or `wl1-ap0`

Best traffic shape:

- long-lived `iperf3`
- sustained HTTP transfer
- continuous ping is acceptable as a smoke test but not ideal for binding

## Router helper

This tree now ships a router-side helper:

- `e8450-bridge-offload-bench`

It creates a temporary nftables `inet bench` flowtable using the current
`br-lan` member devices plus `wan`, then watches PPE entries.

Subcommands:

- `setup`
- `watch [seconds]`
- `status`
- `teardown`

The helper discovers bridge members dynamically from `/sys/class/net/br-lan`,
so it does not hardcode `wl0-ap0` or `wl1-ap0`.

## Validation steps

1. On the router:
   `e8450-bridge-offload-bench setup`

2. Confirm the temporary table:
   `e8450-bridge-offload-bench status`

3. Start sustained bridged traffic between the two clients.

4. On the router, watch PPE entries:
   `e8450-bridge-offload-bench watch 60`

5. Optional tighter filter while watching:
   `grep ' BIND ' /sys/kernel/debug/ppe0/entries`

6. Tear down the temporary bench table when done:
   `e8450-bridge-offload-bench teardown`

## What to look for

Expected signal:

- `BIND` entries, not only `UNB`
- client IPs from the bridged pair in `orig=` / `new=`
- counters increasing while the transfer is active

Useful supporting checks:

- `bridge fdb show br br-lan`
- `iw dev wl0-ap0 station dump` or `iw dev wl1-ap0 station dump`
- `nft list table inet bench`

## Failure interpretation

If bridge traffic works but PPE never shows `BIND` entries:

- the traffic is staying in the software bridge path
- the nft flowtable is missing a required ingress device
- the traffic shape is too short-lived to bind
- the bridged-flow patch path is not taking effect at runtime

If `BIND` entries appear only for routed traffic and never for bridged traffic,
the `999-ppe-90` path still needs investigation despite boot success.
