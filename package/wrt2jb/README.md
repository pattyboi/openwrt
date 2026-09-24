# WRT2JB — PS4 jailbreak host served from your router

Serves the **RAW GAME** browser exploit chain (upstream `raw13g/raw13g.github.io`, same
lineage as `mansoor0x/polpNO`) from an OpenWrt router on **port 8000**, so a PS4 on your LAN
can be jailbroken with GoldHEN — no PC, no internet access, no laptop left running.

On the console: open `http://<router>:8000/` in its browser. The page runs the chain and
installs GoldHEN. `http://<router>:8000/t` shows what the last run did.

This is an OpenWrt **package**, not an app or an image: it's source you add to an OpenWrt
buildroot and build into your own firmware. See [Installation](#installation).

## Why run it from the router instead of a laptop

A PS4 jailbreak is lost the moment the console powers off — the page has to be reachable
again on every boot. Your router is already the one thing on the network that's always on,
already reachable with no internet dependency, and already knows every device on your LAN.
Running the host there means: turn the PS4 on, open the bookmark, done — no laptop to dig
out, no Wi-Fi hotspot to fight with, no "wait, which port forwarding did I set up."

## Requirements

- Any OpenWrt router with `uhttpd` (the default web server — virtually every build has it).
- Tested against `mediatek/mt7622` (Linksys E8450 / Belkin RT3200); the package itself has
  no board-specific logic, but only that target has been run against real hardware so far.
  If you build and run it on something else, an issue report either way (works / doesn't) is
  useful to the next person.
- The console and the router on the same LAN. No internet access is required for the
  console side; the *router* needs internet once, at build time, to fetch the upstream chain
  and the ps4debug-NG payload.

## Installation

```sh
# from an OpenWrt buildroot checkout
git clone https://github.com/<you>/wrt2jb /tmp/wrt2jb
cp -r /tmp/wrt2jb/wrt2jb /tmp/wrt2jb/luci-app-wrt2jb package/

./scripts/feeds update -a && ./scripts/feeds install -a
make menuconfig   # Network -> wrt2jb, LuCI -> Applications -> luci-app-wrt2jb (optional)
make package/wrt2jb/{clean,compile} package/luci-app-wrt2jb/{clean,compile}
```

Then flash/sysupgrade as normal, or `opkg`/`apk install` the built package onto a router
already running a matching OpenWrt release. `luci-app-wrt2jb` is optional — `wrt2jb` alone
is enough to serve the chain and drive `binload` from the command line; the LuCI app just
adds a status page and a push button under **Services → WRT2JB**.

## What it installs

| path | what |
|---|---|
| `/www/wrt2jb/` | the chain: `index.html`, `jb.html`, `jb.js`, `core.js`, `mem.js`, `int64.js`, `rpc_worker.js`, `ps4_offsets.js`, `logo_raw.png`, `patches/{1302,1350,1352}.bin`, `goldhen.bin`, `payload2.bin` |
| `/www/wrt2jb/t` | the CGI behind `POST /t` (beacon log) and `GET /t` (status page) |
| `/www/wrt2jb/MANIFEST` | what is being served: upstream revision + sha256 of every file |
| `/etc/uci-defaults/50-wrt2jb` | adds the `uhttpd` instance `wrt2jb` (port 8000, docroot `/www/wrt2jb`, `cgi_prefix /t`) |
| `/usr/libexec/wrt2jb/binload` | `binload <host> <port> <payload>` — hands a payload to a console's GoldHEN PayLoader and prints one JSON line |
| `/usr/share/wrt2jb/payloads/` | ps4debug-NG v1.3.2 (`28829f48…`) + `MANIFEST` recording what it should hash to |
| `/etc/config/wrt2jb` | `console_ip` and `binloader_port` (the address `luci-app-wrt2jb` pushes to) |

## What a PS4 jailbreak is, and why the host is a web page

A retail PS4 runs a locked-down, FreeBSD-derived system. A **browser exploit chain** — a few
JavaScript files served from a web server — can make the console load and run code of the
operator's choosing; that's the whole point of this package. Three properties decide the
design:

* **it is lost on power-off.** The console goes back to normal the moment it's switched off,
  so the page is opened again after every boot. That's why the host must be *always on* and
  reachable without internet, DNS, or a PC: the router already is all three.
* **the console's browser is the entry**, so the host is a static web server plus one log
  endpoint. There is no agent, no daemon, and no client software on the console side.
* **a run can fail, or crash the console** (a kernel fault = automatic reboot). A failed run
  isn't damage: re-open the page and run again.

The web server is a **second `uhttpd` instance on port 8000** — deliberately not LuCI's
instance on `:80` — so nothing here can disturb the router's own admin UI, and the page's CGI
prefix (`/t`) can't collide with LuCI's.

### The console's side of the contract, in order

1. The operator opens `http://<router>:8000/` in the PS4's browser. The page (`index.html`)
   runs the chain **immediately, without a tap** — see [the AppCache note](#the-two-deliberate-changes-to-the-upstream-tree)
   below; that's intended.
2. The chain works in stages, and after each stage it POSTs a beacon to **`POST /t`**
   (hard-coded in `jb.js`) — about **240 beacons per run**. It ignores the reply.
3. On success it installs **GoldHEN** (the on-console helper that adds FTP, a payload loader,
   cheat and debug menus) into the console's memory. GoldHEN lives in RAM exactly like the
   jailbreak does.
4. On failure the console just keeps running; re-run the page. On a **kernel fault** the
   console reboots and the page must be opened again.

Beacon tags the host understands (everything else is stored verbatim and ignored):

| tag in the beacon body | meaning |
|---|---|
| `PROOF-SUMMARY-FINAL` | the run's summary; `fail=0` means clean, anything else means a partial run |
| `EG-VERDICT` | the chain's own end verdict; `jailbroken=1` means it got through |
| `JB-ROOT` | the chain reached the point where it can patch the kernel |
| `KPATCH-BLOB` | the kernel patch blob was written |
| `PAYLOAD-RUN`, `PAYLOAD-BLOB` | the final payload stage |

`GET /t` turns the log into one of four states: **JAILBROKEN** (`EG-VERDICT` says
`jailbroken=1`), **ROOT REACHED, no end verdict**, **NO JAILBREAK IN THIS LOG**, or
**NO RUN YET**.

## Binload

`binload` POSTs a payload to the console's GoldHEN PayLoader and reports the reply; 200 means
loaded. Two rules are built into it, both from direct measurement:

* **it does not use the router's `wget`.** `wget --post-file` sends the body chunked with
  `Content-Length: 0` on OpenWrt's stock BusyBox wget; the request is built by hand and
  written through `nc` instead.
* **it never probes the port with a bare connect.** A connect-and-close was measured to take
  the PayLoader listener down, so the push itself is the only probe.

**Load ps4debug only on a fresh boot whose chain run finished cleanly** — a load after an
INCOMPLETE run has faulted the console's kernel and needed a power cycle. `luci-app-wrt2jb`
shows the last proof summary and asks for confirmation before pushing when it isn't
`fail=0`; the script itself doesn't know, so honour the rule if you call it by hand.

```sh
binload 192.168.1.185 9090 /usr/share/wrt2jb/payloads/ps4debug-ng_v1.3.2_release_2026-09-20.bin
# {"ok":true,"bytes":3171952,"status":"HTTP/1.1 200 OK","message":"GoldHEN answered 200 -- payload loaded", ...}
```

Extra payloads can be dropped into `/etc/wrt2jb/payloads/` (scp) and will be listed by the
LuCI page.

The instance is separate from LuCI's on `:80`, and the log lives in RAM
(`/tmp/wrt2jb/http.jsonl`) — it survives a run, not a reboot.

## The interfaces, exactly

Anything that changes these changes what the LuCI app, the status page, and any external
tooling see.

| interface | shape |
|---|---|
| `GET /` and any static path | the served chain from `/www/wrt2jb/` (never a directory listing, never a symlink — both disabled in the instance) |
| `POST /t` | **204 No Content**; appends one NDJSON row to `/tmp/wrt2jb/http.jsonl` with keys `at`, `path`, `client`, `ua`, `status`, `body`. Body capped at 64 KB |
| `GET /t` | HTML status page (the four states above, plus what is being served) |
| `GET /t?log=1` | `application/x-ndjson` — the raw log, for tools |
| `GET /wrt2jb/MANIFEST` | generated: `package <ver>`, `source <url>`, `source_revision <sha>`, `source_date <date>`, then one `sha256 <hash> <file>` line per served asset |
| `/usr/share/wrt2jb/payloads/MANIFEST` | `sha256 <hash> <file>` for each payload the router may push to the console |
| `binload <host> <port> <payload>` | prints **exactly one** JSON object on stdout — `{"ok":bool,"bytes":n,"status":"...","message":"..."}` — and exits 0 **only** on HTTP 200 |
| `uci show wrt2jb` | `wrt2jb.main.console_ip` (the console's address) and `wrt2jb.main.binloader_port` (default 9090) |
| `uci show uhttpd.wrt2jb` | the host instance: `home=/www/wrt2jb`, `listen_http=0.0.0.0:8000`, `cgi_prefix=/t`, `index_page=index.html`, `no_symlinks=1`, `no_dirlists=1`, `max_requests=3` |

`max_requests 3` bounds how many beacons can spawn a CGI at once — a run posts hundreds, and
without the bound they'd pile up.

## The two deliberate changes to the upstream tree

1. **The AppCache is removed** (`patches/001-serve-without-appcache.patch` strips
   `manifest="cache.appcache"` from `index.html` and `jb.html`; `cache.appcache` is not
   installed). This is a measured failure, not tidiness: with the manifest in place the
   console downloads an update and then keeps serving the **old** `jb.js` and the **old**
   payload until someone taps "UPDATE READY" — a chain can run stale without any visible
   sign of it. Patch, not `sed`, so that an upstream edit to those lines fails the build
   instead of silently restoring the trap.
2. **Nothing else.** No offset, no gadget, no payload byte is touched.

## The rules that are measurements, not preferences

1. **Never probe the console's payload port (9090) with a bare connect.** A connect-and-close
   was measured to take GoldHEN's PayLoader listener down. `binload` only ever speaks the
   real protocol, and its own answer is the probe.
2. **Never push `ps4debug` after an incomplete run.** A push after a partial chain run has
   faulted the console's kernel (page fault in kernel mode) and needed a power cycle.
   `luci-app-wrt2jb` enforces this as a confirmation; `binload` by hand does not — honour it
   yourself.
3. **Never let the AppCache back in.** With the manifest in place the console keeps executing
   a *stale* chain and a stale payload until an operator taps "UPDATE READY". That's what
   `patches/001` prevents, and it's a patch rather than a `sed` on purpose: if upstream edits
   those lines the **build fails** instead of silently restoring the trap.
4. **Pin a full commit sha, never a branch.** The served bytes *are* the exploit; a moving
   branch means the artifact changes without review.
5. **The payload the router pushes is not the payload the chain installs.** The chain installs
   GoldHEN; `binload` pushes *ps4debug-NG* (a debug server) — and only ever to a console that
   is already jailbroken by that chain.

## Updating the pinned upstream revision

```sh
# in the OpenWrt tree
sed -i 's/^PKG_SOURCE_VERSION:=.*/PKG_SOURCE_VERSION:=<new sha>/' package/wrt2jb/Makefile
sed -i 's/^PKG_SOURCE_DATE:=.*/PKG_SOURCE_DATE:=<date>/'        package/wrt2jb/Makefile
make package/wrt2jb/clean package/wrt2jb/compile
```

Pin the full commit sha, never a branch. The revision this package currently serves is
`ef1670a8db0beb49b942dfacced6edbc5225f47c` (2026-09-22, *"aio fix thanks to MODDED_WARFARE and
Al-Azif"* — see [Credits](#credits--attribution)). Never edit the served files in place: they
are the artifact, not source to hand-patch.

## Serving a payload we built instead

The upstream revision ships an **unidentified** GoldHEN build. If you've built or verified a
specific GoldHEN binary yourself and want the chain to install *that* one instead:

```sh
make package/wrt2jb/compile WRT2JB_PAYLOAD=/path/to/goldhen.bin
```

It's installed as both `goldhen.bin` and `payload2.bin` (the chain picks one by firmware),
and the change shows up in `/www/wrt2jb/MANIFEST` and on the status page.

## Checking what the router actually serves

```sh
curl -s http://<router>:8000/wrt2jb/MANIFEST                    # package, source, revision, and a sha256 per file
curl -s http://<router>:8000/wrt2jb/MANIFEST | sha256sum -c -    # verify every listed file against what's actually served
```

`uclient-fetch`/`wget` work in place of `curl` for the fetch if you're running this from
another OpenWrt box (BusyBox doesn't ship `curl`).

## Testing without a console

```sh
curl -s http://localhost:8000/wrt2jb/MANIFEST                 # what is being served
curl -s -X POST --data 'PS4-JB&tag=EG-VERDICT&detail=jailbroken%3D1' localhost:8000/t
curl -s 'localhost:8000/t?log=1'                             # the row you just wrote
curl -s localhost:8000/t | grep -o 'JAILBROKEN'              # the state it renders
nc -l -p 9090 & binload 127.0.0.1 9090 /usr/share/wrt2jb/payloads/*.bin   # stand-in PayLoader
```

`curl` is not installed by default in a minimal OpenWrt image; `uclient-fetch` or `wget` work
for the `GET`s, and the `POST` can be done with `nc`/`printf` exactly as `binload` does it.
The LuCI page has the same checks behind a button, and `ubus call luci.wrt2jb status` gives
the same facts as the page.

## Safe-change recipes

* **Upstream moves** → set `PKG_SOURCE_VERSION`/`PKG_SOURCE_DATE` in `package/wrt2jb/Makefile`,
  then `make package/wrt2jb/clean package/wrt2jb/compile`, then re-check the served bytes with
  the `curl … | sha256sum -c -` recipe above. Never edit the served files in place.
* **Serve a GoldHEN build you've verified instead of upstream's** →
  `make package/wrt2jb/compile WRT2JB_PAYLOAD=/path/to/goldhen.bin` (installed as both
  `goldhen.bin` and `payload2.bin`, and reflected in the MANIFEST).
* **Add a payload to the push list** → drop it in `/etc/wrt2jb/payloads/` (scp); the LuCI page
  lists it. The sha256 in `.../payloads/MANIFEST` is what the page compares against.
* **Change the console's address or port** → LuCI page (*Save address*) or
  `ubus call luci.wrt2jb save_config '{"console_ip":"192.168.1.185","binloader_port":9090}'`.
* **Move the host off port 8000** → edit the `uhttpd.wrt2jb` instance in
  `/etc/uci-defaults/50-wrt2jb`, reinstall, `/etc/init.d/uhttpd reload`. The port is part of
  the console's bookmark, so update that too.

## When something looks wrong

| symptom | first thing to check |
|---|---|
| `GET /t` says NO RUN YET although a run happened | the console used a different host or port, or the beacon went to another server; an empty `GET /t?log=1` means the CGI never ran ⇒ check the `uhttpd.wrt2jb` instance is enabled and listening on :8000 |
| a run reports `fail!=0` and the console is fine | re-run the page from the console; then read the log before pushing anything (see [rules](#the-rules-that-are-measurements-not-preferences)) |
| console rebooted by itself mid-run | that's a kernel fault and it's recoverable — re-open the page. Copy `/tmp/wrt2jb/http.jsonl` off the router first if the run matters |
| LuCI page missing after install | the app's `postinst` clears LuCI's cache and reloads rpcd; if it's still missing, `rm -rf /tmp/luci-*` and reload rpcd |
| `binload` says "no reply" but bytes went out | the payload was written; GoldHEN may still have loaded it. Check the console (FTP on 2121 should be up) before pushing again |

## Credits & attribution

None of the actual jailbreak is this package's work — it serves other people's research and
takes pains not to touch it. In rough dependency order:

* **The RAW GAME chain** — [`raw13g/raw13g.github.io`](https://github.com/raw13g/raw13g.github.io),
  same lineage as [`mansoor0x/polpNO`](https://github.com/mansoor0x/polpNO). The pinned
  revision (`ef1670a8…`, 2026-09-22) carries the commit message *"aio fix thanks to
  MODDED_WARFARE and Al-Azif"* — credit where upstream put it.
* **GoldHEN** — the PS4 homebrew enabler this chain installs, by
  [SiSTRo](https://github.com/SiSTR0) and contributors:
  [ctn123](https://github.com/ctn123), [Shinigami](https://github.com/ScriptSK), and the rest
  of the team credited at [GoldHEN/GoldHEN](https://github.com/GoldHEN/GoldHEN). GoldHEN is
  closed-source and distributed as signed binaries by its own author; this package serves
  whatever binary the pinned RAW GAME revision bundles, unmodified.
* **ps4debug-NG** — [Pharaoh2k/ps4debug-NG](https://github.com/Pharaoh2k/ps4debug-NG),
  GPL-3.0, an independent reimplementation of Ctn's `ps4debug`. Fetched at build time from a
  hash-pinned upstream release, never vendored into this repository.
* **OpenWrt & LuCI** — the platform this package builds on and integrates with.

If you're one of the people above and want something here changed — credit, attribution
wording, or a request to stop redistributing — open an issue.

## Legal / safety

* **This is for homebrew, backups, and running your own code on hardware you own.** It is
  not a piracy tool and doesn't support one; how you use a jailbroken console is on you.
* **Jailbreaking can crash your console.** A failed exploit run is recoverable (power-cycle
  and try again); a bad payload push after an incomplete run has faulted a console's kernel
  in testing. Follow the rules above.
* **It almost certainly voids your warranty and may violate the console's terms of service.**
  Know your own jurisdiction's rules before you do this.
* **No warranty, express or implied** — see [LICENSE](LICENSE). This is offered as-is,
  by hobbyists, for hobbyists.

## License

This package's own code (the OpenWrt Makefile, `binload`, the `/t` CGI, and the uci-defaults
wiring) is MIT-licensed — see [LICENSE](LICENSE). The RAW GAME chain, GoldHEN, and
ps4debug-NG are **not** this project's code and are not covered by that license; see
[Credits & attribution](#credits--attribution) and each project's own repository for their
terms.
