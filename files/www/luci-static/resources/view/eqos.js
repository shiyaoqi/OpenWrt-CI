'use strict';
'require form';
'require network';
'require uci';
'require view';

return view.extend({
	load() {
		return Promise.all([
			uci.load('eqos'),
			network.getHostHints()
		]);
	},

	render(data) {
		let m, s, o;

		m = new form.Map('eqos', _('设备限速'),
			_('按设备分配带宽，并可把设备限制为「只能访问局域网」。限速单位为 Mbit/s。'));

		s = m.section(form.NamedSection, 'config', 'eqos', _('总开关'));

		o = s.option(form.Flag, 'enabled', _('启用限速'));
		o.default = o.disabled;
		o.rmempty = false;

		o = s.option(form.Value, 'download', _('总下载带宽 (Mbit/s)'),
			_('整条线路的下行上限，所有设备共享。请填略低于运营商实际速率的数值，填太小会让全部设备一起变慢。'));
		o.datatype = 'and(uinteger,min(1))';
		o.rmempty = false;

		o = s.option(form.Value, 'upload', _('总上传带宽 (Mbit/s)'),
			_('整条线路的上行上限，所有设备共享。'));
		o.datatype = 'and(uinteger,min(1))';
		o.rmempty = false;

		s = m.section(form.TableSection, 'device', _('按设备限速'),
			_('每一行对应一台设备。IP 可从下拉框直接选（自动带出 DHCP 里的设备名），也可以手填。'));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = true;

		o = s.option(form.Flag, 'enabled', _('启用'));
		o.default = o.enabled;

		o = s.option(form.Value, 'ip', _('IP 地址'));
		o.datatype = 'ip4addr';
		for (let i of Object.entries(data[1]?.hosts))
			for (let v in i[1].ipaddrs)
				if (i[1].ipaddrs[v]) {
					const ip_addr = i[1].ipaddrs[v], ip_host = i[1].name;
					o.value(ip_addr, ip_host ? String.format('%s (%s)', ip_host, ip_addr) : ip_addr)
				}
		o.rmempty = false;

		o = s.option(form.Value, 'download', _('下载 (Mbit/s)'),
			_('该设备的下行上限。'));
		o.datatype = 'and(uinteger,min(1))';
		o.rmempty = false;

		o = s.option(form.Value, 'upload', _('上传 (Mbit/s)'),
			_('该设备的上行上限。'));
		o.datatype = 'and(uinteger,min(1))';
		o.rmempty = false;

		o = s.option(form.Flag, 'v4only', _('仅走 IPv4'),
			_('勾选后该设备无法使用 IPv6 出网，会自动回落到 IPv4 —— 这样上面的下载/上传限速才能覆盖它的全部流量（限速只对 IPv4 生效，IPv6 地址会轮换、没法按地址限速）。需能在 DHCP 里查到该设备的 MAC。'));
		o.default = o.disabled;
		o.rmempty = true;

		o = s.option(form.Flag, 'wan_block', _('仅局域网'),
			_('勾选后该设备完全无法访问互联网，但仍能访问路由器和局域网内的其它设备（例如投屏、打印、NAS）。勾选此项时「仅走 IPv4」自动失效。'));
		o.default = o.disabled;
		o.rmempty = true;

		o = s.option(form.Value, 'comment', _('备注'));

		return m.render();
	}
});
