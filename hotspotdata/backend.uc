// 热点省电 (Hotspot Power Saver, id hotspotdata): the app's backend.  The linking itself runs in the background
// (service.sh under /etc/init.d/hotspot-data, and the deep sleep sleep.sh as its
// instance "sleep"); this installs that service and
// keeps it installed -- an image update brings no /etc/init.d/hotspot-data, so
// the notification poll (manifest "notifications") puts it back -- and serves
// the app's page.
//
//   GET  /status          the hotspot, mobile data, the radio, the service, the settings
//   POST /enabled         {"on": true|false}
//   POST /sleep           {"on": true|false}: the deep sleep
//   GET  /blank-poll      {ms}: the dark screen's poll, for the patched app.js
//   POST /unpatch         app.js without poll-patch.js, the screen restarted
//   GET  /notifications   (none: only the service and patch checks, once a minute)
//
// app.js is patched (poll-patch.js) so that the dark screen polls its status
// every blank_poll seconds instead of every 5 while the hotspot and the radio
// are off: the patch asks GET /blank-poll.  An image update brings an
// unpatched app.js; the notification poll patches it again and the screen
// restarts once.  The volkeys app patches the same file elsewhere, between
// its own markers.

'use strict';

import { readfile, writefile, rename, stat } from 'fs';

const DIR = '/etc/e5-infoscreen/plugins/hotspotdata';
const INIT = '/etc/init.d/hotspot-data';
const CFG = 'e5-plugin-hotspotdata';
const APP = '/usr/share/e5-infoscreen/www/app.js';
const FN_ANCHOR = 'async function poll() {';
const POLL_OLD = 'pollTimer = setTimeout(poll, blank ? POLL_BLANK : POLL_AWAKE);';
const POLL_NEW = 'pollTimer = setTimeout(poll, blank ? hotspotdataBlankPoll() : POLL_AWAKE);';
const BEGIN = '/* BEGIN e5-hotspotdata';
// t551m-sim-status stamps its readings with time.monotonic(), which stops in
// deep sleep, while the screen and this app compare them with /proc/uptime
// (boottime): after the first suspend each reading looked older than 15 s and
// the status bar said "unknown".  Both it and t551m-registration (which
// compares with time.monotonic()) go to CLOCK_BOOTTIME.  (Patterns for sed's
// basic regular expressions: no brackets; the parentheses are literal.)
const BOOTTIME = [
	{ file: '/usr/libexec/t551m-sim-status', service: 't551m-sim-status',
	  from: "'updated': time.monotonic()", to: "'updated': time.clock_gettime(time.CLOCK_BOOTTIME)" },
	{ file: '/usr/libexec/unisoc-modem/t551m-registration',
	  from: "time.monotonic()-row", to: "time.clock_gettime(time.CLOCK_BOOTTIME)-row" }
];
const END = '/* END e5-hotspotdata */\n';

