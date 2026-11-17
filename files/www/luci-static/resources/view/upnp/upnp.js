'use strict';
/*
 * WB 中文覆盖版：状态 → 服务 → 自动端口映射（原「UPnP IGD & PCP」）
 * 上游文件：applications/luci-app-upnp/htdocs/luci-static/resources/view/upnp/upnp.js
 *
 * 只改「文案 + 分区归类」，功能与官方完全一致：
 *   - 5 秒轮询 luci.upnp.get_status 刷新当前生效的映射
 *   - 删除某条映射走 luci.upnp.delete_rule
 *   - 配置项仍读写 /etc/config/upnpd，ACL 规则表原样保留
 * 因此上游修 bug 时，本文件需要跟着同步（回退：删掉本文件即恢复官方英文/翻译版）。
 */

'require view';
'require dom';
'require poll';
'require uci';
'require rpc';
'require form';

const callUpnpGetStatus = rpc.declare({
	object: 'luci.upnp',
	method: 'get_status',
	expect: { }
});

const callUpnpDeleteRule = rpc.declare({
	object: 'luci.upnp',
	method: 'delete_rule',
	params: [ 'token' ],
	expect: { result: 'OK' }
});

function pad2(n) {
	return String(n).padStart(2, '0');
}

function fmtExpires(sec) {
	sec = sec || 0;
	if (sec <= 0)
		return '';

	const h = Math.floor(sec / 3600);
	const m = Math.floor((sec % 3600) / 60);
	const s = Math.floor(sec % 60);

	if (h > 0)
		return h + ' 小时 ' + pad2(m) + ' 分';
	if (m > 0)
		return m + ' 分 ' + pad2(s) + ' 秒';
	return s + ' 秒';
}

function handleDelRule(num, ev) {
	dom.parent(ev.currentTarget, '.tr').style.opacity = 0.5;
	ev.currentTarget.classList.add('spinning');
	ev.currentTarget.disabled = true;
	ev.currentTarget.blur();
	callUpnpDeleteRule(num);
}

