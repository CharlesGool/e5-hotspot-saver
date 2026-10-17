#!/bin/sh
# 热点省电 (Hotspot Power Saver): OFF for a CPU domain on the screen's CPU page
# (设置 → 系统 → CPU 设置).  The app's patch of settings.uc (cpu-patch.uc) sends
# every change on that page through this, and service.sh keeps what it says:
#
#   cpu-off.sh get               JSON: how many cores each domain turned off keeps;
#                                each domain's CPUs, those that never go offline
#                                (cpu0, and any without an online file), those
#                                offline now, and its choices; and FULL
#   cpu-off.sh set '{id,value}'  a change on the CPU page: <policy>_cores (the
#                                关闭核心 row) "off" takes the domain's cores
#                                offline, "keep1" "keep2" "keep4" all but its first
#                                1, 2 or 4, "on" none; anything else goes to
#                                cpu-control, and a domain that is off stays so (its
#                                governor and limits are set while it is online for
#                                the call).  Prints cpu-control's reply.
#   cpu-off.sh apply             the domains turned off held offline (service.sh)
#   cpu-off.sh snapshot          FULL, if there is none yet
#
# A domain of one core has OFF; one of more has "keep 1, 2 or 4" (those fewer
# than it has), and OFF as well unless a core of it never goes (cpu0: then
# keep 1 is that core alone).  OFF lists "<policy> <cores kept>"; OFF_CPUS
# the cores that makes offline, for service.sh and the app's page.
#
# cpu-control (shared with LuCI) reads a domain with no core online as empty --
# no CPUs, no frequencies -- and with the boot profile on (/etc/e5-cpu.json) it
# saves it so, which the next boot rejects ("CPU topology changed").  So every
# change goes to it with every core online: the offline ones (turned off here,
# or by the hotspot-off core shutdown) come online for the call and go again
# after it.  Its reply then has every domain whole: kept as FULL, from which
# the page draws a domain that is off.
#
# At least MIN_ON cores stay out of the domains turned off: a choice that would
# leave fewer is refused, and get leaves it out of a domain's allowed ones.
# (One core alone carries the screen, the network and the modem's interrupts;
# service.sh keeps as many with the hotspot off.)
#
# OFF lasts until a reboot, like the CPU page's own changes; with the boot
# profile on it is saved too (SAVED), and service.sh turns it off again at boot.

R=${HOTSPOTDATA_TEST_ROOT:-}
CPUSYS=$R/sys/devices/system/cpu
CTL=$R/usr/libexec/unisoc-modem/cpu-control
OFF=$R/var/run/hotspotdata.cpu-off
OFF_CPUS=$R/var/run/hotspotdata.cpu-off.cpus
SAVED=$R/etc/hotspotdata.cpu-off
FULL=$R/var/run/hotspotdata.cpu-full.json
CORES=$R/var/run/hotspotdata.cores           # (service.sh: offline with the hotspot off)
PERF=$R/var/run/hotspotdata.perf             # (service.sh: the clocks held low)
PERF_PENDING=$R/var/run/hotspotdata.perf-pending
LOCK=$R/var/run/hotspotdata.cpu.lock
CPU_PROFILE=$R/etc/e5-cpu.json

MIN_ON=2

log() { logger -t hotspotdata -- "$*"; }

# (changes one at a time, and not while service.sh moves cores)
case "$1" in
	set|apply)
		[ -n "$HOTSPOTDATA_CPU_LOCKED" ] ||
			HOTSPOTDATA_CPU_LOCKED=1 exec flock "$LOCK" sh "$0" "$@" ;;
esac

policies() {
	local p
	for p in "$CPUSYS"/cpufreq/policy*; do
		case "${p##*/}" in policy|policy*[!0-9]*) continue ;; esac
		echo "${p##*/}"
	done
}

# A domain's CPUs, from each CPU's cpufreq link: a domain with no core online
# cannot read its own related_cpus (EBUSY).
cpus_of() {
	local d l
	for d in "$CPUSYS"/cpu[0-9]*; do
		l=$(readlink "$d/cpufreq" 2>/dev/null) || continue
		[ "${l##*/}" = "$1" ] && echo "${d##*/cpu}"
	done | sort -n | tr '\n' ' '
}

# (never cpu0, the boot CPU: one core always stays, and the one the system
# started on -- the hotspot-off core shutdown keeps it as well)
can_off() { [ "$1" != 0 ] && [ -f "$CPUSYS/cpu$1/online" ]; }

