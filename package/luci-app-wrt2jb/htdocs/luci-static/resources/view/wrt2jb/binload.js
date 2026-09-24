'use strict';
'require view';
'require rpc';
'require ui';

/*
 * The PS4 jailbreak host, from LuCI: what the router is serving, what the last chain run
 * did, and a button that hands a payload to the console's GoldHEN PayLoader.
 *
 * The backend is /usr/share/rpcd/ucode/wrt2jb.uc (ubus object luci.wrt2jb); the push itself
 * is /usr/libexec/wrt2jb/binload, and the reason it is a real POST rather than a port probe
 * is in that script's header.
 */

const callStatus = rpc.declare({
	object: 'luci.wrt2jb',
	method: 'status',
	expect: {}
});

const callBinload = rpc.declare({
	object: 'luci.wrt2jb',
	method: 'binload',
	params: [ 'host', 'port', 'payload' ],
	expect: {}
});

const callSave = rpc.declare({
	object: 'luci.wrt2jb',
	method: 'save_config',
	params: [ 'console_ip', 'binloader_port' ],
	expect: {}
});

function row(label, value, cls) {
	/* a cell may be text, a node, or a list of nodes (a field and its unit, say) -- passing a
	   list through as one child would stringify it into "[object HTMLInputElement]" */
	const children = Array.isArray(value) ? value
		: [ (value == null || value === '') ? '—' : value ];
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '30%' }, [ label ]),
		E('td', { 'class': 'td left' + (cls ? ' ' + cls : '') }, children)
	]);
}

function section(title, children) {
	return E('div', { 'class': 'cbi-section' }, [
		E('h3', [ title ])
	].concat(children));
}

/*
 * Rule, measured directly: ps4debug-NG may be loaded only on a boot whose chain run
 * finished cleanly. Loading it after a dirty run has faulted the console's kernel
 * (`Fatal trap 12`, `[GoldHEN] <payloader> Error handling payload`) and required a power
 * cycle. The flag comes from the router's beacon log, so it is about the last run the
 * router saw, not about the console's whole history.
 */
function warningNode(run) {
	run = run || {};
	if (run.clean === true)
		return '';
	return E('div', { 'class': 'alert-message warning' }, [
		E('strong', [ _('The last chain run the router saw was not clean.') ]),
		' ',
		E('span', [ run.proof
			? _('Proof summary: %s.').format(run.proof)
			: _('No proof summary in this log — the router may not have seen the run at all.') ]),
		' ',
		_('Loading ps4debug-NG after a dirty run faulted the kernel on 2026-09-20 and needed a power ' +
		  'cycle. Reboot the console and run the chain to a clean finish first.')
	]);
}

