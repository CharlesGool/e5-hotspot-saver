// 热点联动数据: the app's backend.  The linking itself runs in the background
// (service.sh under /etc/init.d/hotspot-data); this installs that service and
// keeps it installed -- an image update brings no /etc/init.d/hotspot-data, so
// the notification poll (manifest "notifications") puts it back -- and serves
// the app's page.
//
//   GET  /status          the hotspot, mobile data, the radio, the service, the settings
//   POST /enabled         {"on": true|false}
//   GET  /notifications   (none: only the service check, once a minute)

'use strict';

import { readfile, writefile, stat } from 'fs';

const DIR = '/etc/e5-infoscreen/plugins/hotspotdata';
const INIT = '/etc/init.d/hotspot-data';
const CFG = 'e5-plugin-hotspotdata';

return function(ctx) {
	function running() {
		let s = ctx.ubus('service', 'list', { name: 'hotspot-data' })?.['hotspot-data'];
		for (let name, inst in (s?.instances ?? {}))
			if (inst?.running) return true;
		return false;
	}

	// the init script as this version of the app has it, enabled and running
	function ensure_service() {
		let want = readfile(`${DIR}/hotspot-data.init`);
		if (want == null)
			return false;       // not an installed app (no files under DIR)
		if (readfile(INIT) != want) {
			ctx.run(`cp '${DIR}/hotspot-data.init' '${INIT}.new' && chmod 755 '${INIT}.new' && ` +
				`mv -f '${INIT}.new' '${INIT}' && '${INIT}' enable && '${INIT}' restart >/dev/null 2>&1`);
			ctx.log('service installed');
		}
		else if (!running())
			ctx.run(`'${INIT}' enable; '${INIT}' start >/dev/null 2>&1`);
		// (a reinstalled app: service.sh changed under the running one)
		else if (readfile(`${DIR}/service.sh`) != readfile('/var/run/hotspotdata.running')) {
			ctx.run(`'${INIT}' restart >/dev/null 2>&1`);
			ctx.log('service restarted for the new version');
		}
		return running();
	}

	function setting(name, def) {
		return ctx.uci().get(CFG, 'settings', name) ?? def;
	}

	function hotspot() {
		let c = ctx.uci(), ap = null;
		c.foreach('wireless', 'wifi-iface', s => { if (!ap && s.mode == 'ap') ap = s; });
		if (!ap) return { available: false, on: false };
		return {
			available: true,
			on: ap.disabled != '1' && c.get('wireless', ap.device, 'disabled') != '1'
		};
	}

	function data() {
		let iface = ctx.uci().get('unisoc_modem', 'main', 'data_interface') ?? 'wan';
		let st = ctx.ubus(`network.interface.${iface}`, 'status');
		return {
			iface,
			up: st?.up === true,
			pending: st?.pending === true,
			auto: ctx.uci().get('network', iface, 'auto') != '0'
		};
	}

	// ModemManager's state of the modem (disabled, registered, ...), null without one
	function modem() {
		let out = ctx.sh("mmcli -m any -K 2>/dev/null | sed -n 's/^modem\\.generic\\.state *: *//p' | head -n 1") ?? '';
		out = trim(out);
		return out == '' ? null : out;
	}

	// The data card's radio as the AT owner sees it (t551m-sim-status, every
	// 5 s; "disabled" is CFUN not 1) -- what the status bar shows, and the
	// truth where ModemManager's "disabled" is not: no AT in a request here.
	function radio() {
		let card = trim(readfile('/sys/module/sipc_wwan/parameters/card') ?? '0') == '1' ? 1 : 0;
		// the service paused the poller only once it read CFUN 4 itself
		if (stat('/var/run/hotspotdata.simstatus-paused'))
			return { card, known: true, off: true, paused: true };
		let d = null;
		try { d = json(readfile('/run/t551m-sims.json') ?? 'null'); } catch (e) {}
		let now = +(split(readfile('/proc/uptime') ?? '0', ' ')[0]);
		let s = d?.sims?.[card];
		if (s == null || s.error || now - s.updated > 15 || now < s.updated)
			return { card, known: false };
		return { card, known: true, off: s.registration == 'disabled',
			registration: s.registration, operator: s.operator, label: s.radio_label };
	}

	function status(service) {
		return {
			enabled: setting('enabled', '1') != '0',
			mode: setting('mode', 'radio') == 'data' ? 'data' : 'radio',
			off_delay: +setting('off_delay', '0'),
			hotspot: hotspot(),
			data: data(),
			modem: modem(),
			radio: radio(),
			// CPU/GPU held at their lowest clocks (the service's saved limits)
			perf_low: stat('/var/run/hotspotdata.perf') != null,
			service
		};
	}

	return {
		'GET /status': function(req) {
			return status(ensure_service());
		},
		'POST /enabled': function(req) {
			let on = req.body?.on;
			if (type(on) != 'bool')
				return { status: 400, type: 'application/json', body: '{"error":"on: true or false"}' };
			if (!stat(`/etc/config/${CFG}`))
				writefile(`/etc/config/${CFG}`, '');
			let c = ctx.uci();
			if (c.get(CFG, 'settings') == null)
				c.set(CFG, 'settings', 'settings');
			c.set(CFG, 'settings', 'enabled', on ? '1' : '0');
			c.commit(CFG);
			return status(ensure_service());
		},
		'GET /notifications': function(req) {
			if (!ctx.state_get('checked', 60)) {
				ensure_service();
				ctx.state_put('checked', { at: time() });
			}
			return { notifications: [] };
		}
	};
};