offline_now() {
	local d
	for d in "$CPUSYS"/cpu[0-9]*; do
		[ -f "$d/online" ] && [ "$(cat "$d/online")" = 0 ] && echo "${d##*/cpu}"
	done
}

# the cores a domain turned off keeps (0 for none), nothing for one that is on
keep_of() {
	local p k
	[ -f "$OFF" ] || return 0
	while read -r p k; do
		[ "$p" = "$1" ] && { echo "${k:-0}"; return; }
	done < "$OFF"
}

is_off() { [ -n "$(keep_of "$1")" ]; }

# OFF, with domain $1 keeping $2 cores ("" for on)
off_list_with() {
	local p k
	if [ -f "$OFF" ]; then
		while read -r p k; do
			[ -n "$p" ] && [ "$p" != "$1" ] && echo "$p ${k:-0}"
		done < "$OFF"
	fi
	[ -z "$2" ] || echo "$1 $2"
}

off_put() {
	off_list_with "$1" "$2" > "$OFF.new"
	mv -f "$OFF.new" "$OFF"
	[ -s "$OFF" ] || rm -f "$OFF"
}

# the cores domain $1 keeping $2 takes offline: all but its first $2
cpus_off_of() {
	local c i=0
	for c in $(cpus_of "$1"); do
		i=$((i + 1))
		[ "$i" -le "$2" ] && continue
		can_off "$c" && echo "$c"
	done
}

# the cores the domains turned off take offline -- with domain $1 keeping $2
# when given ("" for on)
off_cpus() {
	local p k
	if [ $# -gt 0 ]; then
		off_list_with "$1" "$2"
	elif [ -f "$OFF" ]; then
		cat "$OFF"
	fi | while read -r p k; do
		[ -n "$p" ] && cpus_off_of "$p" "${k:-0}"
	done
}

# how many cores are left online by the domains turned off, with domain $1 keeping $2
left_with() {
	local d n=0 off
	off=" $(echo $(off_cpus "$1" "$2")) "
	for d in "$CPUSYS"/cpu[0-9]*; do
		case "$off" in *" ${d##*/cpu} "*) ;; *) n=$((n + 1)) ;; esac
	done
	echo "$n"
}

# the choices of a domain (cores kept: 0 is OFF): see the top
choices_of() {
	local c n=0 f=0 k out=
	for c in $(cpus_of "$1"); do
		n=$((n + 1))
		can_off "$c" || f=$((f + 1))
	done
	[ "$n" -gt "$f" ] || return 0               # (no core of it can go)
	[ "$n" = 1 ] && { echo 0; return; }
	[ "$f" = 0 ] && out=0
	for k in 1 2 4; do [ "$k" -lt "$n" ] && out="$out $k"; done
	echo $out
}

# those of them allowed now: the one it has, and those leaving MIN_ON cores
allowed_of() {
	local k cur out=
	cur=$(keep_of "$1")
	for k in $(choices_of "$1"); do
		if [ "$k" = "$cur" ] || [ "$(left_with "$1" "$k")" -ge "$MIN_ON" ]; then out="$out $k"; fi
	done
	echo $out
}

# OFF_CPUS as OFF says
cpus_sync() {
	off_cpus > "$OFF_CPUS.new"
	if [ -s "$OFF_CPUS.new" ]; then mv -f "$OFF_CPUS.new" "$OFF_CPUS"; else rm -f "$OFF_CPUS.new" "$OFF_CPUS"; fi
}

cpu_set_online() {
	echo "$2" > "$CPUSYS/cpu$1/online" 2>/dev/null && return 0
	if [ "$2" = 1 ]; then log "cpu$1 cannot come online"; else log "cpu$1 cannot go offline"; fi
	return 1
}

# the cores the domains turned off take offline: offline
hold() {
	local c n=
	for c in $(off_cpus); do
		[ "$(cat "$CPUSYS/cpu$c/online" 2>/dev/null)" = 1 ] || continue
		cpu_set_online "$c" 0 && n="$n $c"
	done
	[ -z "$1" ] || [ -z "$n" ] || log "CPU page OFF: CPU$n offline again"
}