return view.extend({
	load: function() {
		return Promise.all([
			callUpnpGetStatus(),
			uci.load('upnpd')
		]);
	},

	poll_status: function(nodes, data) {
		var rules = Array.isArray(data[0].rules) ? data[0].rules : [];

		var rows = rules.map(function(rule) {
			return [
				rule.host_hint || '未知设备',
				rule.intaddr,
				rule.intport,
				rule.extport,
				rule.proto,
				fmtExpires(rule.expires),
				'%h'.format(rule.descr || ''),
				E('button', {
					'class': 'btn cbi-button-remove',
					'click': L.bind(handleDelRule, this, rule.num)
				}, [ '删除' ])
			];
		});

		cbi_update_table(nodes.querySelector('#upnp_status_table'), rows,
			E('em', '当前没有生效的端口映射。'));
	},

	render: function(data) {
		let m, s, o;

		m = new form.Map('upnpd', '自动端口映射',
			'局域网里的下载工具、游戏机、部分 NAS 和苹果设备，会绕过你手动配置，直接要求路由器开放外网端口——' +
			'这就是「自动端口映射」。它省事，但也意味着任何内网设备都能申请开洞，所以默认开启「安全限制」，' +
			'只让发起请求的那台设备自己使用映射。');

		/* ---- 第一块：当前生效的映射（只读表 + 单条删除） ---- */
		s = m.section(form.GridSection, '_active_rules');

		s.render = L.bind(function(view, section_id) {
			var table = E('table', { 'class': 'table cbi-section-table', 'id': 'upnp_status_table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, '设备'),
					E('th', { 'class': 'th' }, '内网地址'),
					E('th', { 'class': 'th' }, '内网端口'),
					E('th', { 'class': 'th' }, '外网端口'),
					E('th', { 'class': 'th' }, '协议'),
					E('th', { 'class': 'th' }, '剩余有效'),
					E('th', { 'class': 'th' }, '说明'),
					E('th', { 'class': 'th cbi-section-actions' }, '')
				])
			]);

			var rules = Array.isArray(data[0].rules) ? data[0].rules : [];

			var rows = rules.map(function(rule) {
				return [
					rule.host_hint || '未知设备',
					rule.intaddr,
					rule.intport,
					rule.extport,
					rule.proto,
					fmtExpires(rule.expires),
					'%h'.format(rule.descr || ''),
					E('button', {
						'class': 'btn cbi-button-remove',
						'click': L.bind(handleDelRule, this, rule.num)
					}, [ '删除' ])
				];
			});

			cbi_update_table(table, rows, E('em', '当前没有生效的端口映射。'));

			return E('div', { 'class': 'cbi-section cbi-tblsection' }, [
				E('h3', '当前生效的映射'),
				E('p', { 'class': 'cbi-section-descr' },
					'这些是设备自己申请、路由器已经放行的端口，到期会自动消失，也可以在这里手动删除。'),
				table
			]);
		}, o, this);

		/* ---- 第二块：服务开关，按「基本 / 安全 / 高级」分类 ---- */
		s = m.section(form.NamedSection, 'config', 'upnpd', '服务设置');
		s.addremove = false;
		s.tab('basic', '基本设置');
		s.tab('security', '安全限制');
		s.tab('advanced', '高级参数');

		o = s.taboption('basic', form.Flag, 'enabled', '启动自动端口映射',
			'总开关。关闭后下面两个协议都不工作，所有自动开端口请求会被拒绝。');
		o.rmempty = false;

		o = s.taboption('basic', form.Flag, 'enable_upnp', 'UPnP 自动开端口（通用）',
			'Windows、迅雷/BT 下载工具、Xbox/PS 游戏机用这一套，兼容性最好。');
		o.default = '1';

		o = s.taboption('basic', form.Flag, 'enable_natpmp', 'PCP / NAT-PMP 自动开端口（苹果设备）',
			'Mac、iPhone、AirPort 路由器和部分 NAS 用它，比 UPnP 简单，苹果设备优先走这个。');
		o.default = '1';

		o = s.taboption('basic', form.Flag, 'igdv1', 'UPnP 兼容模式（仅 IPv4）',
			'把自己伪装成老式 UPnP 网关。只有设备搜不到路由器、或老设备连不上时才需要打开。');
		o.default = '1';
		o.rmempty = false;
		o.depends('enable_upnp', '1');

		o = s.taboption('basic', form.Value, 'download', '上报下载带宽（KB/s）',
			'只是告诉设备「这条线有多快」，不影响实际限速。');
		o.depends('enable_upnp', '1');

		o = s.taboption('basic', form.Value, 'upload', '上报上传带宽（KB/s）',
			'同上，仅作上报，不做限速。');
		o.depends('enable_upnp', '1');

		/* --- 安全限制：真正决定「谁能用这些孔」的地方 --- */
		o = s.taboption('security', form.Flag, 'secure_mode', '只允许发起请求的设备使用该映射',
			'默认开启，建议保持。关掉后同网段任何设备都能蹭用别人开好的外网端口，' +
			'等于把内网设备的服务暴露给整个局域网。');
		o.default = '1';
		o.depends('enable_upnp', '1');

		o = s.taboption('security', form.Flag, 'log_output', '输出调试日志到系统日志',
			'排查「设备说映射成功但连不上」时临时打开，平时关掉，否则系统日志会被刷屏。');

		/* --- 高级参数：一般不用动 --- */
		s.taboption('advanced', form.Flag, 'use_stun', '用 STUN 探测公网地址',
			'只有上游是「完全锥形 NAT」、需要准确上报公网 IP 时才开。');

		o = s.taboption('advanced', form.Value, 'stun_host', 'STUN 服务器');
		o.depends('use_stun', '1');
		o.datatype = 'host';

		o = s.taboption('advanced', form.Value, 'stun_port', 'STUN 端口');
		o.depends('use_stun', '1');
		o.datatype = 'port';
		o.placeholder = '3478';

		s.taboption('advanced', form.Flag, 'force_forwarding', '强制转发',
			'即使检测到上级网络也是 NAT，仍然强行建立映射。多一层 NAT 时通常无效。');

		o = s.taboption('advanced', form.Value, 'notify_interval', '广播间隔（秒）',
			'向局域网广播「我在」的频率，默认 900 秒，改小只会增加无关流量。');
		o.datatype = 'uinteger';
		o.placeholder = '900';
		o.depends('enable_upnp', '1');

		o = s.taboption('advanced', form.Value, 'port', '服务端口（SOAP/HTTP）',
			'留给设备访问本服务的端口，默认 5000，不是被映射的业务端口。');
		o.datatype = 'port';
		o.placeholder = '5000';
		o.depends('enable_upnp', '1');

		o = s.taboption('advanced', form.Value, 'presentation_url', '管理页面地址（展示用）',
			'设备点「打开路由器页面」时跳转的地址，填不填都不影响映射。');
		o.placeholder = 'http://192.168.68.1/';
		o.depends('enable_upnp', '1');

		o = s.taboption('advanced', form.Value, 'uuid', '设备 UUID');
		o.depends('enable_upnp', '1');

		o = s.taboption('advanced', form.Value, 'model_number', '上报型号');
		o.depends('enable_upnp', '1');

		o = s.taboption('advanced', form.Value, 'serial_number', '上报序列号');
		o.depends('enable_upnp', '1');

		o = s.taboption('advanced', form.Flag, 'system_uptime', '上报系统运行时间',
			'默认上报整台路由器的运行时间，关闭后只报本服务的运行时间。');
		o.default = '1';
		o.depends('enable_upnp', '1');

		o = s.taboption('advanced', form.Value, 'upnp_lease_file', '映射记录文件');
		o.placeholder = '/var/run/miniupnpd.leases';

		/* ---- 第三块：白名单 / 黑名单 ---- */
		s = m.section(form.GridSection, 'perm_rule', '允许与禁止名单',
			'规定哪些内网地址、哪些端口可以被自动映射。规则从上往下匹配，先命中先生效；' +
			'IPv6 不受这张表限制。默认已有一条「允许 1024 以上端口」和一条「其余全部拒绝」。');
		s.sortable = true;
		s.anonymous = true;
		s.addremove = true;

		s.option(form.Value, 'comment', '说明');

		o = s.option(form.Value, 'int_addr', '客户端地址');
		o.datatype = 'ip4addr';
		o.placeholder = '0.0.0.0/0';

		o = s.option(form.Value, 'int_ports', '客户端端口');
		o.datatype = 'portrange';
		o.placeholder = '1-65535';

		o = s.option(form.Value, 'ext_ports', '外网端口');
		o.datatype = 'portrange';
		o.placeholder = '1-65535';

		o = s.option(form.ListValue, 'action', '动作');
		o.value('allow', '允许');
		o.value('deny', '拒绝');

		return m.render().then(L.bind(function(m, nodes) {
			poll.add(L.bind(function() {
				return Promise.all([
					callUpnpGetStatus()
				]).then(L.bind(this.poll_status, this, nodes));
			}, this), 5);
			return nodes;
		}, this, m));
	}
});
