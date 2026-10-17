#!/bin/sh
# 热点省电 (Hotspot Power Saver) -- the background half of the hotspotdata info
# screen app (its id, settings, files and log tag keep the name hotspotdata).
#
#   hotspot turned off -> mobile data down (after off_delay minutes), and with
#                         mode "radio" the data card's radio off as well
#   hotspot turned on  -> the radio back on, mobile data up
#   and with perf_low, the CPU and GPU at their lowest clocks while it is off
#   (cores: CPU cores offline as well; boost_screen: not while the screen is lit)
#   and with bt_off, Bluetooth off; with idle_off, the hotspot itself turned off
#   when no device has used it for that many minutes
#   and the CPU domains turned OFF on the screen's CPU page (cpu-off.sh) kept off
#
# The hotspot's state is its configuration: the first wifi-iface in mode ap and
# its radio, not disabled -- what the screen, LuCI and the dashboard all change
# (/usr/libexec/unisoc-modem/hotspot.uc).  Data is the netifd interface the
# dashboard's own data switch uses (unisoc_modem.main.data_interface, wan).
#
# Modes (e5-plugin-hotspotdata.settings.mode):
#   radio  the cellular radio off.  ModemManager's disable (the proto's
#          teardown, network.<wan>.disable_modem default 1) is not enough on
#          this modem: the card stays at CFUN 1, camped (t551m-sim-status still
#          reads its operator).  So the data card also gets AT+CFUN=4 -- radio
#          off, SIM kept, what the dashboard does to a standby card -- through
#          the AT adapter with the card selected (MU300_SIM_SLOT ->
#          AT+SPACTCARD), and AT+CFUN=1 before data comes back.  Never
#          AT+CFUN=0 or SFUN=3/5: after those the SIM is gone until a reboot
#          (api.uc, at_warning).  No SMS and no calls while it is off.
#   data   data only: disable_modem 0 keeps the modem registered, so SMS and
#          calls still come in.
#
# While the hotspot is off, network.<wan>.auto is 0 as well, so that a boot, a
# network reload or the modem coming back does not dial again behind our back;
# anything that still brings the interface up (a SIM switch, an APN change, the
# reconnect button, the dashboard's radio button) is taken down again at the
# next check, and in mode radio the radio is checked (AT+CFUN?) every
# RADIO_RETRY s and turned off again.  While the hotspot is on, data is only
# raised on the change: turning data off by hand then stays.
#
# /etc/init.d/hotspot-data runs this under procd; the app's backend installs
# that.  When the app is removed or the linking turned off, this gives back
# what it changed (auto, disable_modem, the radio); a removed app also removes
# the service.

DIR=/etc/e5-infoscreen/plugins/hotspotdata
CFG=e5-plugin-hotspotdata
INIT=/etc/init.d/hotspot-data
AT=/usr/libexec/unisoc-modem/at
# MARK.<card>: a card whose radio we turned off (kept until a reboot, which
# powers it anyway); one each, so a data SIM switched while off is given back too
MARK=/var/run/hotspotdata.radio-off
# t551m-sim-status reads both cards over AT every 5 s, radio off or not; with
# pause_sim_status it is stopped while the radio is off (PAUSED: stopped by us,
# so started again by us).  Its readers (the status bar, the dashboard's
# per-card rows) take a reading older than 15 s as unknown.  Our own AT goes
# through e5-at, not through it.
SIMSTAT=/etc/init.d/t551m-sim-status
PAUSED=/var/run/hotspotdata.simstatus-paused
NAP=1
NAP_STEPS=3
NAP_LONG=3
RADIO_RETRY=30
RADIO_GAP_MAX=300
MODEM_LOST=60
RECOVER_GAP=600

log() { logger -t hotspotdata -- "$*"; }
# routine messages, not said for the screen's own on/off cycles (quiet)
info() { [ -n "$quiet" ] || log "$@"; }
quiet=

data_iface() {
	local i
	i=$(uci -q get unisoc_modem.main.data_interface)
	echo "${i:-wan}"
}

# the data SIM (sipc_wwan card=, e5-sim)
data_card() {
	local c
	c=$(cat /sys/module/sipc_wwan/parameters/card 2>/dev/null)
	case "$c" in 0|1) echo "$c" ;; *) echo 0 ;; esac
}

hotspot_on() {
	local ap radio
	ap=$(uci -q show wireless | sed -n "s/^wireless\.\([^.]*\)\.mode='ap'$/\1/p" | head -n 1)
	[ -n "$ap" ] || return 1
	radio=$(uci -q get "wireless.$ap.device")
	[ "$(uci -q get "wireless.$ap.disabled")" != 1 ] &&
		[ "$(uci -q get "wireless.$radio.disabled")" != 1 ]
}

enabled() { [ "$(uci -q get "$CFG.settings.enabled")" != 0 ]; }

mode() {
	case "$(uci -q get "$CFG.settings.mode")" in
		data) echo data ;;
		*) echo radio ;;
	esac
}

off_delay() {
	local d
	d=$(uci -q get "$CFG.settings.off_delay")
	case "$d" in ''|*[!0-9]*) d=0 ;; esac
	echo $((d * 60))
}

uptime_s() { cut -d. -f1 /proc/uptime; }

# 0: up or dialling; 1: down
data_active() {
	local st
	st=$(ifstatus "$1" 2>/dev/null) || return 1
	[ "$(echo "$st" | jsonfilter -e '@.up')" = true ] ||
		[ "$(echo "$st" | jsonfilter -e '@.pending')" = true ]
}