# The limits service.sh could not give back to a domain with no core online
# (PERF_PENDING), written while it is online for cpu-control -- before it reads
# them, and saves them in the boot profile.  Not while the clocks are held.
# (A limit as it reads: the requested one where the kernel has it.)
limit_now() {
	local r
	r=$(echo "$1" | sed 's/scaling_\(m[a-z]*_freq\)$/scaling_requested_\1/')
	[ "$r" != "$1" ] && [ -f "$r" ] && { cat "$r"; return; }
	cat "$1"
}
perf_pending() {
	local path old ours
	[ -f "$PERF_PENDING" ] && [ ! -f "$PERF" ] || return 0
	: > "$PERF_PENDING.new"
	while read -r path old ours; do
		if ! cat "$R$path" >/dev/null 2>&1; then
			echo "$path $old $ours" >> "$PERF_PENDING.new"
		elif [ "$(limit_now "$R$path")" = "$ours" ]; then
			echo "$old" > "$R$path" 2>/dev/null
		fi
	done < "$PERF_PENDING"
	if [ -s "$PERF_PENDING.new" ]; then mv -f "$PERF_PENDING.new" "$PERF_PENDING"; else rm -f "$PERF_PENDING.new" "$PERF_PENDING"; fi
}

# While service.sh holds the clocks low (PERF: "path old ours"), cpu-control
# gets the real limits for the call -- it reads them, and saves them in the
# boot profile -- and they are held again after it: a limit the call changed
# is what the hotspot's restore gives back.
perf_unhold() {
	local path old ours
	[ -f "$PERF" ] || return 0
	while read -r path old ours; do
		[ -n "$old" ] && [ -n "$ours" ] || continue
		[ "$(limit_now "$R$path" 2>/dev/null)" = "$ours" ] && echo "$old" > "$R$path" 2>/dev/null
	done < "$PERF"
}
perf_rehold() {
	local path old ours now
	[ -f "$PERF" ] || return 0
	: > "$PERF.new"
	while read -r path old ours; do
		now=$(limit_now "$R$path" 2>/dev/null)
		[ -n "$now" ] && [ -n "$ours" ] && old=$now
		echo "$path $old $ours" >> "$PERF.new"
		[ -n "$ours" ] && echo "$ours" > "$R$path" 2>/dev/null
	done < "$PERF"
	mv -f "$PERF.new" "$PERF"
}

# While they are held, a domain online again (not held: it had no core online
# when they were) is held with them -- into PERF with what it is to get back,
# its PERF_PENDING limits or else its own, and at its lowest.
perf_join() {
	local p d path lo name line old
	[ -f "$PERF" ] || return 0
	for p in $(policies); do
		d=$CPUSYS/cpufreq/$p
		[ -n "$(cat "$d/affected_cpus" 2>/dev/null)" ] || continue
		path=${d#$R}
		grep -q "^$path/scaling_max_freq " "$PERF" && continue
		lo=$(tr ' ' '\n' < "$d/scaling_available_frequencies" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | head -n 1)
		[ -n "$lo" ] || lo=$(cat "$d/cpuinfo_min_freq" 2>/dev/null)
		[ -n "$lo" ] || continue
		for name in scaling_max_freq scaling_min_freq; do
			line=$(grep "^$path/$name " "$PERF_PENDING" 2>/dev/null | head -n 1)
			old=$(echo "$line" | cut -d' ' -f2)
			[ -n "$old" ] || old=$(limit_now "$d/$name")
			echo "$path/$name $old $lo" >> "$PERF"
			if [ -n "$line" ]; then
				grep -v "^$path/$name " "$PERF_PENDING" > "$PERF_PENDING.new"
				mv -f "$PERF_PENDING.new" "$PERF_PENDING"
				[ -s "$PERF_PENDING" ] || rm -f "$PERF_PENDING"
			fi
		done
		echo "$lo" > "$d/scaling_min_freq" 2>/dev/null
		echo "$lo" > "$d/scaling_max_freq" 2>/dev/null
		log "CPU page: $p online while the clocks are held low: held with them"
	done
}

# a cpu-control reply with every domain whole, as FULL
full_save() {
	case "$1" in *'"policies"'*) ;; *) return ;; esac
	case "$1" in *'"cpus":""'*) return ;; esac
	printf '%s\n' "$1" > "$FULL.new" && mv -f "$FULL.new" "$FULL"
}

snapshot() {
	[ -s "$FULL" ] || full_save "$("$CTL" get 2>/dev/null)"
}

# SAVED as OFF while the boot profile is on, gone otherwise
save_sync() {
	if [ -s "$OFF" ] && [ -f "$CPU_PROFILE" ]; then
		cmp -s "$OFF" "$SAVED" || { cp "$OFF" "$SAVED.new" && mv -f "$SAVED.new" "$SAVED"; }
	else
		rm -f "$SAVED"
	fi
}

