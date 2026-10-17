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
//   GET  /cores           each CPU core (online, MHz, off by whom), /proc/stat's
//                         busy and total, the governors: the overview's CPU card
//   POST /unpatch         app.js without poll-patch.js, the screen restarted
//   GET  /notifications   (none: only the service and patch checks, once a minute)
//
// app.js is patched (poll-patch.js) so that the dark screen polls its status
// every blank_poll seconds instead of every 5 while the hotspot and the radio
// are off: the patch asks GET /blank-poll.  An image update brings an
// unpatched app.js; the notification poll patches it again and the screen
// restarts once.  The volkeys app patches the same file elsewhere, between
// its own markers.
//
// settings.uc is patched too (cpu-patch.uc, before system_cat): the CPU page
// (设置 → 系统 → CPU 设置) gets a 关闭核心 row under each domain's governor,
// and every change there goes through cpu-off.sh.  api.uc loads settings.uc
// for every request, so no restart; a patched file that does not compile is
// not written.  An image update brings it unpatched: patched again the same way.
// A second block of its own (usb-patch.uc, before about: usb_cat comes after
// system_cat) gives the USB page's role 关闭（仅充电）, through usb-off.sh.
//
// And index.html (cores-card.html, after app.js): the overview's CPU card,
// which asks GET /cores.  The screen restarts when that changes.

'use strict';

import { readfile, writefile, rename, stat, unlink, glob } from 'fs';