# would netifd dial it on its own (at boot, when the modem appears)?
data_autostart() {
	[ "$(ifstatus "$1" 2>/dev/null | jsonfilter -e '@.autostart')" = true ]
}

# ModemManager's state of the modem: disabled, enabled, registered, ... or
# nothing while there is none
modem_state() {
	mmcli -m any -K 2>/dev/null | sed -n 's/^modem\.generic\.state *: *//p' | head -n 1
}

# the card's radio: 1 on, 4 off, 0 minimum; nothing when the AT owner does not answer
cfun_get() {
	MU300_SIM_SLOT=$1 "$AT" -t 10 'AT+CFUN?' 2>/dev/null |
		sed -n 's/.*+CFUN: *\([0-9]*\).*/\1/p' | head -n 1
}

cfun_set() {
	MU300_SIM_SLOT=$1 "$AT" -t 15 "AT+CFUN=$2" 2>/dev/null | grep -q '^OK'
}

pause_wanted() { [ "$(uci -q get "$CFG.settings.pause_sim_status")" != 0 ]; }

# (also when something started it again while paused)
sim_status_pause() {
	[ -x "$SIMSTAT" ] || return
	ubus call service list '{"name":"t551m-sim-status"}' 2>/dev/null |
		grep -q '"running": *true' || return
	: > "$PAUSED"
	"$SIMSTAT" stop >/dev/null 2>&1
	log "radio off: SIM status polling (t551m-sim-status) paused"
}

# While the poller is paused and the radio off, its file says so in its place:
# the data card "disabled" (CFUN not 1, as the poller itself writes it) with
# 射频关闭 for an operator, which the status bar shows instead of 搜索中 (it
# says 搜索中 for a modem without an operator).  Fresh every loop -- readers
# take a row older than 15 s (/proc/uptime) as unknown; the other card's row
# is written old, so it reads as unknown.  The poller overwrites it on resume.
SIMS=/run/t551m-sims.json
sims_write_off() {
	local c up r0 r1 row off stale
	c=$(data_card)
	up=$(cut -d' ' -f1 /proc/uptime)
	off="{\"slot\":$c,\"updated\":$up,\"present\":true,\"registration\":\"disabled\",\"operator\":\"射频关闭\",\"tech\":null,\"radio_label\":null,\"signal\":{},\"error\":null}"
	stale="{\"slot\":$((1 - c)),\"updated\":0,\"present\":null,\"registration\":\"unknown\",\"operator\":null,\"tech\":null,\"radio_label\":null,\"signal\":{},\"error\":\"paused\"}"
	if [ "$c" = 0 ]; then r0=$off r1=$stale; else r0=$stale r1=$off; fi
	printf '{"updated":%s,"active":%s,"sims":[%s,%s]}\n' "$up" "$c" "$r0" "$r1" > "$SIMS.hotspotdata" &&
		mv -f "$SIMS.hotspotdata" "$SIMS"
}

# With the hotspot off (perf_low): every CPU policy and the GPU (a devfreq
# device named *gpu*/*mali*) held at their lowest frequency, min and max both.
# What was there is kept in PERF ("path value", in the order to write it back:
# max before min) and written back when the hotspot is on again or the linking
# off.  The same sysfs limits cpu-control (LuCI's and the screen's CPU page)
# sets at runtime; its saved profile (/etc/e5-cpu.json) is not touched, and a
# reboot starts from that profile anyway.  DDR is left alone: its controller
# is shared with the modem and the display.
CPUFREQ=/sys/devices/system/cpu/cpufreq
DEVFREQ=/sys/class/devfreq
PERF=/var/run/hotspotdata.perf
# limits a restore could not write: their domain had no core online (OFF on
# the CPU page), so it cannot be written; written once it has one again --
# here, and by cpu-off.sh as it brings cores online for cpu-control
PERF_PENDING=/var/run/hotspotdata.perf-pending
perf_wanted() { [ "$(uci -q get "$CFG.settings.perf_low")" != 0 ]; }

lowest() {
	tr ' ' '\n' < "$1" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | head -n 1
}

# one limit's current value: the requested one where this kernel has it
# (the effective one may be under a thermal cap)
limit_now() {
	local r
	r=$(echo "$1" | sed 's/scaling_\(m[a-z]*_freq\)$/scaling_requested_\1/')
	[ "$r" != "$1" ] && [ -f "$r" ] && { cat "$r"; return; }
	cat "$1"
}

# A domain's limits held at LO: PERF.new gets "path old LO" for max, then for
# min (written back in that order: max first, then min); min is lowered first.
hold_domain() {
	local max=$1 min=$2 lo=$3
	echo "$max $(limit_now "$max") $lo" >> "$PERF.new"
	echo "$min $(limit_now "$min") $lo" >> "$PERF.new"
	echo "$lo" > "$min" 2>/dev/null || log "cannot write $min"
	echo "$lo" > "$max" 2>/dev/null || log "cannot write $max"
}

