# luci-app-wrt2jb — WRT2JB (PS4 jailbreak host), from LuCI

A page under **Services → WRT2JB** that shows what the router's jailbreak host is serving and
what the last chain run did, and hands a payload to a console's GoldHEN PayLoader with one
button.

The actual mechanism lives in the [`wrt2jb`](../wrt2jb/README.md) package
(`usr/libexec/wrt2jb/binload`, the ps4debug-NG payload, `/etc/config/wrt2jb`); this package
is a LuCI control surface on top of it and depends on it.

**Read [`wrt2jb`'s own README](../wrt2jb/README.md) first.** It carries the console side of
the contract, every endpoint and its exact shape, the rules that are measurements rather
than preferences, how to test without a console, and how to recover when a run faults —
everything this page talks to.

## Installation

`luci-app-wrt2jb` is a standard LuCI app package; it installs alongside `wrt2jb` (see that
package's [Installation](../wrt2jb/README.md#installation) section) and is selected the same
way — `make menuconfig` → LuCI → Applications → `luci-app-wrt2jb`. `luci-base` and `wrt2jb`
are pulled in automatically as dependencies.

## What it installs

| path | what |
|---|---|
| `/www/luci-static/resources/view/wrt2jb/binload.js` | the page |
| `/usr/share/rpcd/ucode/wrt2jb.uc` | the backend: ubus object `luci.wrt2jb` with `status`, `binload`, `save_config` |
| `/usr/share/rpcd/acl.d/luci-app-wrt2jb.json` | ACL: `status` is read, `binload`/`save_config` are write |
| `/usr/share/luci/menu.d/luci-app-wrt2jb.json` | the menu entry under Services |

## What the page shows

* **Served chain** — package version, upstream revision, the GoldHEN sha256 being served, the
  page URL, and the last run's verdict from the host's beacon log.
* **Last run** — the last beacon's detail, i.e. what the chain said last.
* **Console** — the address and binloader port (editable, saved with *Save address*), whether
  the console answers **ping**, and which payload would be pushed.
* **Result** — the last push: loaded or not, the HTTP status, the byte count, and whether the
  file's sha256 is the one this package was built against.

## Why the push looks the way it does

The push is the same delivery route jailbreakers already use by hand against GoldHEN's
PayLoader — this button just moves that route onto the router. It doesn't change what the
payload does.

* **It is the real POST, never a port probe.** A connect-and-close to GoldHEN's PayLoader was
  measured to take the listener down, so there is no "is 9090 open?" check anywhere; the push
  is the probe and its answer is the status.
* **A dirty boot is refused without a confirmation.** Loading ps4debug-NG after an INCOMPLETE
  chain run has faulted the kernel (`Fatal trap 12: page fault while in kernel mode`) and
  needed a power cycle. The page shows the last `PROOF-SUMMARY-FINAL` with a clean/dirty mark,
  warns when it isn't `fail=0`, and asks before pushing — *load ps4debug only on a fresh boot
  whose chain run completed cleanly*, made visible. The flag comes from the router's beacon
  log, so it's about the last run the router saw; it can't see a reboot it didn't witness.
* **It does not use the router's `wget`.** `wget --post-file` sends the body chunked with
  `Content-Length: 0` on OpenWrt's stock BusyBox wget, so `binload` builds the request by hand
  and writes it through `nc`.
* **The browser never sends a path.** The payload picker lists files the backend itself found
  under `/usr/share/wrt2jb/payloads/` and `/etc/wrt2jb/payloads/`; the name is resolved to a
  path server-side, and the address and port are validated before anything runs.

## Calling it without the UI

```sh
ubus call luci.wrt2jb status
ubus call luci.wrt2jb binload '{"host":"192.168.1.185","port":9090,"payload":"ps4debug-ng_v1.3.2_release_2026-09-20.bin"}'
ubus call luci.wrt2jb save_config '{"console_ip":"192.168.1.185","binloader_port":9090}'
```

## Credits, legal, and license

See [`wrt2jb`'s README](../wrt2jb/README.md#credits--attribution) for full credits to the
RAW GAME chain, GoldHEN, and ps4debug-NG authors, and its
[Legal / safety](../wrt2jb/README.md#legal--safety) section before you use this against a
real console. This package's own code is MIT-licensed — see [LICENSE](LICENSE); it grants no
rights over the jailbreak host it controls or the third-party content that host serves.
