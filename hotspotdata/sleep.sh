#!/bin/sh
# 深度休眠 (Deep Sleep) -- the hotspotdata app's second background service: the
# suspending, next to service.sh's saving (/etc/init.d/hotspot-data, instance "sleep").
#
# OpenWrt never asks the kernel to suspend, so the SoC stays awake around the
# clock even with the screen dark and the hotspot off.  The kernel and the
# firmware can do it (/sys/power/mem_sleep offers "deep", PSCI SYSTEM_SUSPEND):
# this service suspends to RAM when nothing needs the system, and sends it
# back to sleep shortly after every wake that nobody asked for.
#
# It suspends only when all of these hold:
#   * the screen has been dark (backlight 0) for `delay` seconds;
#   * the hotspot is off: the Wi-Fi driver stops the AP in suspend and hostapd
#     does not notice, so a suspend with the hotspot up would break it;
#   * no USB power: the MUSB driver refuses to suspend with VBUS in device mode
#     (musb_sprd_pm_suspend), and while charging nothing is drawn from the battery;
#   * the cellular radio is off (service.sh's mark), unless sleep_radio_on is
#     set: with the radio on, the modem wakes the AP every few seconds and the
#     wake/sleep cycles cost more than staying awake;
#   * no PCM playing or capturing (a call, a ringtone);
#   * no userspace wake lock in /sys/power/wake_lock.
# Kernel wakeup sources are honoured through /sys/power/wakeup_count.
#
# The PMIC watchdog (ump9620-pmic-wdt) has no suspend handling and keeps counting
# while the AP sleeps; procd, frozen, cannot ping it, and 30 s of sleep reset the
# board.  So procd closes it with the magic character (which stops it) just
# before each suspend and opens it again right after.
#
# A key (gpio-keys), the charger, the modem, the RTC alarm (sleep_wake_every) wake it,
# and the fuel gauge: its sleep calibration (the relax counter, 4 s a count under
# 30 mA; the device tree's 580 counts are 2320 s) wakes it to read the OCV.
# Settings: e5-plugin-hotspotdata.settings.sleep*, state in /var/run/hotspotdata.sleep/.
# A removed app: service.sh removes the init script; this only gives the watchdog back.

DIR=/etc/e5-infoscreen/plugins/hotspotdata
CFG=e5-plugin-hotspotdata
RUN=/var/run/hotspotdata.sleep
STATE=$RUN/state
STATS=$RUN/stats
WS=/sys/kernel/debug/wakeup_sources
RTC=/sys/class/rtc/rtc0
BACKLIGHT=$(ls /sys/class/backlight/*/brightness 2>/dev/null | head -n 1)
# a sleep shorter than this is "short"; SHORT_MAX of them in a row back off
SHORT_S=10
SHORT_MAX=3
BACKOFF_MIN=60
BACKOFF_MAX=600

log() { logger -t hotspotdata -- "sleep: $*"; }

# e5-plugin-hotspotdata.settings.sleep_<name> ("sleep" itself: on/off)
setting() {
	local v
	v=$(uci -q get "$CFG.settings.$1")
	echo "${v:-$2}"
}

num() {
	case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac
}

uptime_s() { local u; read -r u _ < /proc/uptime; echo "${u%%.*}"; }
# CLOCK_BOOTTIME (/proc/uptime) goes on in suspend, CLOCK_MONOTONIC stops
boot_f() { local u; read -r u _ < /proc/uptime; echo "$u"; }
mono_f() { awk '/^now at/ { printf "%.2f", $3 / 1e9; exit }' /proc/timer_list; }

screen_lit() {
	local v
	[ -n "$BACKLIGHT" ] && read -r v < "$BACKLIGHT" && [ "${v:-0}" -gt 0 ]
} 2>/dev/null

usb_power() {
	local p v
	for p in usb ac; do
		read -r v < "/sys/class/power_supply/$p/online" 2>/dev/null && [ "$v" = 1 ] && return 0
	done
	return 1
}

ap_up() { iw dev 2>/dev/null | grep -q 'type AP'; }

radio_off() { [ -f /var/run/hotspotdata.radio-off.0 ] || [ -f /var/run/hotspotdata.radio-off.1 ]; }

audio_busy() { cat /proc/asound/card*/pcm*/sub*/status 2>/dev/null | grep -q 'RUNNING'; }