perf_low() {
	local p d lo n=0
	[ -f "$PERF" ] && return
	: > "$PERF.new"
	for p in "$CPUFREQ"/policy*; do
		[ -f "$p/scaling_max_freq" ] || continue
		# (no core online -- OFF on the CPU page: its limits cannot be read or written)
		[ -n "$(cat "$p/affected_cpus" 2>/dev/null)" ] || continue
		lo=$(lowest "$p/scaling_available_frequencies")
		[ -n "$lo" ] || lo=$(cat "$p/cpuinfo_min_freq" 2>/dev/null)
		[ -n "$lo" ] || continue
		hold_domain "$p/scaling_max_freq" "$p/scaling_min_freq" "$lo"
		n=$((n + 1))
	done
	for d in "$DEVFREQ"/*; do
		case "${d##*/}" in *gpu*|*GPU*|*mali*) ;; *) continue ;; esac
		lo=$(lowest "$d/available_frequencies")
		[ -n "$lo" ] && [ -f "$d/max_freq" ] || continue
		hold_domain "$d/max_freq" "$d/min_freq" "$lo"
		n=$((n + 1))
	done
	mv -f "$PERF.new" "$PERF"
	info "hotspot off: $n CPU/GPU frequency domains held at their lowest"
}

# The old limits back -- only where they still are what we wrote: a limit
# changed meanwhile (the CPU page) is the user's now, and stays.  And a CPU
# profile saved meanwhile holds our lowest clocks: said in the log.
CPU_PROFILE=/etc/e5-cpu.json
perf_restore() {
	local path old ours kept=0
	[ -f "$PERF" ] || return 0
	while read -r path old ours; do
		[ -n "$old" ] || continue
		if ! cat "$path" >/dev/null 2>&1; then
			echo "$path $old $ours" >> "$PERF_PENDING"
		elif [ -z "$ours" ] || [ "$(limit_now "$path")" = "$ours" ]; then
			echo "$old" > "$path" 2>/dev/null
		else
			kept=$((kept + 1))
		fi
	done < "$PERF"
	[ "$kept" = 0 ] || log "$kept frequency limits changed while held low: left as they were set"
	[ -f "$CPU_PROFILE" ] && [ "$CPU_PROFILE" -nt "$PERF" ] &&
		log "warning: the CPU profile ($CPU_PROFILE) was saved while the clocks were held low; check it on the CPU page"
	rm -f "$PERF"
	info "CPU/GPU frequency limits restored"
}

# PERF_PENDING written where its domain is back (not while the clocks are held)
perf_pending() {
	local path old ours
	[ -f "$PERF_PENDING" ] && [ ! -f "$PERF" ] || return 0
	: > "$PERF_PENDING.new"
	while read -r path old ours; do
		if ! cat "$path" >/dev/null 2>&1; then
			echo "$path $old $ours" >> "$PERF_PENDING.new"
		elif [ "$(limit_now "$path")" = "$ours" ]; then
			echo "$old" > "$path" 2>/dev/null
		fi
	done < "$PERF_PENDING"
	if [ -s "$PERF_PENDING.new" ]; then
		mv -f "$PERF_PENDING.new" "$PERF_PENDING"
	else
		rm -f "$PERF_PENDING.new" "$PERF_PENDING"
		info "CPU frequency limits of a domain back online restored"
	fi
}

# With the hotspot off (cores): CPU cores offline, after the clocks are held
# low.  "little" keeps the slowest cluster (the CPUFreq policy with the lowest
# cpuinfo_max_freq) and takes every other core offline; "two" keeps only the
# first two cores of that cluster.  CORES lists the cores we took offline:
# online again when the hotspot is on, before the clocks come back and data
# is dialled, and packet steering spreads the network work over them again.
# A core that has no online file (cpu0, usually) always stays.
#
# A kernel that dies taking a core offline would, with the hotspot off at
# boot, do it again at every boot.  So GUARD is on flash from just before the
# first core goes until 30 s after the last: found at start, the last attempt
# did not finish, and core shutdown is turned off (cores=all) for good.
CPUSYS=/sys/devices/system/cpu
CORES=/var/run/hotspotdata.cores
GUARD=/etc/hotspotdata.cpu-offline-guard
VERIFIED=/etc/hotspotdata.cpu-offline-ok

# The CPU page's OFF (cpu-off.sh, through the app's patch of settings.uc): the
# domains turned off there (CPUOFF_LIST, its cores CPUOFF_CPUS; SAVED for the next boot with the
# CPU profile on) stay off -- no core of theirs comes online with the hotspot
# or a lit screen, and each full pass takes one that did offline again.  The
# moves of cores here and in cpu-off.sh take CPU_LOCK (fd 8) in turn.
CPUOFF=$DIR/cpu-off.sh
CPUOFF_LIST=/var/run/hotspotdata.cpu-off
CPUOFF_CPUS=/var/run/hotspotdata.cpu-off.cpus
CPUOFF_SAVED=/etc/hotspotdata.cpu-off
CPU_FULL=/var/run/hotspotdata.cpu-full.json
CPU_LOCK=/var/run/hotspotdata.cpu.lock
exec 8>"$CPU_LOCK"

# a core of a domain turned off on the CPU page (never cpu0: cpu-off.sh keeps it)
user_off() {
	local l
	[ "$1" != 0 ] || return 1
	[ -f "$CPUOFF_CPUS" ] && grep -qx "$1" "$CPUOFF_CPUS"
}

