#!/usr/bin/env ucode
/*
 * The backend behind the LuCI binload control (luci-app-wrt2jb).
 *
 * rpcd loads this file because it lives in /usr/share/rpcd/ucode; it exposes the ubus
 * object `luci.wrt2jb` with three methods:
 *
 *   status        what the router knows: the served chain, the last run from the beacon
 *                 log, the console's address, the payloads on disk and the last push
 *   binload       hand a payload to the console's GoldHEN PayLoader (the real POST --
 *                 see usr/libexec/wrt2jb/binload for why it is not a port probe)
 *   save_config   write the console address back to /etc/config/wrt2jb
 *
 * Everything here reads local state or runs a local command; the only network traffic is
 * the push itself, which the console has to answer.
 */
'use strict';

import { cursor } from 'uci';
import * as fs from 'fs';

const HOST_MANIFEST = '/www/wrt2jb/MANIFEST';
const PAYLOAD_MANIFEST = '/usr/share/wrt2jb/payloads/MANIFEST';
const LOG = '/tmp/wrt2jb/http.jsonl';
const LAST_PUSH = '/tmp/wrt2jb/last-push.json';
const BINLOAD = '/usr/libexec/wrt2jb/binload';
const PAYLOAD_DIRS = [ '/usr/share/wrt2jb/payloads', '/etc/wrt2jb/payloads' ];

/* This host's own address for the status-page link. Read the router's actual
   LAN address so the link is right on any OpenWrt router, not just one
   pre-configured at the stock 192.168.1.1 default. */
function host_url() {
	const uci = cursor();
	let addr = uci.get('network', 'lan', 'ipaddr');
	uci.unload();
	if (type(addr) == 'array') addr = addr[0];
	return 'http://' + ((addr != null && length(addr)) ? addr : '192.168.1.1') + ':8000/';
}

function readfile(path) {
	try { return fs.readfile(path); } catch (e) { return null; }
}

/* ---- the served tree's own manifest, and the payloads' ---- */

function sha_lines(path) {
	const out = {};
	const text = readfile(path);
	if (text == null) return out;
	const lines = split(text, '\n');
	for (let i = 0; i < length(lines); i++) {
		const m = match(lines[i], /^sha256 ([0-9a-f]{64}) (\S+)$/);
		if (m) out[m[2]] = m[1];
	}
	return out;
}

function kv_lines(path) {
	const out = {};
	const text = readfile(path);
	if (text == null) return out;
	const lines = split(text, '\n');
	for (let i = 0; i < length(lines); i++) {
		const m = match(lines[i], /^([a-z_]+) (.+)$/);
		if (m) out[m[1]] = m[2];
	}
	return out;
}

/* ---- the beacon log, in the format the host CGI writes ---- */

function urldecode(s) {
	return replace(replace(replace(s, /%3D/g, '='), /%20/g, ' '), /%2F/g, '/');
}

function run_summary() {
	let rows = 0, at = '', tag = '', detail = '', client = '', verdict = 'NO RUN', proof = '';
	const text = readfile(LOG);
	if (text != null) {
		const lines = split(text, '\n');
		for (let i = 0; i < length(lines); i++) {
			const line = trim(lines[i]);
			if (!length(line)) continue;
			let rec = null;
			try { rec = json(line); } catch (e) { continue; }
			if (type(rec) != 'object' || rec.path != '/t') continue;
			rows++;
			if (rec.at != null) at = rec.at;
			if (rec.client != null) client = rec.client;
			const body = (rec.body != null) ? rec.body : '';
			const mt = match(body, /tag=([^&]*)/);
			const md = match(body, /detail=([^&]*)/);
			if (mt) tag = urldecode(mt[1]);
			if (md) detail = urldecode(md[1]);
			if (tag == 'PROOF-SUMMARY-FINAL') proof = detail;
			if (tag == 'EG-VERDICT' && index(detail, 'jailbroken=1') >= 0)
				verdict = 'JAILBROKEN';
			else if (tag == 'JB-ROOT' && verdict != 'JAILBROKEN')
				verdict = 'ROOT';
			else if (verdict == 'NO RUN')
				verdict = 'NO VERDICT';
		}
	}
	return { beacons: rows, last_at: at, last_tag: tag, last_detail: detail,
	         last_client: client, verdict: verdict, proof: proof,
	         /* Rule, measured directly: load ps4debug-NG only on a boot whose chain run
	            finished cleanly. Loading it after a dirty run has faulted the console's
	            kernel and required a power cycle -- see README.md. */
	         clean: (length(proof) && match(proof, /fail=0/) != null) };
}

/* ---- payloads on disk ---- */

function payload_list() {
	const expected = sha_lines(PAYLOAD_MANIFEST);
	const out = [];
	for (let i = 0; i < length(PAYLOAD_DIRS); i++) {
		const dir = PAYLOAD_DIRS[i];
		let names = null;
		try { names = fs.lsdir(dir); } catch (e) { names = null; }
		if (names == null) continue;
		for (let j = 0; j < length(names); j++) {
			const name = names[j];
			if (substr(name, length(name) - 4) != '.bin') continue;
			const path = dir + '/' + name;
			let st = null;
			try { st = fs.stat(path); } catch (e) { st = null; }
			if (st == null || !st.size) continue;
			const exp = (expected[name] != null) ? expected[name] : '';
			push(out, { name: name, path: path, size: st.size, sha256: exp });
		}
	}
	return out;
}

