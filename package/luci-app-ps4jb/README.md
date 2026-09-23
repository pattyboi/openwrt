# luci-app-ps4jb — the PS4 jailbreak host, from LuCI

A page under **Services → PS4 jailbreak** that shows what the router's jailbreak host is serving and
what the last chain run did, and hands a payload to a console's GoldHEN PayLoader with one button.

The mechanism lives in the `ps4jb` package (`usr/libexec/ps4jb/binload`, the ps4debug-NG payload,
`/etc/config/ps4jb`); this package is the control surface and depends on it.

**Working in this repo only?** `package/ps4jb/README.md` § *"If you only have this repo — the whole
picture"* carries the console side of the contract, every endpoint and its exact shape, the rules
that are measurements rather than preferences, how to test without a console, and how to recover when
a run faults. Read it before changing anything this page talks to.

## What it installs

| path | what |
|---|---|
| `/www/luci-static/resources/view/ps4jb/binload.js` | the page |
| `/usr/share/rpcd/ucode/ps4jb.uc` | the backend: ubus object `luci.ps4jb` with `status`, `binload`, `save_config` |
| `/usr/share/rpcd/acl.d/luci-app-ps4jb.json` | ACL: `status` is read, `binload`/`save_config` are write |
| `/usr/share/luci/menu.d/luci-app-ps4jb.json` | the menu entry under Services |

## What the page shows

* **Served chain** — package version, upstream revision, the GoldHEN sha256 being served, the page URL,
  and the last run's verdict from the host's beacon log.
* **Last run** — the last beacon's detail, i.e. what the chain said last.
* **Console** — the address and binloader port (editable, saved with *Save address*), whether the
  console answers **ping**, and which payload would be pushed.
* **Result** — the last push: loaded or not, the HTTP status, the byte count, and whether the file's
  sha256 is the one this package was built against.

## Why the push looks the way it does

This is the same delivery route the PS4 corpus has already used by hand — `tools/goldhen_push.py` to
GoldHEN's PayLoader — and it is how the corpus got its 13.52 kernel image (ps4debug-NG v1.3.2, pushed
2026-09-20, `save-injection/work/ps4debug-ng-01/`). The button moves that route onto the router; it does
not change what the payload does.

* **It is the real POST, never a port probe.** A connect-and-close to GoldHEN's PayLoader was measured
  to take the listener down, so there is no "is 9090 open?" check anywhere; the push is the probe and
  its answer is the status.
* **A dirty boot is refused without a confirmation.** Loading ps4debug-NG after an INCOMPLETE chain run
  faulted the kernel on 2026-09-20 (`Fatal trap 12: page fault while in kernel mode`) and needed a power
  cycle. The page shows the last `PROOF-SUMMARY-FINAL` with a clean/dirty mark, warns when it is not
  `fail=0`, and asks before pushing — the corpus's rule, *load ps4debug only on a fresh boot whose chain
  run completed cleanly*, made visible. The flag comes from the router's beacon log, so it is about the
  last run the router saw; it cannot see a reboot it did not witness.
* **It does not use the router's `wget`.** `wget --post-file` sends the body chunked with
  `Content-Length: 0` on this firmware, so `binload` builds the request by hand and writes it through
  `nc`.
* **The browser never sends a path.** The payload picker lists files the backend itself found under
  `/usr/share/ps4jb/payloads/` and `/etc/ps4jb/payloads/`; the name is resolved to a path server-side,
  and the address and port are validated before anything runs.

## Calling it without the UI

```sh
ubus call luci.ps4jb status
ubus call luci.ps4jb binload '{"host":"192.168.1.185","port":9090,"payload":"ps4debug-ng_v1.3.2_release_2026-09-20.bin"}'
ubus call luci.ps4jb save_config '{"console_ip":"192.168.1.185","binloader_port":9090}'
```