# the app is gone: the CPU page's OFF given back, and its patches of the page
# and of the overview (its CPU card, at the screen's next start) out
cpu_off_clear() {
	local d
	sed -i '/^\/\* BEGIN e5-hotspotdata/,/^\/\* END e5-hotspotdata \*\//d' \
		/usr/share/e5-infoscreen/settings.uc 2>/dev/null
	sed -i '/^<!-- BEGIN e5-hotspotdata/,/^<!-- END e5-hotspotdata -->/d' \
		/usr/share/e5-infoscreen/www/index.html 2>/dev/null
	[ -f "$CPUOFF_LIST" ] || { rm -f "$CPUOFF_SAVED"; return 0; }
	for d in "$CPUSYS"/cpu[0-9]*; do
		[ -f "$d/online" ] && user_off "${d##*/cpu}" || continue
		echo 1 > "$d/online" 2>/dev/null
	done
	rm -f "$CPUOFF_LIST" "$CPUOFF_CPUS" "$CPUOFF_SAVED" "$CPU_FULL"
	log "CPU page OFF: every domain on again"
}

cores_mode() {
	case "$(uci -q get "$CFG.settings.cores")" in
		all) echo all ;;
		two) echo two ;;
		*) echo little ;;
	esac
}

# the CPUs of the slowest cluster
little_cpus() {
	local p f best= bestf=
	for p in "$CPUFREQ"/policy*; do
		f=$(cat "$p/cpuinfo_max_freq" 2>/dev/null)
		[ -n "$f" ] || continue
		if [ -z "$bestf" ] || [ "$f" -lt "$bestf" ]; then bestf=$f best=$p; fi
	done
	[ -n "$best" ] && cat "$best/related_cpus" 2>/dev/null
}

cores_off() { flock 8; _cores_off; flock -u 8; }
cores_on() { flock 8; _cores_on; flock -u 8; }

# The cores to keep, without those OFF on the CPU page; topped up to two
# (the lowest-numbered of the rest), so that OFF there and the shutdown here
# together never leave a single core.
keep_two() {
	local c n=0 out=
	for c in "$@"; do user_off "$c" || { out="$out $c"; n=$((n + 1)); }; done
	for c in $(ls "$CPUSYS" | sed -n "s/^cpu\([0-9][0-9]*\)$/\1/p" | sort -n); do
		[ "$n" -lt 2 ] || break
		case " $out " in *" $c "*) continue ;; esac
		user_off "$c" && continue
		out="$out $c"; n=$((n + 1))
	done
	echo $out
}

_cores_off() {
	local mode keep d c n=0
	mode=$(cores_mode)
	if [ "$mode" = all ]; then _cores_on; return; fi
	[ "$(cat "$CORES.mode" 2>/dev/null)" = "$mode" ] && return
	_cores_on                              # (a mode change: from all cores)
	# (every domain whole once, for the CPU page to draw one that goes offline)
	[ -f "$CPU_FULL" ] || [ ! -f "$CPUOFF" ] || sh "$CPUOFF" snapshot
	keep=$(little_cpus)
	[ -n "$keep" ] || { log "no CPU clusters found: no core goes offline"; return; }
	[ "$mode" = two ] && keep=$(echo $keep | tr ' ' '\n' | sort -n | head -n 2 | tr '\n' ' ')
	keep=$(keep_two $keep)
	# (the guard only until it has worked once here: then no flash write per screen-off)
	[ -f "$VERIFIED" ] || { : > "$GUARD"; sync; guarding=1; }
	: > "$CORES"
	for d in "$CPUSYS"/cpu[0-9]*; do
		c=${d##*/cpu}
		[ -f "$d/online" ] || continue
		case " $(echo $keep) " in *" $c "*) continue ;; esac
		[ "$(cat "$d/online")" = 1 ] || continue
		if echo 0 > "$d/online" 2>/dev/null; then
			echo "$c" >> "$CORES"
			n=$((n + 1))
		else
			log "cpu$c cannot go offline"
		fi
	done
	echo "$mode" > "$CORES.mode"
	[ -n "$guarding" ] && guard_until=$(($(uptime_s) + 30))
	guarding=
	info "hotspot off: $n CPU cores offline (kept: $(echo $keep))"
}

_cores_on() {
	local c n=0
	[ -f "$CORES" ] || return 0
	while read -r c; do
		user_off "$c" && continue           # (OFF on the CPU page meanwhile)
		if echo 1 > "$CPUSYS/cpu$c/online" 2>/dev/null; then n=$((n + 1)); else log "cpu$c cannot come online"; fi
	done < "$CORES"
	rm -f "$CORES" "$CORES.mode"
	[ -x /etc/init.d/packet_steering ] && /etc/init.d/packet_steering reload >/dev/null 2>&1
	info "$n CPU cores online again"
}

