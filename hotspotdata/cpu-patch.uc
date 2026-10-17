/* BEGIN e5-hotspotdata (the hotspotdata app, /etc/e5-infoscreen/plugins/hotspotdata) */
// 关闭核心 for a CPU domain, a row under its governor: a domain of one core
// OFF, one of more "keep 1, 2 or 4" -- all its cores offline but the first
// ones (cpu0, the boot CPU, always stays; a choice is offered only while two
// cores stay online).  Every change on the CPU pages goes through the app's
// cpu-off.sh, which brings offline cores online around cpu-control -- it
// reads a domain with no core online as empty, and would save it so in the
// boot profile.  Such a domain is drawn from the last whole reading.  Without
// the app (no cpu-off.sh) the pages are as they were.
const hotspotdata_cpu = '/etc/e5-infoscreen/plugins/hotspotdata/cpu-off.sh';
function hotspotdata_cpu_get() {
	return ctx.sh_json(`[ -f ${hotspotdata_cpu} ] && sh ${hotspotdata_cpu} get 2>/dev/null`);
}
function hotspotdata_cpu_set(id, value) {
	let body = replace(sprintf('%J', {id, value}), /'/g, "'\\''");
	let result = ctx.sh_json(`sh ${hotspotdata_cpu} set '${body}'`);
	return result?.ok ? null : result?.error ?? 'CPU control unavailable';
}
// "1 2 3 4 5" -> "1–5", "0 6 7" -> "0, 6–7"
function hotspotdata_cpu_list(cpus) {
	let n = map(filter(split(cpus ?? '', ' '), x => x != ''), x => +x), out = [];
	for (let i = 0; i < length(n); ) {
		let j = i;
		while (j + 1 < length(n) && n[j + 1] == n[j] + 1) j++;
		push(out, j > i ? `${n[i]}–${n[j]}` : `${n[i]}`);
		i = j + 1;
	}
	return join(', ', out);
}
// the value of a domain keeping k cores: "off", "keep1", ...
function hotspotdata_cpu_value(k) {
	return k == 0 ? 'off' : `keep${k}`;
}
// the choice keeping k cores: which stay (keeping only cpu0: the boot core)
function hotspotdata_cpu_option(h, k) {
	if (k == 0)
		return {value:'off',label:L('OFF（全部关闭）','OFF (all offline)')};
	let cpus = filter(split(h.cpus, ' '), x => x != '');
	let kept = hotspotdata_cpu_list(join(' ', slice(cpus, 0, k)));
	let boot = kept == hotspotdata_cpu_list(h.fixed) ? L('，启动核，始终保留','; the boot core, always stays') : L('','');
	return {value:hotspotdata_cpu_value(k),label:L(`保留 ${k} 个（CPU ${kept}${boot.zh}）`,`Keep ${k} (CPU ${kept}${boot.en})`)};
}
function hotspotdata_cpu_tag(k) {
	return k == null ? L('','') : k == 0 ? L(' · OFF',' · OFF') : L(` · 保留 ${k} 核`,` · ${k} kept`);
}
// the 关闭核心 row of a domain, null for one with no core that can go
function hotspotdata_cpu_row(pid, h, k) {
	if (!length(h.choices ?? [])) return null;
	let off = k != null;
	let options = [{value:'on',label:L('不关闭','None')}];
	for (let x in h.allowed ?? []) push(options, hotspotdata_cpu_option(h, x));
	let row = {id:`${pid}_cores`,type:'choice',label:L('关闭核心','Cores off'),
		value:off ? hotspotdata_cpu_value(k) : 'on',reload:true,options};
	let notes = [];
	if (off) push(notes, L(`CPU ${hotspotdata_cpu_list(h.offline)} 已关闭；重启后恢复，开启“开机应用调频与温控”则保持`,
		`CPU ${hotspotdata_cpu_list(h.offline)} offline; back after a reboot unless frequency settings persist`));
	if (length(h.choices) > length(h.allowed ?? []))
		push(notes, L('整机至少保留 2 个核心在线，部分选项不可用','Two cores must stay online: some choices are left out'));
	if (length(notes))
		row.note = L(join('；', map(notes, n => n.zh)), join('; ', map(notes, n => n.en)));
	return row;
}
function hotspotdata_cpu_patch() {
	let st = hotspotdata_cpu_get();
	if (!st?.ok) return;
	for (let c in cpu_categories) {
		let items = c.items;
		c.set = hotspotdata_cpu_set;
		if (c.id == 'cpu') {
			c.items = function() {
				let s = hotspotdata_cpu_get(), out = items();
				for (let it in out) {
					let pid = substr(it.id, 4), h = s?.policies?.[pid];
					if (it.type != 'category' || !h) continue;
					// its governor and maximum as well (the requested one; a domain with
					// no core online: the last whole reading)
					let sys = `/sys/devices/system/cpu/cpufreq/${pid}/`;
					let p = filter(s.full?.policies ?? [], x => x.id == pid)[0];
					let gov = ctx.read_trim(sys + 'scaling_governor') || p?.governor;
					let max = +(ctx.read_trim(sys + 'scaling_requested_max_freq') || ctx.read_trim(sys + 'scaling_max_freq') || p?.max || 0);
					let g = (gov ? ` · ${gov}` : '') + (max > 0 ? ` · ${max / 1000} MHz` : '');
					let tag = hotspotdata_cpu_tag(s.off?.[pid]), cpus = hotspotdata_cpu_list(h.cpus);
					it.label = L(`CPU ${cpus}${g}${tag.zh}`,`CPU ${cpus}${g}${tag.en}`);
				}
				return out;
			};
			continue;
		}
		let pid = substr(c.id, 4), h0 = st.policies?.[pid];
		if (!h0) continue;
		c.label = L(`CPU ${h0.cpus}`,`CPU ${h0.cpus}`);
		c.items = function() {
			let s = hotspotdata_cpu_get(), h = s?.policies?.[pid];
			if (!h || h.cpus == '') return items();
			let row = hotspotdata_cpu_row(pid, h, s.off?.[pid]);
			if (h.offline != h.cpus) {
				// a core online: cpu-control's page, 关闭核心 under the governor
				let out = [];
				for (let it in items()) {
					push(out, it);
					if (it.id == `${pid}_governor` && row) push(out, row);
				}
				return out;
			}
			// no core online: cpu-control reads nothing, so the last whole reading
			let p = filter(s.full?.policies ?? [], x => x.id == pid)[0];
			let out = [
				{id:'current',type:'info',label:L('实际频率','Current frequency'),value:L('OFF（核心已关闭）','OFF (cores offline)')}
			];
			if (s.off?.[pid] == null)
				push(out, {id:'cores',type:'info',label:L('离线核心','Offline cores'),value:`CPU ${hotspotdata_cpu_list(h.offline)}`,
					note:L('热点省电临时关闭，开热点或亮屏时恢复','Taken offline by Hotspot Power Saver for now')});
			if (length(p?.governors ?? []))
				push(out, {id:`${pid}_governor`,type:'choice',label:L('调速器','Governor'),value:p.governor,reload:true,
					options:map(p.governors, g => ({value:g,label:g})),note:L('核心开启后使用','Used once the cores are back')});
			if (row) push(out, row);
			return out;
		};
	}
}
hotspotdata_cpu_patch();
/* END e5-hotspotdata */