const DIR = '/etc/e5-infoscreen/plugins/hotspotdata';
const INIT = '/etc/init.d/hotspot-data';
const CFG = 'e5-plugin-hotspotdata';
const APP = '/usr/share/e5-infoscreen/www/app.js';
const FN_ANCHOR = 'async function poll() {';
const POLL_OLD = 'pollTimer = setTimeout(poll, blank ? POLL_BLANK : POLL_AWAKE);';
const POLL_NEW = 'pollTimer = setTimeout(poll, blank ? hotspotdataBlankPoll() : POLL_AWAKE);';
const BEGIN = '/* BEGIN e5-hotspotdata';
const SETTINGS = '/usr/share/e5-infoscreen/settings.uc';
const SETTINGS_ANCHOR = 'const system_cat = {';
const CPU_ANCHOR = 'const cpu_categories = [';
const USB_BEGIN = '/* BEGIN e5-usboff';
const USB_END = '/* END e5-usboff */
';
const USB_ANCHOR = 'const about = {';
const USB_CAT = 'const usb_cat = {';
const INDEX = '/usr/share/e5-infoscreen/www/index.html';
const INDEX_ANCHOR = '<script src="app.js"></script>\n';
const HTML_BEGIN = '<!-- BEGIN e5-hotspotdata';
const HTML_END = '<!-- END e5-hotspotdata -->\n';
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

	// a file without our block
	function cut(src, begin, end) {
		begin = begin ?? BEGIN; end = end ?? END;
		let b = index(src, begin), e = index(src, end);
		if (b < 0 || e < b) return null;
		return substr(src, 0, b) + substr(src, e + length(end));
	}

	// app.js without our block and with the poll line as it came
	function strip(src) {
		src = cut(src);
		return src == null ? null : join(POLL_OLD, split(src, POLL_NEW));
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

	// index.html with this version of cores-card.html; the screen restarted when it changed
	function ensure_index_patch() {
		let src = readfile(INDEX), want = readfile(`${DIR}/cores-card.html`);
		if (src == null || want == null) return { patched: false, error: 'missing index.html or cores-card.html' };
		if (index(src, want) >= 0) return { patched: true };
		if (index(src, HTML_BEGIN) >= 0) {
			src = cut(src, HTML_BEGIN, HTML_END);
			if (src == null) return { patched: false, error: 'cannot remove the older CPU card' };
		}
		if (count(src, INDEX_ANCHOR) != 1)
			return { patched: false, error: 'this screen version has no single app.js script: no CPU card' };
		let parts = split(src, INDEX_ANCHOR), tmp = INDEX + '.hotspotdata-new';
		if (writefile(tmp, parts[0] + INDEX_ANCHOR + want + parts[1]) == null || !rename(tmp, INDEX)) {
			unlink(tmp);
			return { patched: false, error: 'cannot write index.html' };
		}
		ctx.log('index.html patched (the overview\'s CPU card), the screen restarts');
		restart_screen();
		return { patched: true, restarting: true };
	}

	// each core: online, its clock, and who took it offline (the CPU page's
	// OFF, the hotspot-off core shutdown); /proc/stat's busy and total jiffies
	// for the load; the governors of the domains
	function cores() {
		let held = split(readfile('/var/run/hotspotdata.cores') ?? '', '\n');
		let page = split(readfile('/var/run/hotspotdata.cpu-off.cpus') ?? '', '\n');
		let cpus = [], govs = [];
		for (let d in glob('/sys/devices/system/cpu/cpu[0-9]*')) {
			let id = +replace(d, /^.*cpu/, ''), on = trim(readfile(`${d}/online`) ?? '1') != '0';
			let khz = on ? +trim(readfile(`${d}/cpufreq/scaling_cur_freq`) ?? '0') : 0;
			push(cpus, { id, online: on, mhz: khz / 1000,
				off: on ? null : index(page, `${id}`) >= 0 ? 'page' : index(held, `${id}`) >= 0 ? 'hotspot' : 'other' });
		}
		for (let p in glob('/sys/devices/system/cpu/cpufreq/policy[0-9]*')) {
			let g = trim(readfile(`${p}/scaling_governor`) ?? '');
			if (g != '' && index(govs, g) < 0) push(govs, g);
		}
		// cpu  user nice system idle iowait irq softirq steal ...
		let f = map(slice(split(trim(split(readfile('/proc/stat') ?? '', '\n')[0]), /\s+/), 1, 9), x => +x);
		let total = 0;
		for (let x in f) total += x;
		return { cpus: sort(cpus, (a, b) => a.id - b.id), governors: govs,
			stat: { busy: total - (f[3] ?? 0) - (f[4] ?? 0), total } };
	}

	// settings.uc with this version of cpu-patch.uc: the CPU page's OFF
	function ensure_cpu_patch() {
		let src = readfile(SETTINGS), want = readfile(`${DIR}/cpu-patch.uc`);
		if (src == null || want == null) return { patched: false, error: 'missing settings.uc or cpu-patch.uc' };
		if (index(src, want) >= 0) return { patched: true };
		if (index(src, BEGIN) >= 0) {
			src = cut(src);
			if (src == null) return { patched: false, error: 'cannot remove the older CPU page patch' };
		}
		if (count(src, SETTINGS_ANCHOR) != 1 || count(src, CPU_ANCHOR) != 1)
			return { patched: false, error: 'this screen version has no CPU page to patch' };
		let parts = split(src, SETTINGS_ANCHOR);
		src = parts[0] + want + SETTINGS_ANCHOR + parts[1];
		// (only a file that compiles: a broken settings.uc is every settings page gone)
		let tmp = SETTINGS + '.hotspotdata-new';
		let ok = writefile(tmp, src) != null;
		if (ok)
			try { loadfile(tmp, { raw_mode: true }); } catch (e) { ok = false; ctx.log(`settings.uc patch: ${e}`); }
		if (!ok || !rename(tmp, SETTINGS)) {
			unlink(tmp);
			return { patched: false, error: 'cannot patch settings.uc' };
		}
		ctx.log('settings.uc patched (CPU page: OFF)');
		return { patched: true };
	}

	// settings.uc with this version of usb-patch.uc: the USB role 关闭（仅充电）
	function ensure_usb_patch() {
		let src = readfile(SETTINGS), want = readfile(`${DIR}/usb-patch.uc`);
		if (src == null || want == null) return { patched: false, error: 'missing settings.uc or usb-patch.uc' };
		if (index(src, want) >= 0) return { patched: true };
		if (index(src, USB_BEGIN) >= 0) {
			src = cut(src, USB_BEGIN, USB_END);
			if (src == null) return { patched: false, error: 'cannot remove the older USB page patch' };
		}
		if (count(src, USB_ANCHOR) != 1 || count(src, USB_CAT) != 1)
			return { patched: false, error: 'this screen version has no USB page to patch' };
		let parts = split(src, USB_ANCHOR);
		src = parts[0] + want + USB_ANCHOR + parts[1];
		// (only a file that compiles, as for the CPU page)
		let tmp = SETTINGS + '.hotspotdata-new';
		let ok = writefile(tmp, src) != null;
		if (ok)
			try { loadfile(tmp, { raw_mode: true }); } catch (e) { ok = false; ctx.log(`settings.uc USB patch: ${e}`); }
		if (!ok || !rename(tmp, SETTINGS)) {
			unlink(tmp);
			return { patched: false, error: 'cannot patch settings.uc' };
		}
		ctx.log('settings.uc patched (USB page: off)');
		return { patched: true };
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

	// the cores OFF on the CPU page takes offline (cpu-off.sh's list), offline now or not
	function cpu_off() {
		let cpus = map(filter(split(readfile('/var/run/hotspotdata.cpu-off.cpus') ?? '', '\n'), l => l != ''), l => +l);
		return sort(cpus, (a, b) => a - b);
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
			// the cores of the domains turned OFF on the CPU page
			cpu_off: guarded(cpu_off),
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
			// (and at once for a new cpu-patch.uc: a reinstalled app)
			let mtime = stat(`${DIR}/cpu-patch.uc`)?.mtime;
			st.cpu_patch = ctx.state_get('cpu_patch', 60);
			if (st.cpu_patch == null || st.cpu_patch.mtime != mtime) {
				st.cpu_patch = { ...ensure_cpu_patch(), mtime };
				ctx.state_put('cpu_patch', st.cpu_patch);
			}
			let usb = stat(`${DIR}/usb-patch.uc`)?.mtime;
			st.usb_patch = ctx.state_get('usb_patch', 60);
			if (st.usb_patch == null || st.usb_patch.mtime != usb) {
				st.usb_patch = { ...ensure_usb_patch(), mtime: usb };
				ctx.state_put('usb_patch', st.usb_patch);
			}
			let card = stat(`${DIR}/cores-card.html`)?.mtime;
			st.index_patch = ctx.state_get('index_patch', 60);
			if (st.index_patch == null || st.index_patch.mtime != card) {
				st.index_patch = { ...ensure_index_patch(), mtime: card };
				ctx.state_put('index_patch', st.index_patch);
			}
			return st;
		},
		'GET /cores': function(req) {
			return cores();
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
				ensure_cpu_patch();
				ensure_usb_patch();
				ensure_index_patch();
				ensure_simstat();
			}
			return { notifications: [] };
		}
	};
};