# With boost_screen: while the screen is lit (its backlight above 0 -- what
# the screen itself takes for awake; a screen cut off by the volume keys is
# dark), the hotspot-off limits are let go -- every core online, the clocks
# back -- and they come back SCREEN_HOLD s after it went dark.  These cycles
# are quiet in the log.  BOOSTED says the limits are let go for the screen.
BOOSTED=/var/run/hotspotdata.boost
SCREEN_HOLD=5
BACKLIGHT=
for b in /sys/class/backlight/*; do
	[ -f "$b/brightness" ] && { BACKLIGHT=$b/brightness; break; }
done
boost_wanted() { [ "$(uci -q get "$CFG.settings.boost_screen")" != 0 ]; }
# (shell builtins only: this runs every second)
screen_lit() {
	local v
	[ -n "$BACKLIGHT" ] && read -r v < "$BACKLIGHT" && [ "${v:-0}" -gt 0 ]
} 2>/dev/null

# With dark_watch: the screen's power watcher (t551m-screen-power watch: ten
# times a second it reads the backlight, for one changed behind its back, and
# sets the touch screen to match) paused while the screen is dark -- SIGSTOP
# after SCREEN_HOLD s dark, SIGCONT when it lights (within a loop pause) or
# this service ends.  Lighting the screen does not need it: the screen sets
# its backlight with t551m-screen-power set, which lets the touch screen go
# itself.  Stopped only with its lock held, never inside a backlight change
# -- every later one would wait on that lock, and the screen not light.
WATCHPAUSED=/var/run/hotspotdata.watch-paused
SP_LOCK=/run/t551m-screen-power.lock
dark_watch=0
wdark_since=
watch_pause() {
	local p
	[ -f "$WATCHPAUSED" ] && return
	p=$(pgrep -f 't551m-screen-power watch' | head -n 1)
	[ -n "$p" ] || return
	if flock "$SP_LOCK" kill -STOP "$p" 2>/dev/null; then
		echo "$p" > "$WATCHPAUSED"
	fi
}
watch_resume() {
	local p
	[ -f "$WATCHPAUSED" ] || return 0
	read -r p < "$WATCHPAUSED"
	rm -f "$WATCHPAUSED"
	[ -n "$p" ] && kill -CONT "$p" 2>/dev/null
	return 0
}
# (every loop turn: builtins, and the setting as the last full pass read it)
screen_watch() {
	if [ "$dark_watch" = 1 ] && [ "$state" != disabled ] && ! screen_lit; then
		[ -n "$wdark_since" ] || wdark_since=$NOW
		[ $((NOW - wdark_since)) -ge "$SCREEN_HOLD" ] && watch_pause
	else
		wdark_since=
		watch_resume
	fi
}

# The loop's pause, a second at a time: with the hotspot off and boost on, a
# screen that lights or goes dark ends it, so full speed comes within a second.
nap() {
	local i=0 lit=0
	if ! { [ "$state" = off ] && [ "$boost" = 1 ]; }; then
		sleep "$NAP_LONG"
		return
	fi
	screen_lit && lit=1
	while [ "$i" -lt "$NAP_STEPS" ]; do
		sleep "$NAP"
		i=$((i + 1))
		[ "$state" = off ] && [ "$boost" = 1 ] || continue
		if screen_lit; then [ "$lit" = 1 ] || return 0; else [ "$lit" = 0 ] || return 0; fi
	done
}

# the hotspot-off CPU limits, as the screen allows
limits_off() {
	local now
	if [ "$boost" = 1 ] && screen_lit; then
		dark_since=
		if [ -f "$PERF" ] || [ -f "$CORES" ]; then
			quiet=1; cores_on; perf_restore; quiet=
			: > "$BOOSTED"
		fi
		return
	fi
	now=$(uptime_s)
	[ -n "$dark_since" ] || dark_since=$now
	# (after a lit screen, dark for SCREEN_HOLD s first: a glance does not cycle the cores)
	if [ -f "$BOOSTED" ]; then
		[ $((now - dark_since)) -ge "$SCREEN_HOLD" ] || return
		quiet=1
	fi
	if perf_wanted; then perf_low; else perf_restore; fi
	cores_off
	quiet=
	rm -f "$BOOSTED"
}

# With bt_off: Bluetooth powered off with the hotspot (bluetoothctl, as the
# screen's own switch does: the kernel then disables the WCN chip's BT core),
# once per hotspot-off -- not while a device is connected (looked at again at
# the next full pass); powered on again with the hotspot only if it was us.
BTOFF=/var/run/hotspotdata.bt-off
bt_wanted() { [ "$(uci -q get "$CFG.settings.bt_off")" != 0 ]; }

bt_off() {
	[ "$bt_done" = 1 ] && return
	command -v bluetoothctl >/dev/null 2>&1 || { bt_done=1; return; }
	timeout 10 bluetoothctl show 2>/dev/null | grep -q 'Powered: yes' || { bt_done=1; return; }
	[ -z "$(timeout 10 bluetoothctl devices Connected 2>/dev/null)" ] || return
	if timeout 15 bluetoothctl power off >/dev/null 2>&1; then
		: > "$BTOFF"
		log "hotspot off: Bluetooth off"
	fi
	bt_done=1
}

bt_on() {
	[ -f "$BTOFF" ] || return 0
	rm -f "$BTOFF"
	if timeout 15 bluetoothctl power on >/dev/null 2>&1; then
		log "Bluetooth on again"
	else
		log "Bluetooth did not power on"
	fi
}

# With idle_off minutes: the hotspot turned off when no device has been on it
# -- no Wi-Fi station (hostapd's get_clients; the driver has no station dump)
# and no computer on the USB port (usb0 with a carrier) -- for that long.  The
# same switch as the screen's (/usr/libexec/unisoc-modem/hotspot off); the rest
# follows as for any hotspot-off.  Looked at every IDLE_CHECK s.
HOTSPOT_SWITCH=/usr/libexec/unisoc-modem/hotspot
IDLE_CHECK=30
idle_minutes() {
	local v
	v=$(uci -q get "$CFG.settings.idle_off")
	case "$v" in ''|*[!0-9]*) v=30 ;; esac
	echo "$v"
}

wifi_clients() {
	local o n=0 c
	for o in $(ubus list 'hostapd.*' 2>/dev/null); do
		c=$(ubus call "$o" get_clients 2>/dev/null | grep -c '"assoc": *true')
		n=$((n + ${c:-0}))
	done
	echo "$n"
}

usb_in_use() { [ "$(cat /sys/class/net/usb0/carrier 2>/dev/null)" = 1 ]; }

idle_check() {
	local mins
	[ "$NOW" -ge "$idle_next" ] || return
	idle_next=$((NOW + IDLE_CHECK))
	mins=$(idle_minutes)
	[ "$mins" -gt 0 ] || { idle_since=$NOW; return; }
	if [ "$(wifi_clients)" -gt 0 ] || usb_in_use; then
		idle_since=$NOW
		return
	fi
	[ $((NOW - idle_since)) -ge $((mins * 60)) ] || return
	log "hotspot: no device on it for $mins min, turning it off"
	"$HOTSPOT_SWITCH" off >/dev/null 2>&1 || log "the hotspot switch failed"
	idle_since=$NOW
}

# Light passes: with the hotspot off and everything in place, most loops only
# look -- with shell builtins -- whether a configuration a change would come
# through has changed (the hotspot's switch, LuCI and the screen all commit
# /etc/config) or the screen did; the full pass runs then, and at least every
# FULL_GAP s for what changes without them (a re-dialled interface).  The
# light pass keeps the SIM file fresh and asks the radio when that is due.
STAMP=/var/run/hotspotdata.stamp
FULL_GAP=30
WATCHED="/etc/config/wireless /etc/config/network /etc/config/$CFG /etc/config/unisoc_modem"

now_set() { read -r NOW _ < /proc/uptime; NOW=${NOW%.*}; }

light_ok() {
	local f s
	[ "$state" = off ] && [ "$offed" = 1 ] || return 1
	[ "$NOW" -lt "$full_next" ] || return 1
	[ -f "$BOOSTED" ] && return 1
	for f in $WATCHED; do
		[ -f "$f" ] && ! [ "$f" -ot "$STAMP" ] && return 1
	done
	if [ "$boost" = 1 ]; then
		if screen_lit; then s=1; else s=0; fi
		[ "$s" = "$screen_was" ] || return 1
	fi
	return 0
}

light_pass() {
	if [ -f "$PAUSED" ] && [ "$NOW" -ge "$sims_next" ]; then
		sims_write_off
		sims_next=$((NOW + 10))
	fi
	[ "$NOW" -ge "$radio_next" ] && radio_apply "$m"
}

guard_check() {
	[ -n "$guard_until" ] && [ "$(uptime_s)" -ge "$guard_until" ] || return 0
	: > "$VERIFIED"
	rm -f "$GUARD"; sync
	guard_until=
	log "CPU core shutdown works on this device: no more flash guard"
}

sim_status_resume() {
	[ -f "$PAUSED" ] || return
	"$SIMSTAT" start >/dev/null 2>&1
	rm -f "$PAUSED"
	log "SIM status polling (t551m-sim-status) resumed"
}

# The radios back on, those it was us who turned off.  A card whose AT owner
# does not answer, or that refuses CFUN=1, keeps its mark: false, and the main
# loop tries again every RADIO_RETRY s (a dropped mark left a card at CFUN 4
# for good, and data never came back).
radio_restore() {
	local c v rc=0
	for c in 0 1; do
		[ -f "$MARK.$c" ] || continue
		v=$(cfun_get "$c")
		case "$v" in
			4)
				if cfun_set "$c" 1; then
					log "cellular radio on (SIM $((c + 1)), AT+CFUN=1)"
					rm -f "$MARK.$c"
				else
					log "AT+CFUN=1 failed (SIM $((c + 1))), again in ${RADIO_RETRY}s"
					rc=1
				fi ;;
			'')
				log "SIM $((c + 1)): no answer to AT+CFUN?, radio on again in ${RADIO_RETRY}s"
				rc=1 ;;
			*)
				rm -f "$MARK.$c" ;;     # (on already, or a CP that restarted)
		esac
	done
	# (after the radio: its first reading is of the card coming back)
	sim_status_resume
	return $rc
}

radio_marked() { [ -f "$MARK.0" ] || [ -f "$MARK.1" ]; }

# ModemManager without a modem ("无模组"): the CP or the WWAN port went away
# and ModemManager forgot it.  While the hotspot is on and that lasts
# MODEM_LOST s, the port is bound again the way e5-sim switches cards --
# ModemManager stopped, sipc_wwan reloaded, ModemManager started -- at most
# once in RECOVER_GAP s, and data brought up after it.
modem_recover() {
	local i c n=0
	i=$(data_iface)
	log "no modem for ${MODEM_LOST}s: binding the modem again (as e5-sim does)"
	ifdown "$i"
	/etc/init.d/modemmanager stop
	/etc/init.d/e5-sipc-wwan restart
	/etc/init.d/modemmanager start
	# the port is back when ModemManager has the modem; its radio as well
	while [ -z "$(modem_state)" ] && [ "$n" -lt 60 ]; do sleep 2; n=$((n + 2)); done
	c=$(data_card)
	[ "$(cfun_get "$c")" = 4 ] && cfun_set "$c" 1 && log "cellular radio on after rebinding (SIM $((c + 1)))"
	rm -f "$MARK.$c"
	ubus call network.interface up "{\"interface\":\"$i\"}"
	if [ -n "$(modem_state)" ]; then
		log "modem back after ${n}s, mobile data ($i) up"
	else
		log "still no modem after rebinding: a reboot may be needed"
	fi
}

# while the hotspot is on: a radio still off, a modem gone
watch_on() {
	local now
	now=$(uptime_s)
	[ "$now" -ge "$watch_next" ] || return
	watch_next=$((now + RADIO_RETRY))
	if radio_marked && radio_restore; then
		data_active "$(data_iface)" ||
			ubus call network.interface up "{\"interface\":\"$(data_iface)\"}"
	fi
	if [ -n "$(modem_state)" ]; then
		lost_since=0
		return
	fi
	[ "$lost_since" -gt 0 ] || lost_since=$now
	[ $((now - lost_since)) -ge "$MODEM_LOST" ] || return
	[ $((now - recovered_at)) -ge "$RECOVER_GAP" ] || return
	recovered_at=$now
	modem_recover
	lost_since=0
}

# disable_modem 0 for mode data, set by us and marked so (managed_dm); given
# back -- deleted, the proto's default 1 -- for mode radio and when we let go
set_keep_radio() {
	local i
	i=$(data_iface)
	if [ "$1" = 1 ]; then
		[ "$(uci -q get "network.$i.disable_modem")" = 0 ] && return
		uci set "network.$i.disable_modem=0"
		uci commit network
		uci set "$CFG.settings.managed_dm=1"
		uci commit "$CFG"
	elif [ "$(uci -q get "$CFG.settings.managed_dm")" = 1 ]; then
		uci -q delete "network.$i.disable_modem"
		uci commit network
		uci -q delete "$CFG.settings.managed_dm"
		uci commit "$CFG"
	fi
}

data_off() {
	local i
	i=$(data_iface)
	if [ "$(uci -q get "network.$i.auto")" != 0 ]; then
		uci set "network.$i.auto=0"
		uci commit network
	fi
	if data_active "$i" || data_autostart "$i"; then
		log "hotspot off: mobile data ($i) down"
		ifdown "$i"
		# (the proto's teardown is still running: look at the radio a bit later)
		radio_next=$(($(uptime_s) + 10))
	fi
}

# The radio as the mode wants it while the hotspot is off, looked at every
# RADIO_RETRY s: mode radio keeps it off, mode data puts it back once.
radio_apply() {
	local m s c now
	m=$1
	now=$(uptime_s)
	[ "$now" -ge "$radio_next" ] || return
	radio_next=$((now + radio_gap))
	data_active "$(data_iface)" && return
	if [ "$m" = data ]; then
		[ "$radio_done" = data ] && return
		radio_restore
		if [ "$(modem_state)" = disabled ]; then
			log "hotspot off, data only: modem enabled for SMS and calls"
			mmcli -m any --timeout=30 --enable >/dev/null 2>&1 || return
		fi
		radio_done=data
		return
	fi
	radio_done=radio
	s=$(modem_state)
	case "$s" in
		# Never touch the radio while ModemManager has no modem or is still
		# probing it: the radio going off under its probe can make it give
		# the device up for good (at boot, with the hotspot off) -- "无模组".
		''|disabling|enabling|initializing) return ;;
		disabled|failed|locked) ;;
		*) mmcli -m any --timeout=30 --disable >/dev/null 2>&1 ;;
	esac
	c=$(data_card)
	case "$(cfun_get "$c")" in
		1)
			: > "$MARK.$c"
			radio_gap=$RADIO_RETRY
			if cfun_set "$c" 4; then
				log "hotspot off: cellular radio off (SIM $((c + 1)), AT+CFUN=4)"
			else
				log "AT+CFUN=4 failed (SIM $((c + 1))), again in ${RADIO_RETRY}s"
				return
			fi ;;
		4)
			[ -f "$MARK.$c" ] || : > "$MARK.$c"
			# off and staying off: AT+CFUN? wakes the modem, so ask less
			# often -- 30 s, doubling to RADIO_GAP_MAX
			radio_gap=$((radio_gap * 2))
			[ "$radio_gap" -le "$RADIO_GAP_MAX" ] || radio_gap=$RADIO_GAP_MAX ;;
		*)
			return ;;
	esac
	# the radio is off (CFUN 4): nothing for the poller to read
	if pause_wanted; then sim_status_pause; else sim_status_resume; fi
}

# (ubus "up", not ifup: ifup reloads the network and restarts an interface
# that is already up)
data_on() {
	local i
	i=$(data_iface)
	radio_restore
	if [ "$(uci -q get "network.$i.auto")" = 0 ]; then
		uci -q delete "network.$i.auto"
		uci commit network
	fi
	if ! data_active "$i"; then
		log "hotspot on: mobile data ($i) up"
		ubus call network.interface up "{\"interface\":\"$i\"}"
	fi
}

# linking off: everything as it was before the app
give_back() {
	watch_resume
	cores_on
	perf_restore
	rm -f "$BOOSTED"
	bt_on
	set_keep_radio 0
	radio_restore
	[ "$(uci -q get "network.$(data_iface).auto")" = 0 ] && data_on
}

# the app is gone: USB 关闭（usb-off.sh) given back -- data on, the port
# automatic -- and the USB page's patch out
usb_off_clear() {
	local p
	sed -i '/^\/\* BEGIN e5-usboff/,/^\/\* END e5-usboff \*\//d' \
		/usr/share/e5-infoscreen/settings.uc 2>/dev/null
	[ "$(uci -q get "$CFG.settings.usb_off")" = 1 ] ||
		[ "$(cat /sys/class/usb_notify/usb_control/usb_data_enabled 2>/dev/null)" = 0 ] || return 0
	echo 1 > /sys/class/usb_notify/usb_control/usb_data_enabled 2>/dev/null
	for p in /sys/bus/platform/devices/*/usb_role_policy; do
		[ "$(cat "$p" 2>/dev/null)" = device ] && echo auto > "$p" 2>/dev/null
	done
	uci -q delete "$CFG.settings.usb_off" && uci commit "$CFG"
	/etc/init.d/e5-usb-watch start >/dev/null 2>&1
	log "USB off given back: USB on again"
}

