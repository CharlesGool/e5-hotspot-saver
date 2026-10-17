/* BEGIN e5-usboff (the hotspotdata app, /etc/e5-infoscreen/plugins/hotspotdata) */
// USB 关闭（仅充电） and 关闭（不充电） among the USB roles (设置 → 高级 → USB → USB 角色):
// the app's usb-off.sh holds the Type-C port as a sink and turns the USB data path
// off, and for 不充电 holds the charger off too (e5-charge's block, e5-sleep8 and
// later); any other role turns both back on before the screen sets that role.
// Without the app (no usb-off.sh) or without the kernel's switches the page is
// as it was.  (Before about: usb_cat is declared after system_cat, where the
// CPU page's patch goes.)
const hotspotdata_usb = '/etc/e5-infoscreen/plugins/hotspotdata/usb-off.sh';
function hotspotdata_usb_get() {
	return ctx.sh_json(`[ -f ${hotspotdata_usb} ] && sh ${hotspotdata_usb} get 2>/dev/null`);
}
function hotspotdata_usb_patch() {
	let st = hotspotdata_usb_get();
	if (!st?.ok || !st.available) return;
	const OFF = L('关闭（仅充电）','Off (charge only)');
	const NOCHARGE = L('关闭（不充电）','Off (no charging)');
	let items = usb_cat.items, set = usb_cat.set;
	usb_cat.items = function() {
		let s = hotspotdata_usb_get(), out = items();
		let off = !!s?.off, nocharge = !!s?.nocharge;
		for (let it in out) {
			if (it.id == 'usb_role' && it.type == 'choice') {
				push(it.options, {value:'off',label:OFF});
				if (s?.nocharge_available) push(it.options, {value:'nocharge',label:NOCHARGE});
				if (nocharge) {
					it.value = 'nocharge';
					it.note = L('USB 数据和充电都已关闭：插着线也不充电、由电池供电，熄屏后可以深度休眠；选择其他角色即恢复',
						'USB data and charging are off: plugged in it does not charge, the battery runs it and it can deep-sleep; pick another role to turn both back on');
				} else if (off) {
					it.value = 'off';
					it.note = L('USB 数据已关闭，只充电，电脑和 USB 设备都无法连接；选择其他角色即恢复',
						'USB data is off: charging only, no computer or USB device can connect; pick another role to turn it back on');
				}
			} else if (it.id == 'usb_role_state' && off) {
				it.value = nocharge ? NOCHARGE : OFF;
				it.busy = false;
				it.note = null;
			}
		}
		return out;
	};
	usb_cat.set = function(id, value) {
		if (id == 'usb_role' && (value == 'off' || value == 'nocharge')) {
			let r = ctx.sh_json(`sh ${hotspotdata_usb} set ${value}`);
			return r?.ok ? null : r?.error ?? 'USB off failed';
		}
		if (id == 'usb_role' || id == 'usb_host_boot') {
			let r = ctx.sh_json(`sh ${hotspotdata_usb} set on`);
			if (!r?.ok) return r?.error ?? 'USB on failed';
		}
		return set(id, value);
	};
}
hotspotdata_usb_patch();
/* END e5-usboff */
