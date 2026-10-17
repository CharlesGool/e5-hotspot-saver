#!/bin/sh
# 热点省电 (Hotspot Power Saver): USB 关闭（仅充电） for the screen's USB role
# (设置 → 高级 → USB → USB 角色).  The app's patch of settings.uc (usb-patch.uc)
# sends the role through this:
#
#   usb-off.sh get        JSON: whether the kernel has the switches, whether USB is off
#   usb-off.sh set off    the port a sink only, then no USB data; kept for the next boot
#   usb-off.sh set on     USB data back (the screen sets the role it asked for next)
#   usb-off.sh apply      at boot (service.sh): off again if it was left off
#
# Off is two switches the kernel already has.  The Type-C port is held as a
# sink (usb_role_policy "device"): it never powers a device or becomes a host.
# And the musb glue's usb_data_enabled (/sys/class/usb_notify/usb_control, the
# stock kernel's "disable USB data") is 0: the controller makes no connection
# in either role, so a computer sees nothing and no USB device is used.  VBUS
# and the charger's own detection do not go through either, so charging goes
# on.  Kept in uci (e5-plugin-hotspotdata.settings.usb_off): it comes with
# the app's settings across an image update, and service.sh applies it again
# at boot, after the system's own USB role.  The removed app turns USB back on.
#
# The system's e5-usb-watch reconnects a gadget that a computer's port does
# not see -- here, every few seconds -- so it is stopped while USB is off and
# started again with it.

R=${HOTSPOTDATA_TEST_ROOT:-}
WATCH=$R/etc/init.d/e5-usb-watch
DATA=$R/sys/class/usb_notify/usb_control/usb_data_enabled
CFG=e5-plugin-hotspotdata

log() { logger -t hotspotdata -- "$*"; }

policy() {
	local p
	for p in "$R"/sys/bus/platform/devices/*/usb_role_policy; do
		[ -f "$p" ] && { echo "$p"; return 0; }
	done
	return 1
}

watch() { [ -x "$WATCH" ] && "$WATCH" "$1" >/dev/null 2>&1; }

available() { [ -f "$DATA" ] && policy >/dev/null; }
is_off() { [ "$(cat "$DATA" 2>/dev/null)" = 0 ]; }

save() {
	[ -f "$R/etc/config/$CFG" ] || : > "$R/etc/config/$CFG"
	uci -q get "$CFG.settings" >/dev/null || uci set "$CFG.settings=settings"
	uci set "$CFG.settings.usb_off=$1"
	uci commit "$CFG"
}

reply() {
	if [ -n "$1" ]; then printf '{"ok":false,"error":"%s"}\n' "$1"; else echo '{"ok":true}'; fi
}

go_off() {
	local p
	p=$(policy) || return 1
	echo device > "$p" 2>/dev/null
	[ "$(cat "$p")" = device ] || return 1
	watch stop
	echo 0 > "$DATA" 2>/dev/null
	is_off
}

# $1: it was off -- the sink-only port back to automatic (the screen sets the
# role chosen next; a port in device mode by choice is left alone)
go_on() {
	local p
	echo 1 > "$DATA" 2>/dev/null
	is_off && return 1
	[ -n "$1" ] && p=$(policy) && [ "$(cat "$p")" = device ] && echo auto > "$p" 2>/dev/null
	watch start
	return 0
}

case "$1" in
	get)
		a=false; o=false
		available && a=true
		is_off && o=true
		printf '{"ok":true,"available":%s,"off":%s}\n' "$a" "$o"
		;;
	set)
		available || { reply 'USB 数据开关不可用（this kernel has no USB data switch）'; exit 0; }
		case "$2" in
			off)
				# (not host at the next boot either)
				[ "$(uci -q get unisoc_modem.usb.role_auto)" = 1 ] &&
					uci set unisoc_modem.usb.role_auto=0 && uci commit unisoc_modem
				if go_off; then
					save 1
					log "USB off (charge only)"
					reply
				else
					go_on 1
					reply 'USB 未能关闭（USB could not be turned off）'
				fi
				;;
			on)
				was=; is_off && was=1
				if go_on "$was"; then
					save 0
					[ -n "$was" ] && log "USB on again"
					reply
				else
					reply 'USB 未能开启（USB could not be turned on）'
				fi
				;;
			*) reply 'off or on' ;;
		esac
		;;
	apply)
		[ "$(uci -q get "$CFG.settings.usb_off")" = 1 ] || exit 0
		available || exit 0
		if go_off; then log "USB off at boot (charge only)"; else log "USB off at boot failed"; fi
		;;
	*)
		echo "usage: $0 get|set off|set on|apply" >&2
		exit 2
		;;
esac