# the app is gone: data back to normal, and this service with it
remove_self() {
	cpu_off_clear
	usb_off_clear
	give_back
	log "app removed: mobile data restored, service removed"
	"$INIT" disable 2>/dev/null
	rm -f "$INIT"
	# (procd stops this process here)
	ubus call service delete '{"name":"hotspot-data"}'
	exit 0
}

# the version that runs, for the backend: a reinstalled app restarts us
cp "$DIR/service.sh" /var/run/hotspotdata.running 2>/dev/null

# a watcher a stopped (or killed) service left paused: going again; and this
# one stopped by procd gives it back before it goes
watch_resume
trap 'watch_resume; exit 0' TERM INT HUP

# a core shutdown the last boot did not live through: not again
if [ -f "$GUARD" ]; then
	rm -f "$GUARD"; sync
	uci set "$CFG.settings.cores=all" && uci commit "$CFG"
	rm -f "$CPUOFF_SAVED"
	log "the last CPU core shutdown did not finish (a crash, or power lost): core shutdown turned off"
fi
guard_until=

# The CPU page's OFF saved with the CPU profile: off again at boot (only
# after a boot is the runtime list gone with SAVED still there), under the
# same flash guard as the core shutdown; without the profile, not kept.
if [ -f "$CPUOFF_SAVED" ] && [ ! -f "$CPUOFF_LIST" ] && [ -f "$CPUOFF" ]; then
	if [ -f "$CPU_PROFILE" ]; then
		cp "$CPUOFF_SAVED" "$CPUOFF_LIST"
		[ -f "$VERIFIED" ] || { : > "$GUARD"; sync; guard_until=$(($(uptime_s) + 30)); }
		sh "$CPUOFF" apply
		log "CPU page OFF at boot: $(echo $(cat "$CPUOFF_LIST"))"
	else
		rm -f "$CPUOFF_SAVED"
	fi
