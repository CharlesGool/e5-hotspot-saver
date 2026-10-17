#!/bin/sh
# 热点省电 (Hotspot Power Saver): USB 关闭（仅充电） for the screen's USB role
# (设置 → 高级 → USB → USB 角色).  The app's patch of settings.uc (usb-patch.uc)
# sends the role through this:
#
#   usb-off.sh get          JSON: whether the kernel has the switches, whether USB is off,
#                           and whether it does not charge either
#   usb-off.sh set off      the port a sink only, then no USB data; kept for the next boot
#   usb-off.sh set nocharge as off, and no charging either: e5-charge's block holds the
#                           charger in HiZ (it draws nothing from USB, the battery runs the
#                           device); with e5-sleep8's kernel the system then deep-sleeps
#                           plugged in too (sleep.sh)
#   usb-off.sh set on       USB data and charging back (the screen sets the role it asked for next)
#   usb-off.sh apply        at boot (service.sh): off again if it was left off
#
# e5-plugin-hotspotdata.settings.usb_off: 0 on, 1 off (charge only), 2 off (no charge).
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

# no charging (USB 关闭（不充电）): the system's charge control holds the charger off
# whatever the level (e5-charge block, e5-sleep8 and later), and is restarted to apply
# it now rather than at its next pass
CHARGE=$R/usr/libexec/e5-charge
blockable() { grep -q 'cfg block' "$CHARGE" 2>/dev/null; }
blocked() { [ "$(uci -q get e5-charge.main.block)" = 1 ]; }
charge_block() {
	blockable || return 1
	[ "$(uci -q get e5-charge.main.block || echo 0)" = "$1" ] && return 0
	uci -q get e5-charge.main >/dev/null || return 1
	uci set e5-charge.main.block="$1" && uci commit e5-charge
	[ -x "$R/etc/init.d/e5-charge" ] && "$R/etc/init.d/e5-charge" restart >/dev/null 2>&1
	return 0
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
		a=false; o=false; n=false; na=false
		available && a=true
		is_off && o=true
		is_off && blocked && n=true
		blockable && na=true
		printf '{"ok":true,"available":%s,"off":%s,"nocharge":%s,"nocharge_available":%s}\n' "$a" "$o" "$n" "$na"
		;;
	set)
		available || { reply 'USB 数据开关不可用（this kernel has no USB data switch）'; exit 0; }
		case "$2" in
			off)
				# (not host at the next boot either)
				[ "$(uci -q get unisoc_modem.usb.role_auto)" = 1 ] &&
					uci set unisoc_modem.usb.role_auto=0 && uci commit unisoc_modem
				if go_off; then
					charge_block 0
					save 1
					log "USB off (charge only)"
					reply
				else
					go_on 1
					reply 'USB 未能关闭（USB could not be turned off）'
				fi
				;;
			nocharge)
				blockable || { reply '这个系统不能停止充电（no charge control here）'; exit 0; }
				[ "$(uci -q get unisoc_modem.usb.role_auto)" = 1 ] &&
					uci set unisoc_modem.usb.role_auto=0 && uci commit unisoc_modem
				if go_off && charge_block 1; then
					save 2
					log "USB off (no charging either)"
					reply
				else
					charge_block 0
					go_on 1
					reply 'USB 未能关闭（USB could not be turned off）'
				fi
				;;
			on)
				was=; is_off && was=1
				charge_block 0
				if go_on "$was"; then
					save 0
					[ -n "$was" ] && log "USB on again"
					reply
				else
					reply 'USB 未能开启（USB could not be turned on）'
				fi
				;;
			*) reply 'off, nocharge or on' ;;
		esac
		;;
	apply)
		m=$(uci -q get "$CFG.settings.usb_off")
		case "$m" in 1|2) ;; *) exit 0 ;; esac
		available || exit 0
		if go_off; then
			if [ "$m" = 2 ] && charge_block 1; then log "USB off at boot (no charging either)"
			else log "USB off at boot (charge only)"; fi
		else
			log "USB off at boot failed"
		fi
		;;
	*)
		echo "usage: $0 get|set off|set nocharge|set on|apply" >&2
		exit 2
		;;
esac
