'use strict';
'require rpc';
'require ui';
'require tools.views as views';

/*
 * WB 系统日志页：基于官方 openwrt-25.12 的 status/syslog.js，
 * 仅额外在顶部加一个「清空日志」按钮。后端是 /usr/bin/wb-clear-logs system，
 * 通过 rpcd ACL luci-app-wbclean 授权，不开放任意命令执行。
 */
const wbCallClearLogs = rpc.declare({
	object: 'file',
	method: 'exec',
	params: [ 'command', 'params' ],
	expect: { stdout: '', stderr: '' }
});

function wbAddSystemLogClear(view) {
	const originalRender = view.render;

	view.render = function(loglines) {
		const node = originalRender.call(this, loglines);
		const self = this;

		const btn = E('button', {
			'class': 'btn cbi-button-remove',
			'title': _('清空 logd 中保存的系统日志'),
			'click': function(ev) {
				ev.preventDefault();
				ui.showModal(_('清空系统日志'), [
					E('p', {}, _('确定要清空系统日志吗？内核日志不会被清除。此操作只清内存缓冲，不改配置文件。')),
					E('div', { 'class': 'button-row right' }, [
						E('button', {
							'class': 'btn cbi-button',
							'click': ui.hideModal
						}, _('取消')),
						' ',
						E('button', {
							'class': 'btn cbi-button-negative important',
							'click': function() {
								ui.hideModal();
								wbCallClearLogs('/usr/bin/wb-clear-logs', [ 'system' ])
									.then(function() {
										ui.addNotification(null, E('p', {}, _('系统日志已清空')));
										window.setTimeout(() => self.pollLog(), 300);
									})
									.catch(function(err) {
										ui.addNotification(null, E('p', {}, _('清空失败：%s').format(String(err))), 'error');
									});
							}
						}, _('清空'))
					])
				]);
			}
		}, _('清空日志'));

		const actions = E('div', { 'class': 'cbi-section-actions' }, [ btn ]);
		if (node.firstChild)
			node.insertBefore(actions, node.firstChild);
		else
			node.appendChild(actions);

		return node;
	};

	return view;
}

return wbAddSystemLogClear(views.LogreadBox(null, _('System Log')));