user_locks() { local l; read -r l < /sys/power/wake_lock 2>/dev/null; echo "$l"; }

wdt_off() {
	ubus call system watchdog '{"magicclose": true}' >/dev/null 2>&1
	ubus call system watchdog '{"stop": true}' >/dev/null 2>&1
}
wdt_on() { ubus call system watchdog '{"stop": false}' >/dev/null 2>&1; }

# name -> wakeup_count (column 4: the events that ended a suspend)
wsnap() { awk 'NR > 1 { print $1, $4 }' "$WS" 2>/dev/null; }

# irq -> total count, and its name joined with _ (the columns after the per-CPU
# counts: only online CPUs have a column, and a suspend takes none away for good)
irqsnap() {
	awk 'NR > 1 { s = 0; for (i = 2; i <= NF && $i ~ /^[0-9]+$/; i++) s += $i
		d = ""; for (; i <= NF; i++) d = d "_" $i; print $1, s, d }' /proc/interrupts
}

# what ended the suspend, as a short label.  A source's wakeup_count only goes
# up while the kernel is checking for wakeup events, and a key behind the
# PMIC's EIC is often handled after that ("unknown"): so the interrupts that
# fired across the suspend count too -- a key among them is what woke us.
woke_by() {
	local names
	names=$(awk 'NR == FNR { p[$1] = $2; next } $2 > p[$1] { print $1 }' "$RUN/ws.prev" "$RUN/ws.now"
		awk 'NR == FNR { p[$1] = $2; next } $2 > p[$1] && $3 ~ /Key|keypad|extcon|typec|rtc|fgu|mailbox|sdiohal|pub_int/ { print $3 }' \
			"$RUN/irq.prev" "$RUN/irq.now")
	names=$(echo $names)
	case "$names" in
		*gpio-keys*|*keypad*|*Power_Key*|*Volume*|*voice_Key*) echo key ;;
		*charger*|*vchg*|*aw322*|*usb*|*musb*|*typec*|*extcon*) echo power ;;
		# (before the modem: its mailbox fires at every resume)
		*fgu*) echo fgu ;;
		*rtc*) echo rtc ;;
		*sipc*|*smsg*|*sipa*|*modem*|*sbuf*|*mailbox*) echo modem ;;
		*sdiohal*|*pub_int*|*Wi-Fi*|*BT_*|*wcn*) echo wcn ;;
		'') echo unknown ;;
		*) echo other ;;
	esac
	echo "$names" > "$RUN/woke_names"
}

# why the system has to stay awake now, or nothing when it may sleep
reason() {
	[ "$(setting sleep 1)" = 0 ] && { echo disabled; return; }
	screen_lit && { echo screen; return; }
	[ $(($(uptime_s) - dark_since)) -lt "$(num "$(setting sleep_delay 30)" 30)" ] && { echo delay; return; }
	usb_power && { echo power; return; }
	ap_up && { echo hotspot; return; }
	[ "$(setting sleep_radio_on 0)" = 1 ] || radio_off || { echo radio; return; }
	audio_busy && { echo audio; return; }
	[ -n "$(user_locks)" ] && { echo wakelock; return; }
	[ "$(uptime_s)" -lt "$backoff_until" ] && { echo backoff; return; }
	echo
}

put_state() {
	echo "$1" > "$STATE.new" && mv -f "$STATE.new" "$STATE"
}

put_stats() {
	cat > "$STATS.new" <<-EOF
	since=$since
	attempts=$attempts
	sleeps=$sleeps
	fails=$fails
	slept=$slept
	last_at=$last_at
	last_slept=$last_slept
	last_by=$last_by
	backoff_until=$backoff_until
	EOF
	mv -f "$STATS.new" "$STATS"
}