function sha256_of(path) {
	const p = fs.popen(sprintf('sha256sum %s 2>/dev/null', path));
	const out = p.read('all');
	p.close();
	const m = match(out, /^([0-9a-f]{64})/);
	return m ? m[1] : '';
}

/* ---- console address ---- */

function config() {
	const uci = cursor();
	const ip = uci.get('wrt2jb', 'main', 'console_ip');
	const port = uci.get('wrt2jb', 'main', 'binloader_port');
	uci.unload();
	return {
		ip: (ip != null && length(ip)) ? ip : '192.168.1.185',
		port: (port != null && length(port)) ? +port : 9090
	};
}

function console_reachable(ip) {
	if (!match(ip, /^\d{1,3}(\.\d{1,3}){3}$/)) return { ok: false, message: 'not an address' };
	const p = fs.popen(sprintf('ping -c 1 -W 2 %s 2>&1', ip));
	const out = p.read('all');
	p.close();
	return { ok: index(out, '1 packets received') >= 0 || index(out, '1 received') >= 0,
	         message: trim(out) };
}

function last_push() {
	const text = readfile(LAST_PUSH);
	if (text == null) return null;
	try { return json(text); } catch (e) { return null; }
}

/* ---- methods ---- */

const methods = {
	status: {
		call: function() {
			const cfg = config();
			const man = kv_lines(HOST_MANIFEST);
			const shas = sha_lines(HOST_MANIFEST);
			const payloads = payload_list();
			return {
				host: {
					package: (man.package != null) ? man.package : '',
					revision: (man.source_revision != null) ? man.source_revision : '',
					url: host_url(),
					goldhen_sha256: (shas['goldhen.bin'] != null) ? shas['goldhen.bin'] : '',
					files: length(shas)
				},
				run: run_summary(),
				console: {
					ip: cfg.ip,
					port: cfg.port,
					reachable: console_reachable(cfg.ip),
					payloads: payloads
				},
				last_push: last_push()
			};
		}
	},

	binload: {
		args: { host: '', port: 0, payload: '' },
		call: function(req) {
			const a = req.args;
			const host = a.host, port = +a.port, name = a.payload;

			if (!match(host, /^\d{1,3}(\.\d{1,3}){3}$/))
				return { ok: false, message: 'console address must be an IPv4 address' };
			if (port < 1 || port > 65535)
				return { ok: false, message: 'port out of range' };

			/* the payload must be one of the files we listed -- no paths from the browser */
			let path = null;
			const all = payload_list();
			for (let i = 0; i < length(all); i++)
				if (all[i].name == name) path = all[i].path;
			if (path == null)
				return { ok: false, message: 'unknown payload: ' + name };

			const sha = sha256_of(path);
			const p = fs.popen(sprintf('%s %s %s %s 2>&1', BINLOAD, host, port, path));
			const out = p.read('all');
			const rc = p.close();

			let res = null;
			try { res = json(trim(out)); } catch (e) { res = null; }
			if (type(res) != 'object')
				res = { ok: false, message: 'binload said: ' + trim(out) };
			res.at = (function() {
				const d = fs.popen('date -u +%Y-%m-%dT%H:%M:%SZ');
				const s = d.read('all'); d.close(); return trim(s);
			})();
			res.payload = name;
			res.host = host;
			res.port = port;
			res.sha256 = sha;
			res.sha256_expected = sha_lines(PAYLOAD_MANIFEST)[name];
			res.sha256_matches = (res.sha256_expected != null && res.sha256 == res.sha256_expected);
			res.rc = rc;

			try { fs.mkdir('/tmp/wrt2jb'); } catch (e) { }
			try { fs.writefile(LAST_PUSH, sprintf('%J', res)); } catch (e) { }

			return res;
		}
	},

	save_config: {
		args: { console_ip: '', binloader_port: 0 },
		call: function(req) {
			const ip = req.args.console_ip, port = +req.args.binloader_port;
			if (!match(ip, /^\d{1,3}(\.\d{1,3}){3}$/))
				return { ok: false, message: 'console address must be an IPv4 address' };
			if (port < 1 || port > 65535)
				return { ok: false, message: 'port out of range' };
			const uci = cursor();
			uci.set('wrt2jb', 'main', 'console_ip', ip);
			uci.set('wrt2jb', 'main', 'binloader_port', sprintf('%d', port));
			/* ucode's uci.commit() answers a boolean, not an exit code */
			const rc = uci.commit('wrt2jb');
			uci.unload();
			if (!rc) return { ok: false, message: 'uci commit failed' };
			return { ok: true, message: 'saved ' + ip + ':' + port };
		}
	}
};

return { 'luci.wrt2jb': methods };