return function(ctx) {
	function count(s, part) { return length(split(s, part)) - 1; }

	// app.js without our block and with the poll line as it came
	function strip(src) {
		let b = index(src, BEGIN), e = index(src, END);
		if (b < 0 || e < b) return null;
		src = substr(src, 0, b) + substr(src, e + length(END));
		return join(POLL_OLD, split(src, POLL_NEW));
	}

	function restart_screen() {
		// (detached: this request runs in the screen's own API server)
		ctx.run("setsid sh -c 'sleep 2; /etc/init.d/e5-infoscreen restart' >/dev/null 2>&1 &");
	}

	function write_app(src) {
		let tmp = APP + '.hotspotdata-new';
		if (writefile(tmp, src) == null || !rename(tmp, APP)) {
			ctx.run(`rm -f '${tmp}'`);
			return false;
		}
		return true;
	}

	// app.js with this version of poll-patch.js; the screen restarted when it changed
	function ensure_patch() {
		let src = readfile(APP), want = readfile(`${DIR}/poll-patch.js`);
		if (src == null || want == null) return { patched: false, error: 'missing app.js or poll-patch.js' };
		if (index(src, want) >= 0 && index(src, POLL_NEW) >= 0) return { patched: true };
		if (index(src, BEGIN) >= 0) {
			src = strip(src);
			if (src == null) return { patched: false, error: 'cannot remove the older patch' };
		}
		if (count(src, FN_ANCHOR) != 1 || count(src, POLL_OLD) != 1)
			return { patched: false, error: 'this screen version has no single status poll: not patched' };
		let parts = split(src, FN_ANCHOR);
		src = parts[0] + want + FN_ANCHOR + parts[1];
		src = join(POLL_NEW, split(src, POLL_OLD));
		if (!write_app(src))
			return { patched: false, error: 'cannot write app.js' };
		ctx.log('app.js patched (dark-screen poll), the screen restarts');
		restart_screen();
		return { patched: true, restarting: true };
	}

	// the SIM status stamped and read in boottime (BOOTTIME); a changed daemon
	// restarted, unless it is paused by us
	function ensure_simstat() {
		let out = { patched: true };
		for (let b in BOOTTIME) {
			let src = readfile(b.file);
			if (src == null || index(src, b.from) < 0)
				continue;
			// (cat into the file: its mode and owner stay)
			ctx.run(`sed "s/${b.from}/${b.to}/g" '${b.file}' > '${b.file}.hotspotdata-new' && ` +
				`cat '${b.file}.hotspotdata-new' > '${b.file}'; rm -f '${b.file}.hotspotdata-new'`);
			if (index(readfile(b.file) ?? '', b.from) >= 0) {
				out = { patched: false, error: `cannot patch ${b.file}` };
				continue;
			}
			ctx.log(`${b.file}: SIM status in boottime (deep sleep)`);
			if (b.service && !stat('/var/run/hotspotdata.simstatus-paused'))
				ctx.run(`/etc/init.d/${b.service} restart >/dev/null 2>&1`);
		}
		return out;
	}

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
		else if (readfile(`${DIR}/service.sh`) != readfile('/var/run/hotspotdata.running') ||
				(readfile(`${DIR}/sleep.sh`) != null &&
				 readfile(`${DIR}/sleep.sh`) != readfile('/var/run/hotspotdata.sleep/running'))) {
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

	// (after setting() and hotspot(): ucode resolves names when it compiles,
	// so a function defined further down is not seen from here)
	function blank_poll() {
		let s = int(setting('blank_poll', '60'));
		if (!(s >= 5 && s <= 600)) s = 60;
		// only with the hotspot off and the radio off by us: no SMS can come
		let off = !hotspot().on && setting('enabled', '1') != '0' &&
			(stat('/var/run/hotspotdata.radio-off.0') || stat('/var/run/hotspotdata.radio-off.1'));
		return { ms: off && s > 5 ? s * 1000 : null };
	}

	// the deep sleep (sleep.sh): why it is awake, and its statistics since it started
	function sleep_status() {
		let RUN = '/var/run/hotspotdata.sleep', st = split(trim(readfile(`${RUN}/state`) ?? ''), ' ');
		let s = {};
		for (let l in split(readfile(`${RUN}/stats`) ?? '', '
')) {
			let m = match(l, /^([a-z_]+)=(.*)$/);
			if (m) s[m[1]] = match(m[2], /^[0-9]+$/) ? +m[2] : m[2];
		}
		return {
			on: setting('sleep', '1') != '0',
			deep: index(readfile('/sys/power/mem_sleep') ?? '', 'deep') >= 0,
			delay: +setting('sleep_delay', '30'),
			radio_on: setting('sleep_radio_on', '0') == '1',
			// "asleep", or "awake" and why: screen delay power hotspot radio audio wakelock backoff grace kernel disabled
			state: st[0] || null,
			why: st[1] || null,
			sleeps: s.sleeps ?? 0,
			fails: s.fails ?? 0,
			slept: s.slept ?? 0,
			wall: s.since ? time() - s.since : 0,
			last_slept: s.last_slept ?? 0,
			last_by: s.last_by || null,
			last_at: s.last_at || null
		};
	}

	// a value that may fail (a command, a file) without failing the status
	function guarded(fn) {
		try { return fn(); } catch (e) { ctx.log(`status: ${e}`); return null; }
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
			// the cores the service took offline, and the kernel's online list ("0-5")
			cores_off: length(filter(split(readfile('/var/run/hotspotdata.cores') ?? '', '\n'), l => l != '')),
			cores_online: trim(readfile('/sys/devices/system/cpu/online') ?? '') || null,
			// the limits let go while the screen is lit (boost_screen)
			boosted: stat('/var/run/hotspotdata.boost') != null,
			// Bluetooth powered off by the service, the idle auto-off, the dark-screen poll
			bt_off: stat('/var/run/hotspotdata.bt-off') != null,
			idle_off: +setting('idle_off', '30'),
			blank_poll: guarded(() => blank_poll().ms),
			sleep: guarded(sleep_status),
			service
		};
	}

	return {
		'GET /status': function(req) {
			let st = status(ensure_service());
			st.simstat = ctx.state_get('simstat', 60);
			if (st.simstat == null) {
				st.simstat = ensure_simstat();
				ctx.state_put('simstat', st.simstat);
			}
			// (the page asks every 3 s: app.js is read at most once a minute)
			st.patch = ctx.state_get('patch', 60);
			if (st.patch == null) {
				st.patch = ensure_patch();
				ctx.state_put('patch', st.patch);
			}
			return st;
		},
		'GET /blank-poll': function(req) {
			return blank_poll();
		},
		'POST /unpatch': function(req) {
			let src = readfile(APP);
			if (src == null || index(src, BEGIN) < 0)
				return { patched: false };
			src = strip(src);
			if (src == null || !write_app(src))
				return { status: 500, type: 'application/json', body: '{"error":"cannot restore app.js"}' };
			ctx.log('app.js restored (dark-screen poll), the screen restarts');
			restart_screen();
			return { patched: false, restarting: true };
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
		'POST /sleep': function(req) {
			let on = req.body?.on;
			if (type(on) != 'bool')
				return { status: 400, type: 'application/json', body: '{"error":"on: true or false"}' };
			if (!stat(`/etc/config/${CFG}`))
				writefile(`/etc/config/${CFG}`, '');
			let c = ctx.uci();
			if (c.get(CFG, 'settings') == null)
				c.set(CFG, 'settings', 'settings');
			c.set(CFG, 'settings', 'sleep', on ? '1' : '0');
			c.commit(CFG);
			return status(ensure_service());
		},
		'GET /notifications': function(req) {
			if (!ctx.state_get('checked', 60)) {
				ctx.state_put('checked', { at: time() });
				ensure_service();
				ensure_patch();
				ensure_simstat();
			}
			return { notifications: [] };
		}
	};
};