# the app is gone: the watchdog as procd had it (service.sh removes the service)
remove_self() {
	wdt_on
	echo 0 > "$RTC/wakealarm" 2>/dev/null
	rm -rf "$RUN"
	exit 0
}

suspend_once() {
	local cnt every t0 m0 t1 m1 rc by d grace
	# blocks while a kernel wakeup source is active; the watchdog is still on
	cnt=$(timeout 15 cat /sys/power/wakeup_count 2>/dev/null) || { put_state "awake kernel"; return; }
	screen_lit && return
	attempts=$((attempts + 1))
	echo 0 > "$RTC/wakealarm" 2>/dev/null
	every=$(num "$(setting sleep_wake_every 0)" 0)
	[ "$every" -gt 0 ] && echo "+$((every * 60))" > "$RTC/wakealarm" 2>/dev/null
	wsnap > "$RUN/ws.prev"
	irqsnap > "$RUN/irq.prev"
	put_state "asleep"
	wdt_off
	t0=$(boot_f); m0=$(mono_f)
	if echo "$cnt" > /sys/power/wakeup_count 2>/dev/null; then
		if echo mem > /sys/power/state 2>/dev/null; then rc=ok; else rc=fail; fi
	else
		rc=busy
	fi
	wdt_on
	t1=$(boot_f); m1=$(mono_f)
	wsnap > "$RUN/ws.now"
	irqsnap > "$RUN/irq.now"
	by=$(woke_by)
	d=$(awk -v a="$t0" -v b="$t1" -v c="$m0" -v e="$m1" 'BEGIN { d = (b - a) - (e - c); if (d < 0) d = 0; printf "%d", d }')
	if [ "$rc" = ok ]; then
		sleeps=$((sleeps + 1))
		slept=$((slept + d))
		last_slept=$d
		last_by=$by
		last_at=$(date +%s)
		log "slept ${d}s, woken by $by ($(cat "$RUN/woke_names"))"
	else
		fails=$((fails + 1))
		[ "$rc" = fail ] && log "suspend failed: $(cat /sys/power/suspend_stats/last_failed_dev 2>/dev/null) $(cat /sys/power/suspend_stats/last_failed_errno 2>/dev/null)"
	fi
	# wakes that keep coming within seconds cost more than staying awake
	if [ "$rc" != ok ] || [ "$d" -lt "$SHORT_S" ]; then
		short=$((short + 1))
		if [ "$short" -ge "$SHORT_MAX" ]; then
			backoff_until=$(($(uptime_s) + backoff))
			log "$short short sleeps in a row: awake for ${backoff}s"
			backoff=$((backoff * 2)); [ "$backoff" -gt "$BACKOFF_MAX" ] && backoff=$BACKOFF_MAX
			short=0
		fi
	else
		short=0; backoff=$BACKOFF_MIN
	fi
	put_stats
	echo 0 > "$RTC/wakealarm" 2>/dev/null
	# time for whoever woke us (an SMS, a key) before the next try
	grace=$(num "$(setting sleep_grace 5)" 5)
	[ "$by" = modem ] && [ "$grace" -lt 15 ] && grace=15
	put_state "awake grace"
	sleep "$grace"
}

mkdir -p "$RUN"
grep -q debugfs /proc/mounts || mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
cp "$DIR/sleep.sh" "$RUN/running" 2>/dev/null
# (a service killed between the two last time left procd's watchdog stopped)
wdt_on
trap 'wdt_on; put_state stopped; exit 0' TERM INT HUP

since=$(date +%s)
attempts=0; sleeps=0; fails=0; slept=0
last_at=0; last_slept=0; last_by=
short=0; backoff=$BACKOFF_MIN; backoff_until=0
dark_since=$(uptime_s)
put_stats
log "started (delay $(setting sleep_delay 30)s, radio_on $(setting sleep_radio_on 0))"

while :; do
	[ -f "$DIR/manifest.json" ] || remove_self
	if screen_lit; then
		dark_since=$(uptime_s)
		put_state "awake screen"
		sleep 2
		continue
	fi
	r=$(reason)
	if [ -n "$r" ]; then
		put_state "awake $r"
		sleep 2
		continue
	fi
	suspend_once
done