return view.extend({
	load: function() {
		return callStatus();
	},

	render: function(status) {
		const self = this;
		const host = (status && status.host) || {};
		const run = (status && status.run) || {};
		const cons = (status && status.console) || {};
		const payloads = cons.payloads || [];

		this.hostEls = {};
		this.pushEl = E('div', { 'class': 'cbi-section' });

		const hostTable = E('table', { 'class': 'table' }, [
			row(_('Package'), host.package),
			row(_('Chain revision'), host.revision ? host.revision.substring(0, 12) : ''),
			row(_('GoldHEN served'), host.goldhen_sha256 ? host.goldhen_sha256.substring(0, 12) + '…' : ''),
			row(_('Page'), E('a', { href: host.url || '#', target: '_blank' }, [ host.url || '—' ])),
			row(_('Last run'), (run.verdict || '') + (run.beacons ? ' · ' + run.beacons + ' beacons' : '')),
			row(_('Last beacon'), run.last_at ? run.last_at + ' · ' + run.last_tag : ''),
			row(_('Last from'), run.last_client)
		]);
		this.hostEls.hostTable = hostTable;

		const runTable = this.buildRunTable(run);

		const ipInput = E('input', {
			type: 'text', id: 'wrt2jb-console-ip', value: cons.ip || '',
			style: 'width:12em', placeholder: '192.168.1.185'
		});
		const portInput = E('input', {
			type: 'text', id: 'wrt2jb-binloader-port', value: String(cons.port || 9090),
			style: 'width:6em'
		});

		const payloadSelect = E('select', { id: 'wrt2jb-payload' },
			payloads.map(function(p) {
				return E('option', { value: p.name }, [
					p.name + ' (' + Math.round(p.size / 1024) + ' KiB)'
				]);
			}));
		this.hostEls.payloadSelect = payloadSelect;
		this.hostEls.ipInput = ipInput;
		this.hostEls.portInput = portInput;

		this.hostEls.pushResult = E('div', { 'class': 'cbi-section' }, [
			E('em', [ _('Nothing pushed yet in this session.') ])
		]);

		const pushButton = E('button', {
			'class': 'cbi-button cbi-button-action important',
			'click': ui.createHandlerFn(this, function() { return self.push(); })
		}, [ _('Push payload to GoldHEN') ]);

		const saveButton = E('button', {
			'class': 'cbi-button cbi-button-save',
			'click': ui.createHandlerFn(this, function() { return self.save(); })
		}, [ _('Save address') ]);

		const refreshButton = E('button', {
			'class': 'cbi-button cbi-button-neutral',
			'click': ui.createHandlerFn(this, function() { return self.refresh(); })
		}, [ _('Refresh') ]);

		const reach = (cons.reachable && cons.reachable.ok)
			? E('span', { 'class': 'ifacebadge' }, [ _('answers ping') ])
			: E('span', { 'class': 'ifacebadge' }, [ _('no ping answer (console off, or a different address)') ]);

		this.rememberRun(run);
		this.hostEls.warning = E('div', {}, [ warningNode(run) ]);

		return E('div', {}, [
			E('h2', [ _('WRT2JB — PS4 jailbreak') ]),
			section(_('Served chain'), [ hostTable ]),
			section(_('Last run (the console\'s own beacons)'), [ runTable ]),
			section(_('Console'), [
				this.hostEls.warning,
				E('table', { 'class': 'table' }, [
					row(_('Address'), [ ipInput, ' : ', portInput ]),
					row(_('Reachable'), reach),
					row(_('Payload'), [ payloadSelect ])
				]),
				E('div', { 'class': 'cbi-page-actions' }, [ pushButton, ' ', saveButton, ' ', refreshButton ]),
				E('div', { 'class': 'cbi-section-descr' }, [
					_('The push is an HTTP POST of the payload to GoldHEN\'s PayLoader; 200 means it loaded. ' +
					  'The port is never probed with a bare connect — that was measured to take the listener down.'),
					' ',
					E('a', { href: host.url ? host.url + 't' : '#', target: '_blank' }, [ _('Host log and verdict') ])
				])
			]),
			section(_('Result'), [ this.hostEls.pushResult ])
		]);
	},

	rememberRun: function(run) {
		run = run || {};
		this.runClean = (run.clean === true);
		this.runProof = run.proof || '';
	},

	refresh: function() {
		const self = this;
		return callStatus().then(function(status) {
			/* capture the node being replaced before building its successor: the builders
			   store the new node in this.hostEls, so reading it afterwards would replace the
			   wrong node ("not a child of this node") */
			const oldHost = self.hostEls.hostTable;
			const newHost = self.buildHostTable(status);
			if (oldHost && oldHost.parentNode) oldHost.parentNode.replaceChild(newHost, oldHost);
			const oldRun = self.hostEls.runTable;
			const newRun = self.buildRunTable((status && status.run) || {});
			if (oldRun && oldRun.parentNode) oldRun.parentNode.replaceChild(newRun, oldRun);
			self.rememberRun(status && status.run);
			if (self.hostEls.warning) self.hostEls.warning.replaceChildren(warningNode(status && status.run));
			const cons = (status && status.console) || {};
			if (cons.ip) self.hostEls.ipInput.value = cons.ip;
			return status;
		});
	},

	buildHostTable: function(status) {
		const host = (status && status.host) || {};
		const run = (status && status.run) || {};
		const t = E('table', { 'class': 'table' }, [
			row(_('Package'), host.package),
			row(_('Chain revision'), host.revision ? host.revision.substring(0, 12) : ''),
			row(_('GoldHEN served'), host.goldhen_sha256 ? host.goldhen_sha256.substring(0, 12) + '…' : ''),
			row(_('Page'), E('a', { href: host.url || '#', target: '_blank' }, [ host.url || '—' ])),
			row(_('Last run'), (run.verdict || '') + (run.beacons ? ' · ' + run.beacons + ' beacons' : '')),
			row(_('Last beacon'), run.last_at ? run.last_at + ' · ' + run.last_tag : ''),
			row(_('Last from'), run.last_client)
		]);
		this.hostEls.hostTable = t;
		return t;
	},

	buildRunTable: function(run) {
		run = run || {};
		const t = E('table', { 'class': 'table' }, [
			row(_('Proof'), run.proof ? run.proof + (run.clean ? '  ✓' : '  ✗') : ''),
			row(_('Detail'), run.last_detail)
		]);
		this.hostEls.runTable = t;
		return t;
	},

	push: function() {
		const self = this;

		/* LuCI's ui module has no confirm() of its own -- it uses the browser's, as the
		   file-overwrite and delete prompts do */
		if (!this.runClean) {
			const ok = confirm(
				_('The last chain run the router saw was not clean (%s). Loading ps4debug-NG after a ' +
				  'dirty run faulted the kernel on 2026-09-20 and needed a power cycle. Push anyway?')
					.format(this.runProof || _('no proof summary'))
			);
			if (!ok)
				return Promise.resolve();
		}
		return this.pushNow();
	},

	pushNow: function() {
		const self = this;
		const host = this.hostEls.ipInput.value.trim();
		const port = parseInt(this.hostEls.portInput.value, 10);
		const payload = this.hostEls.payloadSelect.value;
		const out = this.hostEls.pushResult;

		if (!payload) {
			out.replaceChildren(E('div', { 'class': 'alert-message warning' }, [ _('No payload installed.') ]));
			return Promise.resolve();
		}

		out.replaceChildren(E('em', [ _('Pushing %s to %s:%d …').format(payload, host, port) ]));

		return callBinload(host, port, payload).then(function(res) {
			res = res || {};
			const cls = res.ok ? 'alert-message success' : 'alert-message error';
			const lines = [
				E('strong', [ res.ok ? _('Loaded') : _('Not loaded') ]),
				E('div', [ (res.message || '') + (res.status ? ' — ' + res.status : '') ]),
				E('div', [
					_('sent %s bytes from %s').format(res.bytes || '?', res.payload || payload),
					res.sha256 ? E('span', [ ' · sha256 ', res.sha256.substring(0, 16), '…' ]) : '',
					res.sha256_expected
						? (res.sha256_matches ? ' ✓ ' + _('matches this package') : ' ✗ ' + _('does NOT match this package'))
						: ''
				]),
				E('div', [ _('at ') + (res.at || '') ])
			];
			out.replaceChildren(E('div', { 'class': cls }, lines));
			ui.addNotification(_('WRT2JB'), res.message || '', res.ok ? 'success' : 'error');
			return self.refresh();
		}).catch(function(e) {
			out.replaceChildren(E('div', { 'class': 'alert-message error' }, [ String(e) ]));
		});
	},

	save: function() {
		const ip = this.hostEls.ipInput.value.trim();
		const port = parseInt(this.hostEls.portInput.value, 10);
		return callSave(ip, port).then(function(res) {
			res = res || {};
			ui.addNotification(_('WRT2JB'), res.message || '', res.ok ? 'success' : 'error');
		});
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