fi
# USB 关闭 (usb-off.sh, the USB page) kept: off again at boot -- after the
# system's own USB role (unisoc-modem-ui starts before this service)
[ -f "$DIR/usb-off.sh" ] && sh "$DIR/usb-off.sh" apply
dark_since=
boost=0

state=
off_since=0
radio_done=
radio_next=0
radio_gap=$RADIO_RETRY
watch_next=0
lost_since=0
recovered_at=-100000
offed=0
full_next=0
sims_next=0
screen_was=0
idle_since=0
idle_next=0
bt_done=
NOW=0
m=radio
full_pass() {
	boost=0; boost_wanted && boost=1
	dark_watch=0; [ "$(uci -q get "$CFG.settings.dark_watch")" != 0 ] && dark_watch=1
	if ! enabled; then
		if [ "$state" != disabled ]; then
			give_back
			log "linking disabled"
			state=disabled
		elif radio_marked && [ "$(uptime_s)" -ge "$watch_next" ]; then
			# (a radio give_back could not turn on yet)
			watch_next=$(($(uptime_s) + RADIO_RETRY))
			radio_restore && data_on
		fi
	else
		m=$(mode)
		if [ "$m" = data ]; then set_keep_radio 1; else set_keep_radio 0; fi
		if hotspot_on; then
			if [ "$state" != on ]; then
				# (full speed first: the hotspot is about to carry traffic)
				cores_on
				perf_restore
				rm -f "$BOOSTED"
				data_on
				bt_on
				state=on
				offed=0
				lost_since=0
				watch_next=$(($(uptime_s) + RADIO_RETRY))
				idle_since=$NOW
				idle_next=$((NOW + IDLE_CHECK))
			fi
			watch_on
			idle_check
		else
			if [ "$state" != off ]; then
				off_since=$(uptime_s)
				radio_done=
				radio_next=0
				radio_gap=$RADIO_RETRY
				bt_done=
				offed=0
				state=off
			fi
			# a mode change while off is looked at now
			[ -n "$radio_done" ] && [ "$radio_done" != "$m" ] && radio_next=0
			if [ $(($(uptime_s) - off_since)) -ge "$(off_delay)" ]; then
				data_off
				radio_apply "$m"
				if [ -f "$PAUSED" ]; then
					sims_write_off
					sims_next=$((NOW + 10))
				fi
				limits_off
				if bt_wanted; then bt_off; else bt_on; fi
				offed=1
			fi
		fi
	fi
	perf_pending
	# the CPU page's OFF, whatever brought a core online
	[ -s "$CPUOFF_LIST" ] && [ -f "$CPUOFF" ] && sh "$CPUOFF" apply
	if screen_lit; then screen_was=1; else screen_was=0; fi
}

while :; do
	[ -f "$DIR/manifest.json" ] || remove_self
	now_set
	if light_ok; then
		light_pass
	else
		full_pass
		echo "$NOW" > "$STAMP"
		full_next=$((NOW + FULL_GAP))
	fi
	guard_check
	screen_watch
	nap
done
