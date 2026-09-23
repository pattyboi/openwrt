# ps4jb — PS4 jailbreak host served from the router

Serves the **RAW GAME** browser chain (upstream `raw13g/raw13g.github.io`, the same tree as
`mansoor0x/polpNO`) from the router on **port 8000**, so a PS4 on the LAN can be jailbroken
with GoldHEN without a PC and without internet access.

On the console: open `http://<router>:8000/` in the browser. The page runs the chain and
installs the payload. `http://<router>:8000/t` shows what the last run did.

## What it installs

| path | what |
|---|---|
| `/www/ps4jb/` | the chain: `index.html`, `jb.html`, `jb.js`, `core.js`, `mem.js`, `int64.js`, `rpc_worker.js`, `ps4_offsets.js`, `logo_raw.png`, `patches/{1302,1350,1352}.bin`, `goldhen.bin`, `payload2.bin` |
| `/www/ps4jb/t` | the CGI behind `POST /t` (beacon log) and `GET /t` (status page) |
| `/www/ps4jb/MANIFEST` | what is being served: upstream revision + sha256 of every file |
| `/etc/uci-defaults/50-ps4jb` | adds the `uhttpd` instance `ps4jb` (port 8000, docroot `/www/ps4jb`, `cgi_prefix /t`) |
| `/usr/libexec/ps4jb/binload` | `binload <host> <port> <payload>` — hands a payload to a console's GoldHEN PayLoader and prints one JSON line |
| `/usr/share/ps4jb/payloads/` | ps4debug-NG v1.3.2 (`28829f48…`) + `MANIFEST` recording what it should hash to |
| `/etc/config/ps4jb` | `console_ip` and `binloader_port` (the address `luci-app-ps4jb` pushes to) |

## Binload

`binload` POSTs the payload to the console's GoldHEN PayLoader and reports the reply; 200 means loaded.
Two rules are built into it, both from measurement:

* **it does not use the router's `wget`.** `wget --post-file` sends the body chunked with
  `Content-Length: 0` on this firmware; the request is built by hand and written through `nc`, which is
  the shape `tools/goldhen_push.py` in the PS4 corpus sends.
* **it never probes the port with a bare connect.** A connect-and-close was measured to take the
  PayLoader listener down, so the push itself is the only probe.

This is the route the PS4 corpus already used by hand to get its 13.52 kernel image
(`save-injection/work/ps4debug-ng-01/`). **Load ps4debug only on a fresh boot whose chain run finished
cleanly** — a load after an INCOMPLETE run faulted the kernel on 2026-09-20 and needed a power cycle.
`luci-app-ps4jb` shows the last proof summary and asks before pushing when it is not `fail=0`; the
script itself does not know, so honour the rule if you call it by hand.

```sh
binload 192.168.1.185 9090 /usr/share/ps4jb/payloads/ps4debug-ng_v1.3.2_release_2026-09-20.bin
# {"ok":true,"bytes":3171952,"status":"HTTP/1.1 200 OK","message":"GoldHEN answered 200 -- payload loaded", ...}
```

Extra payloads can be dropped into `/etc/ps4jb/payloads/` (scp) and will be listed by the LuCI page.

The instance is separate from LuCI's on :80, and the log lives in RAM (`/tmp/ps4jb/http.jsonl`)
— it survives a run, not a reboot.

## The two deliberate changes to the upstream tree

1. **The AppCache is removed** (`patches/001-serve-without-appcache.patch` strips
   `manifest="cache.appcache"` from `index.html` and `jb.html`; `cache.appcache` is not
   installed). This is a measured failure, not tidiness: with the manifest in place the
   console downloads an update and then keeps serving the **old** `jb.js` and the **old**
   payload until someone taps "UPDATE READY" — two runs silently executed a stale chain
   because of it. Patch, not `sed`, so that an upstream edit to those lines fails the build
   instead of silently restoring the trap.
2. **Nothing else.** No offset, no gadget, no payload byte is touched.

## Updating it

```sh
# in the OpenWrt tree
sed -i 's/^PKG_SOURCE_VERSION:=.*/PKG_SOURCE_VERSION:=<new sha>/' package/ps4jb/Makefile
sed -i 's/^PKG_SOURCE_DATE:=.*/PKG_SOURCE_DATE:=<date>/'        package/ps4jb/Makefile
make package/ps4jb/clean package/ps4jb/compile
```