reply_error() {
	printf '{"ok":false,"error":"%s"}\n' "$1"
}

# "1 2 4" -> 1,2,4 (a JSON array's insides)
commas() { echo $* | tr ' ' ','; }

do_get() {
	local p k c cpus fixed offl sep=
	printf '{"ok":true,"off":{'
	if [ -f "$OFF" ]; then
		while read -r p k; do
			[ -n "$p" ] || continue
			printf '%s"%s":%s' "$sep" "$p" "${k:-0}"
			sep=,
		done < "$OFF"
	fi
	printf '},"policies":{'
	sep=
	for p in $(policies); do
		cpus=$(echo $(cpus_of "$p"))
		fixed= offl=
		for c in $cpus; do
			if can_off "$c"; then
				[ "$(cat "$CPUSYS/cpu$c/online")" = 0 ] && offl="$offl $c"
			else
				fixed="$fixed $c"
			fi
		done
		printf '%s"%s":{"cpus":"%s","fixed":"%s","offline":"%s","choices":[%s],"allowed":[%s]}' \
			"$sep" "$p" "$cpus" "$(echo $fixed)" "$(echo $offl)" \
			"$(commas $(choices_of "$p"))" "$(commas $(allowed_of "$p"))"
		sep=,
	done
	printf '},"full":'
	if [ -s "$FULL" ]; then cat "$FULL"; else echo null; fi
	printf '}\n'
}

do_set() {
	local req=$1 id value p= k= row= c was was_user held reply
	id=$(jsonfilter -s "$req" -e '@.id' 2>/dev/null)
	value=$(jsonfilter -s "$req" -e '@.value' 2>/dev/null)
	case "$id" in policy[0-9]*_cores) p=${id%_cores} row=1 ;; esac
	if [ -n "$p" ] && ! [ -d "$CPUSYS/cpufreq/$p" ]; then
		reply_error 'CPU policy missing'
		return
	fi
	if [ -n "$row" ]; then
		case "$value" in
			off) k=0 ;;
			keep[0-9]) k=${value#keep} ;;
			on) ;;
			*) reply_error 'Unknown choice'; return ;;
		esac
	fi
	was=$(offline_now)
	was_user=$(off_cpus)
	held=$(echo $(cat "$CORES" 2>/dev/null))
	if [ -n "$k" ]; then
		case " $(choices_of "$p") " in
			*" $k "*) ;;
			*) reply_error 'These CPUs cannot go offline so'; return ;;
		esac
		case " $(allowed_of "$p") " in
			*" $k "*) ;;
			*) reply_error "至少保留 $MIN_ON 个核心在线（at least $MIN_ON CPU cores stay online）"; return ;;
		esac
		off_put "$p" "$k"
		log "CPU page: $p keeps $k (CPU $(echo $(cpus_off_of "$p" "$k")) off)"
	elif [ -n "$row" ] && is_off "$p"; then
		off_put "$p" ""
		log "CPU page: $p on again"
	elif [ "$id" = reset ] && [ -f "$OFF" ]; then
		rm -f "$OFF"
		log "CPU page: restore defaults, every domain on again"
	fi
	cpus_sync
	# every core online for cpu-control
	for c in $was; do cpu_set_online "$c" 1; done
	perf_pending
	perf_unhold
	if [ -n "$row" ]; then
		reply=$("$CTL" get 2>/dev/null)
	else
		reply=$("$CTL" set "$req" 2>/dev/null)
	fi
	perf_rehold
	full_save "$reply"
	# offline again: those that were -- but those no longer off by the CPU
	# page only where the hotspot-off core shutdown holds them; and every core
	# the domains turned off take offline now
	for c in $was; do
		case " $(echo $was_user) " in
			*" $c "*) case " $held " in *" $c "*) ;; *) continue ;; esac ;;
		esac
		cpu_set_online "$c" 0
	done
	hold
	perf_join
	save_sync
	if [ -n "$reply" ]; then
		printf '%s\n' "$reply"
	else
		reply_error 'CPU control unavailable'
	fi
}

case "$1" in
	get) do_get ;;
	set) do_set "$2" ;;
	apply) { [ -s "$FULL" ] || [ -n "$(offline_now)" ]; } || snapshot; cpus_sync; hold said ;;
	snapshot) snapshot ;;
	*) echo "usage: $0 get|set '{\"id\":...,\"value\":...}'|apply|snapshot" >&2; exit 2 ;;
esac