Pin the full commit sha, never a branch. The revision the package currently serves is
`ef1670a8db0beb49b942dfacced6edbc5225f47c` (2026-09-22, *"aio fix thanks to MODDED_WARFARE and
Al-Azif"*); the PS4 corpus assessed it in `docs/59` and `intel/raw13g-upstream/README.md` §11.

## Serving a payload we built instead

The upstream revision ships an **unidentified** GoldHEN build (293,120 B, `df3f27c1…`); the
build our own console has run is GoldHEN 2.4b18.11 (291,072 B, `48d46667…`). To serve a
specific blob:

```sh
make package/ps4jb/compile PS4JB_PAYLOAD=/path/to/goldhen.bin
```

It is installed as both `goldhen.bin` and `payload2.bin` (the chain picks one by firmware),
and the change shows up in `/www/ps4jb/MANIFEST` and on the status page.

## Checking what the router actually serves

From the PS4 corpus:

```sh
python3 tools/ps4jb_check.py --host 192.168.1.1        # fetch, hash, compare against the assessment
```

## If you only have this repo — the whole picture

Everything below is for an agent working **only** in the OpenWrt tree, with no access to the PS4
research corpus. It is the part of the design that is not visible from this package's code.

### What a PS4 jailbreak is, and why the host is a web page

A retail PS4 runs a locked-down, FreeBSD-derived system. A **browser exploit chain** — a few
JavaScript files served from a web server — can make the console load and run code of the operator's
choosing; that is the whole point of this package. Three properties decide the design:

* **it is lost on power-off.** The console goes back to normal the moment it is switched off, so the
  page is opened again after every boot. That is why the host must be *always on* and reachable
  without internet, DNS, or a PC: the router already is all three.
* **the console's browser is the entry**, so the host is a static web server plus one log endpoint.
  There is no agent, no daemon and no client software on the console side.
* **a run can fail, or crash the console** (a kernel fault = automatic reboot). A failed run is not
  damage: re-open the page and run again.

The web server is a **second `uhttpd` instance on port 8000** — deliberately not LuCI's instance on
:80 — so nothing here can disturb the router's own UI, and the page's CGI prefix (`/t`) cannot
collide with LuCI's.

### The console's side of the contract, in order

1. The operator opens `http://<router>:8000/` in the PS4's browser. The page (`index.html`) runs the
   chain **immediately, without a tap** — see the AppCache note above; that is intended.
2. The chain works in stages, and after each stage it POSTs a beacon to **`POST /t`**
   (hard-coded in `jb.js`) — about **240 beacons per run**. It ignores the reply.
3. On success it installs **GoldHEN** (the on-console helper that adds FTP, a payload loader, cheat
   and debug menus) into the console's memory. GoldHEN lives in RAM exactly like the jailbreak does.
4. On failure the console just keeps running; re-run the page. On a **kernel fault** the console
   reboots and the page must be opened again.

Beacon tags the host understands (everything else is stored verbatim and ignored):

| tag in the beacon body | meaning |
|---|---|
| `PROOF-SUMMARY-FINAL` | the run's summary; `fail=0` means clean, anything else means a partial run |
| `EG-VERDICT` | the chain's own end verdict; `jailbroken=1` means it got through |
| `JB-ROOT` | the chain reached the point where it can patch the kernel |
| `KPATCH-BLOB` | the kernel patch blob was written |
| `PAYLOAD-RUN`, `PAYLOAD-BLOB` | the final payload stage |

`GET /t` therefore turns the log into one of four states: **JAILBROKEN** (`EG-VERDICT` says
`jailbroken=1`), **ROOT REACHED, no end verdict**, **NO JAILBREAK IN THIS LOG**, or **NO RUN YET**.

### The interfaces, exactly

These are the contract. Anything that changes them changes what the LuCI app, the status page and the
PS4-side tooling see.

| interface | shape |
|---|---|
| `GET /` and any static path | the served chain from `/www/ps4jb/` (never a directory listing, never a symlink — both disabled in the instance) |
| `POST /t` | **204 No Content**; appends one NDJSON row to `/tmp/ps4jb/http.jsonl` with keys `at`, `path`, `client`, `ua`, `status`, `body`. Body capped at 64 KB |
| `GET /t` | HTML status page (the four states above, plus what is being served) |
| `GET /t?log=1` | `application/x-ndjson` — the raw log, for tools |
| `GET /ps4jb/MANIFEST` | generated: `package <ver>`, `source <url>`, `source_revision <sha>`, `source_date <date>`, then one `sha256 <hash> <file>` line per served asset, `patches/{1302,1350,1352}.bin`, `goldhen.bin`, `payload2.bin` |
| `/usr/share/ps4jb/payloads/MANIFEST` | `sha256 <hash> <file>` for each payload the router may push to the console |
| `binload <host> <port> <payload>` | prints **exactly one** JSON object on stdout — `{"ok":bool,"bytes":n,"status":"...","message":"..."}` — and exits 0 **only** on HTTP 200 |
| `uci show ps4jb` | `ps4jb.main.console_ip` (the console's address) and `ps4jb.main.binloader_port` (default 9090) |
| `uci show uhttpd.ps4jb` | the host instance: `home=/www/ps4jb`, `listen_http=0.0.0.0:8000`, `cgi_prefix=/t`, `index_page=index.html`, `no_symlinks=1`, `no_dirlists=1`, `max_requests=3` |

The log is **RAM-only** (`/tmp`): it survives a run, not a reboot. `max_requests 3` bounds how many
beacons can spawn a CGI at once — a run posts hundreds, and without the bound they would pile up.

### The rules that are measurements, not preferences

1. **Never probe the console's payload port (9090) with a bare connect.** A connect-and-close was
   measured to take GoldHEN's PayLoader listener down. `binload` therefore only ever speaks the real
   protocol, and its own answer is the probe.
2. **Never push `ps4debug` after an incomplete run.** A push after a partial chain run faulted the
   console's kernel (page fault in kernel mode) and needed a power cycle. `luci-app-ps4jb` enforces
   this as a confirmation; `binload` by hand does not — honour it yourself.
3. **Never let the AppCache back in.** With the manifest in place the console keeps executing a
   *stale* chain and a stale payload until an operator taps "UPDATE READY". That is what
   `patches/001` prevents, and it is a patch rather than a `sed` on purpose: if upstream edits those
   lines the **build fails** instead of silently restoring the trap.
4. **Pin a full commit sha, never a branch.** The served bytes *are* the exploit; a moving branch
   means the artifact changes without review.
5. **The payload the router pushes is not the payload the chain installs.** The chain installs
   GoldHEN; `binload` pushes *ps4debug-NG* (a debug server) — and only ever to a console that is
   already jailbroken by that chain.

### Testing without a console

```sh
curl -s http://localhost:8000/ps4jb/MANIFEST                 # what is being served
curl -s -X POST --data 'PS4-JB&tag=EG-VERDICT&detail=jailbroken%3D1' localhost:8000/t
curl -s 'localhost:8000/t?log=1'                             # the row you just wrote
curl -s localhost:8000/t | grep -o 'JAILBROKEN'              # the state it renders
nc -l -p 9090 & binload 127.0.0.1 9090 /usr/share/ps4jb/payloads/*.bin   # stand-in PayLoader
```

`curl` is not installed by default in a minimal image; `uclient-fetch` or `wget` work for the `GET`s,
and the `POST` can be done with `nc`/`printf` exactly as `binload` does it. The LuCI page has the same
checks behind a button, and `ubus call luci.ps4jb status` gives the same facts as the page.

### Where the rest of the knowledge lives

This repo is the *serving* half only. The console-side research, the assessment of the pinned
revision, and the tooling that reads these endpoints live in the PS4 corpus on the staging machine:

| what | where |
|---|---|
| the host's design, deployment and run record | `ps4/docs/59-the-router-jailbreak-host.md`, `ps4/save-injection/work/router-jbhost-01/` |
| the pinned revision, byte-verified, with its patch blob disassembled | `ps4/intel/raw13g-upstream/` (README §11) |
| the AppCache failure this package patches around | `ps4/docs/37` §2b |
| independent hash check of what the router serves | `ps4/tools/ps4jb_check.py --host <router>` |
| reads the beacon log and prints a verdict | `ps4/tools/chain_verdict.py --run-dir <dir>` |
| the payload this package ships, and why it needs a clean run | `ps4/intel/ps4debug-ng-upstream/` |

### Safe-change recipes

* **Upstream moves** → set `PKG_SOURCE_VERSION`/`PKG_SOURCE_DATE` in `package/ps4jb/Makefile`, then
  `make package/ps4jb/clean package/ps4jb/compile`, then re-check the served bytes with the PS4-side
  `tools/ps4jb_check.py`. Never edit the served files in place: they are the artifact.
* **Serve the GoldHEN build *we* have run instead of upstream's** →
  `make package/ps4jb/compile PS4JB_PAYLOAD=/path/to/goldhen.bin` (installed as both `goldhen.bin`
  and `payload2.bin`, and reflected in the MANIFEST).
* **Add a payload to the push list** → drop it in `/etc/ps4jb/payloads/` (scp); the LuCI page lists it.
  The sha256 in `.../payloads/MANIFEST` is what the page compares against.
* **Change the console's address or port** → LuCI page (*Save address*) or
  `ubus call luci.ps4jb save_config '{"console_ip":"192.168.1.185","binloader_port":9090}'`.
* **Move the host off port 8000** → edit the `uhttpd.ps4jb` instance in
  `/etc/uci-defaults/50-ps4jb`, reinstall, `/etc/init.d/uhttpd reload`; tell the PS4-side owner,
  because the port is part of the console's bookmark and of `tools/ps4jb_check.py`'s default.

### When something looks wrong

| symptom | first thing to check |
|---|---|
| `GET /t` says NO RUN YET although a run happened | the console used a different host or port, or the beacon went to another server; an empty `GET /t?log=1` means the CGI never ran ⇒ check the `uhttpd.ps4jb` instance is enabled and listening on :8000 |
| a run reports `fail!=0` and the console is fine | re-run the page from the console; then read the log before pushing anything (rule 2) |
| console rebooted by itself mid-run | that is a kernel fault and it is recoverable — re-open the page. Copy `/tmp/ps4jb/http.jsonl` off the router first if the run matters |
| LuCI page missing after install | the app's `postinst` clears LuCI's cache and reloads rpcd; if it is still missing, `rm -rf /tmp/luci-*` and reload rpcd |
| `binload` says "no reply" but bytes went out | the payload was written; GoldHEN may still have loaded it. Check the console (FTP on 2121 should be up) before pushing again |
