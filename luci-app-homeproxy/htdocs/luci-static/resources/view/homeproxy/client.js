/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2022-2025 ImmortalWrt.org
 */

'use strict';
'require dom';
'require form';
'require network';
'require poll';
'require rpc';
'require uci';
'require ui';
'require validation';
'require view';

'require homeproxy as hp';
'require tools.firewall as fwtool';
'require tools.widgets as widgets';

/* HP_PICKER_BEGIN —— 订阅组卡片选择器 + 节点双栏选择器（左边点击加入，右边点击移除） */
const HP_PICKER_CSS = `
.hp-tr, .hp-groups { --hp-accent: var(--primary-color-high, #3d9a3d); max-width: 100%; box-sizing: border-box; color: var(--text-color-high, inherit); background: transparent; }
.hp-tr { border: 1px solid var(--border-color-medium, rgba(128,128,128,.35)); border-radius: 8px; padding: 10px; background: transparent; }
.hp-head { display:flex; justify-content:space-between; align-items:center; gap:8px; margin-bottom:8px; flex-wrap:wrap; }
.hp-sum { font-weight:600; color:inherit; }
.hp-sum b { color:var(--hp-accent); font-size:1.15em; }
.hp-body { display:grid; grid-template-columns:repeat(2, minmax(0, 1fr)); gap:10px; }
.hp-pane { border:1px solid var(--border-color-medium, rgba(128,128,128,.3)); border-radius:6px; display:flex; flex-direction:column; min-width:0; overflow:hidden; background:transparent; }
.hp-pane-title { padding:6px 10px; font-weight:600; background:transparent; color:inherit; display:flex; justify-content:space-between; border-bottom:1px solid var(--border-color-medium, rgba(128,128,128,.25)); }
.hp-pane-title span { font-weight:400; color:inherit; }
.hp-tools { display:flex; gap:6px; padding:6px 8px; }
.hp-tools input, .hp-tools select { flex:1 1 0; min-width:0; height:30px; margin:0 !important; box-sizing:border-box; }
.hp-list { height:270px; overflow-y:auto; background:transparent; }
.hp-row { display:flex; align-items:center; gap:6px; padding:5px 10px; cursor:pointer; border-top:1px solid var(--border-color-low, rgba(128,128,128,.12)); color:inherit; background:transparent; }
.hp-row:hover { outline:1px solid var(--border-color-medium, rgba(128,128,128,.4)); outline-offset:-1px; }
.hp-name { flex:1 1 auto; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; color:inherit; }
.hp-badge { flex:none; font-size:11px; line-height:16px; padding:0 7px; border-radius:9px; border:1px solid var(--border-color-medium, rgba(128,128,128,.35)); color:inherit; background:transparent; white-space:nowrap; }
.hp-type, .hp-grp { background:transparent; color:inherit; }
.hp-act { flex:none; width:22px; text-align:center; font-weight:700; font-size:16px; color:var(--hp-accent); }
.hp-sel .hp-act { color:var(--primary-color-high, #d9534f); }
.hp-sel { border-left:2px solid var(--primary-color-high, #3d9a3d); }
.hp-foot { padding:6px 8px; border-top:1px solid var(--border-color-medium, rgba(128,128,128,.25)); display:flex; gap:6px; justify-content:flex-end; }
.hp-btn { cursor:pointer; padding:3px 12px; line-height:22px; border-radius:4px; border:1px solid var(--border-color-medium, rgba(128,128,128,.5)); background:transparent; color:inherit; }
.hp-btn:hover:not([disabled]) { border-color:var(--primary-color-high, #3d9a3d); }
.hp-btn[disabled] { opacity:.85; cursor:default; }
.hp-btn.hp-primary { border-color:var(--primary-color-high, #3d9a3d); color:inherit; background:transparent; font-weight:650; }
.hp-btn.hp-primary:hover:not([disabled]) { outline:1px solid var(--primary-color-high, #3d9a3d); }
.hp-empty, .hp-more { padding:16px 10px; text-align:center; color:inherit; background:transparent; }
.hp-more { font-size:12px; padding:8px; }
.hp-groups { display:flex; flex-wrap:wrap; gap:10px; }
.hp-card { position:relative; flex:0 1 270px; min-width:200px; box-sizing:border-box; padding:8px 12px 8px 38px; border:1px solid var(--border-color-medium, rgba(128,128,128,.35)); border-radius:8px; cursor:pointer; user-select:none; color:inherit; background:transparent; }
.hp-card:hover { border-color:var(--hp-accent); }
.hp-card::before { content:''; position:absolute; left:11px; top:50%; margin-top:-9px; width:14px; height:14px; border:1px solid var(--border-color-medium, rgba(128,128,128,.6)); border-radius:4px; }
.hp-card.on { border:2px solid var(--hp-accent); padding:7px 11px 7px 37px; background:transparent; color:inherit; }
.hp-card.on::before { content:'✓'; border-color:var(--hp-accent); color:var(--hp-accent); font-size:12px; line-height:14px; text-align:center; font-weight:700; background:transparent; }
.hp-card-title { font-weight:600; color:inherit; }
.hp-card-sub { font-size:12px; color:inherit; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.hp-eff { flex-basis:100%; box-sizing:border-box; margin:8px 0 0; padding:6px 10px; border-radius:6px; border:1px solid var(--border-color-medium, rgba(128,128,128,.3)); background:transparent; color:inherit; font-weight:600; }
.hp-eff.hp-zero { border-color:var(--warning-color-high, #d9534f); background:transparent; color:inherit; }
.hp-groups-tools { flex-basis:100%; display:flex; gap:6px; align-items:center; color:inherit; }
@media (max-width: 850px) { .hp-body { grid-template-columns:minmax(0, 1fr); } }
`;

/* 「实际参与测速」实时统计：订阅组/取用数量/单独节点任何一项变化都会刷新 */
const hpSummaries = [];
function hpSummaryUpdate() {
	for (let i = hpSummaries.length - 1; i >= 0; i--) {
		const it = hpSummaries[i];
		if (!it.el.isConnected) {
			if (it.seen) hpSummaries.splice(i, 1);
			continue;
		}
		it.seen = true;
		let r = null;
		try { r = it.fn(); } catch (e) { r = null; }
		if (r) {
			it.el.textContent = r.text;
			it.el.classList.toggle('hp-zero', !!r.zero);
		}
	}
}
function hpSummaryRegister(el, fn) {
	if (!hpSummaries.length)
		document.addEventListener('widget-change', () => hpSummaryUpdate());
	hpSummaries.push({ el: el, fn: fn, seen: false });
	setTimeout(hpSummaryUpdate, 80);
	setTimeout(hpSummaryUpdate, 600);
}

function hpPickerInjectCss() {
	let style = document.getElementById('hp-picker-css');
	if (!style) { style = E('style', { 'id': 'hp-picker-css' }); document.head.appendChild(style); }
	style.textContent = HP_PICKER_CSS;
}

/* 订阅组：点卡片即选中/取消 */
const UIGroupPicker = ui.AbstractElement.extend({
	__init__(value, choices, options) {
		this.options = options || {};
		this.choices = choices || {};
		this.meta = this.options.meta || {};
		this.order = Object.keys(this.choices);
		this.selected = L.toArray(value).filter((v) => Object.prototype.hasOwnProperty.call(this.choices, v));
	},
	selectedList() {
		if (!Array.isArray(this.selected)) this.selected = [];
		return this.selected;
	},
	getValue() {
		const selected = this.selectedList();
		return (this.order || []).filter((id) => selected.indexOf(id) >= 0);
	},
	setValue(value) {
		this.selected = L.toArray(value).filter((v) => Object.prototype.hasOwnProperty.call(this.choices || {}, v));
		this.refresh();
	},
	notify() {
		if (!this.node) return;
		this.node.setAttribute('data-changed', 'true');
		this.node.dispatchEvent(new CustomEvent('widget-change', { bubbles: true }));
	},
	toggle(id) {
		const selected = this.selectedList();
		const index = selected.indexOf(id);
		if (index >= 0) selected.splice(index, 1); else selected.push(id);
		this.refresh();
		this.notify();
	},
	refresh() {
		if (!this.cards) return;
		const selected = this.selectedList();
		this.cards.forEach((el, id) => el.classList.toggle('on', selected.indexOf(id) >= 0));
	},
	render() {
		hpPickerInjectCss();
		this.choices = this.choices || {};
		this.meta = this.meta || {};
		this.order = this.order || Object.keys(this.choices);
		this.cards = new Map();
		const frame = E('div', { 'class': 'hp-groups', 'id': this.options?.id });

		if (!this.order.length) {
			frame.appendChild(E('div', { 'class': 'hp-empty' }, '还没有订阅节点组，请先到「节点设置」添加订阅并更新。'));
		} else {
			frame.appendChild(E('div', { 'class': 'hp-groups-tools' }, [
				E('button', { 'type': 'button', 'class': 'hp-btn', 'click': () => {
					this.selected = (this.order || []).slice(); this.refresh(); this.notify();
				} }, '全选'),
				E('button', { 'type': 'button', 'class': 'hp-btn', 'click': () => {
					this.selected = []; this.refresh(); this.notify();
				} }, '全不选'),
				E('span', { 'style': 'font-size:12px' }, '点一下卡片即选中 / 取消')
			]));
			this.order.forEach((id) => {
				const m = this.meta[id] || { title: this.choices[id] || id, count: 0, sample: '' };
				const card = E('div', { 'class': 'hp-card', 'title': m.sample || '', 'click': () => this.toggle(id) }, [
					E('div', { 'class': 'hp-card-title' }, m.title || this.choices[id] || id),
					E('div', { 'class': 'hp-card-sub' }, '%d 个节点%s'.format(Number(m.count) || 0, m.sample ? '　例：' + m.sample : ''))
				]);
				this.cards.set(id, card);
				frame.appendChild(card);
			});
		}

		if (this.options?.effective) {
			const eff = E('div', { 'class': 'hp-eff' });
			frame.appendChild(eff);
			hpSummaryRegister(eff, this.options.effective);
		}

		this.node = frame;
		dom.bindClassInstance(frame, this);
		this.refresh();
		return frame;
	}
});

/* 单个节点：左边「可选」，右边「已选」，点一下加入/移除，带搜索和订阅组筛选 */
const UINodePicker = ui.AbstractElement.extend({
	MAX_ROWS: 120,

	__init__(value, choices, options) {
		this.options = options || {};
		this.choices = choices || {};
		this.meta = this.options.meta || {};
		this.order = Object.keys(this.choices);
		this.selected = L.toArray(value).filter((v) => Object.prototype.hasOwnProperty.call(this.choices, v));
		this.lq = '';
		this.rq = '';
		this.gf = '';
	},
	selectedList() {
		if (!Array.isArray(this.selected)) this.selected = [];
		return this.selected;
	},
	getValue() {
		const selected = this.selectedList();
		return (this.order || []).filter((id) => selected.indexOf(id) >= 0);
	},
	setValue(value) {
		this.selected = L.toArray(value).filter((v) => Object.prototype.hasOwnProperty.call(this.choices || {}, v));
		this.refresh();
	},
	notify() {
		if (!this.node) return;
		this.node.setAttribute('data-changed', 'true');
		this.node.dispatchEvent(new CustomEvent('widget-change', { bubbles: true }));
	},
	info(id) {
		const m = (this.meta || {})[id];
		return m ? m : { type: '', group: '', name: (this.choices || {})[id] || id };
	},
	match(id, q) {
		if (!q) return true;
		const m = this.info(id);
		return (String(m.name || '') + ' ' + String(m.type || '') + ' ' + String(m.group || '')).toLowerCase().indexOf(q) >= 0;
	},
	add(id) {
		const selected = this.selectedList();
		if (selected.indexOf(id) < 0) selected.push(id);
		this.refresh(); this.notify();
	},
	remove(id) {
		const selected = this.selectedList();
		const index = selected.indexOf(id);
		if (index >= 0) selected.splice(index, 1);
		this.refresh(); this.notify();
	},
	row(id, isSel) {
		const m = this.info(id);
		const kids = [];
		if (m.type) kids.push(E('span', { 'class': 'hp-badge hp-type' }, m.type));
		if (m.group) kids.push(E('span', { 'class': 'hp-badge hp-grp' }, m.group));
		kids.push(E('span', { 'class': 'hp-name' }, m.name || id));
		kids.push(E('span', { 'class': 'hp-act' }, isSel ? '×' : '＋'));
		return E('div', {
			'class': 'hp-row' + (isSel ? ' hp-sel' : ''),
			'title': '[%s] %s %s'.format(m.type || '', m.group || '', m.name || id),
			'click': () => (isSel ? this.remove(id) : this.add(id))
		}, kids);
	},
	fill(listEl, ids, emptyText) {
		const top = listEl.scrollTop;
		while (listEl.firstChild) listEl.removeChild(listEl.firstChild);
		if (!ids.length) {
			listEl.appendChild(E('div', { 'class': 'hp-empty' }, emptyText));
			return;
		}
		const isSel = (listEl === this.rList);
		ids.slice(0, this.MAX_ROWS).forEach((id) => listEl.appendChild(this.row(id, isSel)));
		if (ids.length > this.MAX_ROWS)
			listEl.appendChild(E('div', { 'class': 'hp-more' },
				'还有 %d 个没显示，请在上面搜索或选订阅组缩小范围'.format(ids.length - this.MAX_ROWS)));
		listEl.scrollTop = top;
	},
	refresh() {
		if (!this.node) return;
		const selected = this.selectedList();
		const order = this.order || [];
		const left = order.filter((id) =>
			selected.indexOf(id) < 0 && this.match(id, this.lq) && (!this.gf || this.info(id).group === this.gf));
		const right = order.filter((id) => selected.indexOf(id) >= 0 && this.match(id, this.rq));

		this.leftIds = left;
		this.sumEl.textContent = '';
		this.sumEl.appendChild(document.createTextNode('已选 '));
		this.sumEl.appendChild(E('b', {}, String(selected.length)));
		this.sumEl.appendChild(document.createTextNode(' 个单独挑选的节点（共 %d 个）'.format(order.length)));

		this.lCount.textContent = '%d 个'.format(left.length);
		this.rCount.textContent = '%d 个'.format(selected.length);
		this.fill(this.lList, left, order.length ? '没有可加入的节点（已全部选中，或被搜索条件过滤）' : '还没有任何节点');
		this.fill(this.rList, right, selected.length ? '没有匹配的已选节点' : '还没有选节点——在左边点一下就加入');

		this.addAllBtn.textContent = '全部加入（%d）'.format(left.length);
		this.addAllBtn.disabled = !left.length;
		this.clearBtn.disabled = !selected.length;
	},
	render() {
		hpPickerInjectCss();
		this.choices = this.choices || {};
		this.meta = this.meta || {};
		this.order = this.order || Object.keys(this.choices);
		this.lList = E('div', { 'class': 'hp-list' });
		this.rList = E('div', { 'class': 'hp-list' });
		this.lCount = E('span');
		this.rCount = E('span');
		this.sumEl = E('div', { 'class': 'hp-sum' });
		this.effEl = E('div', { 'class': 'hp-eff', 'style': this.options?.effective ? '' : 'display:none' });
		if (this.options?.effective) hpSummaryRegister(this.effEl, this.options.effective);

		const groups = [];
		this.order.forEach((id) => {
			const g = this.info(id).group;
			if (g && groups.indexOf(g) < 0) groups.push(g);
		});

		const lSearch = E('input', { 'type': 'search', 'placeholder': '搜索节点名 / 类型 / 订阅组…', 'autocomplete': 'off' });
		lSearch.addEventListener('input', () => { this.lq = lSearch.value.trim().toLowerCase(); this.refresh(); });
		lSearch.addEventListener('keydown', (ev) => {
			if (ev.key === 'Enter') {
				ev.preventDefault();
				if (this.leftIds && this.leftIds.length) this.add(this.leftIds[0]);
			}
		});
		const lTools = [lSearch];
		if (groups.length > 1) {
			const sel = E('select', {}, [E('option', { 'value': '' }, '全部分组')].concat(
				groups.map((g) => E('option', { 'value': g }, g))));
			sel.addEventListener('change', () => { this.gf = sel.value; this.refresh(); });
			lTools.push(sel);
		}

		const rSearch = E('input', { 'type': 'search', 'placeholder': '在已选中搜索…', 'autocomplete': 'off' });
		rSearch.addEventListener('input', () => { this.rq = rSearch.value.trim().toLowerCase(); this.refresh(); });

		this.addAllBtn = E('button', { 'type': 'button', 'class': 'hp-btn hp-primary', 'click': () => {
			const selected = this.selectedList();
			(this.leftIds || []).forEach((id) => { if (selected.indexOf(id) < 0) selected.push(id); });
			this.refresh(); this.notify();
		} }, '全部加入');
		this.clearBtn = E('button', { 'type': 'button', 'class': 'hp-btn', 'click': () => {
			this.selected = []; this.refresh(); this.notify();
		} }, '清空已选');

		const frame = E('div', { 'class': 'hp-tr', 'id': this.options?.id }, [
			E('div', { 'class': 'hp-head' }, [
				this.sumEl,
				E('span', { 'style': 'font-size:12px' }, '左边点一下＝加入，右边点一下＝移除；保存并应用后生效')
			]),
			this.effEl,
			E('div', { 'class': 'hp-body' }, [
				E('div', { 'class': 'hp-pane' }, [
					E('div', { 'class': 'hp-pane-title' }, [E('div', '可选节点'), this.lCount]),
					E('div', { 'class': 'hp-tools' }, lTools),
					this.lList,
					E('div', { 'class': 'hp-foot' }, [this.addAllBtn])
				]),
				E('div', { 'class': 'hp-pane' }, [
					E('div', { 'class': 'hp-pane-title' }, [E('div', '已选节点'), this.rCount]),
					E('div', { 'class': 'hp-tools' }, [rSearch]),
					this.rList,
					E('div', { 'class': 'hp-foot' }, [this.clearBtn])
				])
			])
		]);

		this.node = frame;
		dom.bindClassInstance(frame, this);
		this.refresh();
		return frame;
	}
});

/* HP_PICKER_END */


const callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: ['name'],
	expect: { '': {} }
});

const callReadDomainList = rpc.declare({
	object: 'luci.homeproxy',
	method: 'acllist_read',
	params: ['type'],
	expect: { '': {} }
});

const callWriteDomainList = rpc.declare({
	object: 'luci.homeproxy',
	method: 'acllist_write',
	params: ['type', 'content'],
	expect: { '': {} }
});

const callCurrentNode = rpc.declare({
	object: 'luci.homeproxy',
	method: 'current_node_get',
	expect: { '': {} }
});

const callTailscaleStatus = rpc.declare({
	object: 'luci.homeproxy',
	method: 'tailscale_status',
	expect: { '': {} }
});

function renderTailscaleStatus(status) {
	if (status?.state === 'Running')
		return E('span', {}, [
			E('span', { 'class': 'label success' }, _('Connected')),
			status.network ? E('span', {}, ' (' + status.network + ')') : ''
		]);
	if (status?.state === 'disabled')
		return E('span', {}, _('Save and apply to enable Tailscale.'));
	if (status?.auth_url) {
		try {
			const url = new URL(status.auth_url);
			if (['http:', 'https:'].includes(url.protocol) && url.hostname && !url.username && !url.password)
				return E('a', { 'class': 'cbi-button cbi-button-action', href: url.href,
					target: '_blank', rel: 'noopener noreferrer' }, _('Log in to Tailscale'));
		} catch (e) { }
	}
	if (status?.state === 'NeedsMachineAuth')
		return E('span', {}, _('Approve this device in the Tailscale admin console.'));
	if (status?.state === 'NeedsLogin' || status?.state === 'NoState')
		return E('span', {}, _('Waiting for the login link. Check the control server connection if it does not appear.'));
	return E('span', {}, _('Tailscale status is unavailable. Save and apply, then check that the client is running.'));
}

function getServiceStatus() {
	return L.resolveDefault(callServiceList('homeproxy'), {}).then((res) => {
		let isRunning = false;
		try {
			isRunning = res['homeproxy']['instances']['sing-box-c']['running'];
		} catch (e) { }
		return isRunning;
	});
}

/*
 * The measured delay is coloured by latency so a bad node stands out:
 * below 800 ms green, below 1500 ms amber, everything above red. The tones
 * are the 600 shades of the palette, they stay legible on light and dark
 * themes alike.
 */
function renderDelay(delay) {
	const ms = parseInt(String(delay || '').replace(/[^0-9]/g, ''), 10);

	if (isNaN(ms))
		return '';

	const color = (ms >= 1500) ? '#dc2626' : (ms >= 800) ? '#d97706' : '#16a34a';

	return ' (<span style="color:%s;font-weight:bold">%h</span>)'.format(color, delay);
}

function renderStatus(isRunning, version, node) {
	let spanTemp = '<em><span style="color:%s"><strong>%s (sing-box v%s) %s</strong></span></em>';
	let renderHTML;
	if (isRunning)
		renderHTML = spanTemp.format('green', _('HomeProxy'), version, _('RUNNING'));
	else
		renderHTML = spanTemp.format('red', _('HomeProxy'), version, _('NOT RUNNING'));

	if (!isRunning || !node || !node.active)
		return renderHTML;

	renderHTML += '<br/><span style="font-size:0.9em">%s: <strong>%h</strong>%s</span>'
		.format(_('Current node'), node.active.label, renderDelay(node.delay));

	return renderHTML;
}

let stubValidator = {
	factory: validation,
	apply(type, value, args) {
		if (value != null)
			this.value = value;

		return validation.types[type].apply(this, args);
	},
	assert(condition) {
		return !!condition;
	}
};

return view.extend({
	load() {
		return Promise.all([
			uci.load('homeproxy'),
			hp.getBuiltinFeatures(),
			network.getHostHints()
		]);
	},

	render(data) {
		let m, s, o, ss, so;

		let features = data[1],
		    hosts = data[2]?.hosts;

		function validateDnsFallback(section_id, value) {
			if (!value)
				return true;

			let ipv6_support = this.section.formvalue(section_id, 'ipv6_support');
			try {
				let url = new URL(value.replace(/^.*:\/\//, 'http://'));
				if (stubValidator.apply('hostname', url.hostname))
					return true;
				else if (stubValidator.apply('ip4addr', url.hostname))
					return true;
				else if ((ipv6_support === '1') && stubValidator.apply('ip6addr', url.hostname.match(/^\[(.+)\]$/)?.[1]))
					return true;
				else
					return _('Expecting: %s').format(_('valid DNS server address'));
			} catch (e) {}

			if (!stubValidator.apply((ipv6_support === '1') ? 'ipaddr' : 'ip4addr', value))
				return _('Expecting: %s').format(_('valid DNS server address'));

			return true;
		}

		/* Cache all configured proxy nodes, they will be called multiple times */
		let proxy_nodes = {};
		uci.sections(data[0], 'node', (res) => {
			let nodeaddr = ((res.type === 'direct') ? res.override_address : res.address) || '',
			    nodeport = ((res.type === 'direct') ? res.override_port : res.port) || '';

			proxy_nodes[res['.name']] =
				String.format('[%s] %s', res.type, res.label || ((stubValidator.apply('ip6addr', nodeaddr) ?
					String.format('[%s]', nodeaddr) : nodeaddr) + ':' + nodeport));
		});

		/* 订阅节点组：按 grouphash 归类，标签显示订阅域名 + 节点数；无 grouphash 的归为「手动添加节点」 */
		let group_labels = {}, group_counts = {}, group_sample = {}, group_order = [];
		uci.sections(data[0], 'node', (res) => {
			let g = res.grouphash || '';
			if (!g) return;
			if (!group_counts[g]) {
				group_order.push(g);
				group_sample[g] = res.label || res.address || '';
			}
			group_counts[g] = (group_counts[g] || 0) + 1;
		});
		group_order.forEach((g, idx) => {
			group_labels[g] = String.format('订阅组%d [%s] — %d 个节点（例：%s）',
				idx + 1, g.substring(0, 6), group_counts[g], String(group_sample[g]).substring(0, 20));
		});
		let has_manual_nodes = false;
		uci.sections(data[0], 'node', (res) => { if (!res.grouphash) has_manual_nodes = true; });

		/* 节点勾选框列表：标签前面带上所属订阅组，方便按订阅挑选 */
		let node_group_tag = {};
		group_order.forEach((g, idx) => { node_group_tag[g] = '订阅组' + (idx + 1); });
		let list_nodes = {};
		uci.sections(data[0], 'node', (res) => {
			list_nodes[res['.name']] = String.format('[%s] %s',
				res.grouphash ? (node_group_tag[res.grouphash] || '订阅') : '手动', proxy_nodes[res['.name']]);
		});

		/* 节点附加信息：类型 / 所属订阅组 / 名称，供双栏选择器显示 */
		let node_meta = {};
		uci.sections(data[0], 'node', (res) => {
			let a = res.address || '', p = res.port || '';
			node_meta[res['.name']] = {
				type: res.type || '',
				group: res.grouphash ? (node_group_tag[res.grouphash] || '订阅') : '手动',
				name: res.label || ((stubValidator.apply('ip6addr', a) ? String.format('[%s]', a) : a) + ':' + p)
			};
		});

		/* 订阅组卡片信息 */
		let group_meta = {};
		group_order.forEach((g, idx) => {
			group_meta[g] = {
				title: '订阅组' + (idx + 1) + '（' + g.substring(0, 6) + '）',
				count: group_counts[g],
				sample: String(group_sample[g]).substring(0, 24)
			};
		});
		let manual_count = 0;
		uci.sections(data[0], 'node', (res) => { if (!res.grouphash) manual_count++; });
		group_meta['__manual__'] = { title: '手动添加的节点', count: manual_count, sample: '没有订阅链接的节点' };

		/* 每个订阅组的节点 id（排序后取前 N / 一半，规则与 generate_client.uc 一致） */
		let group_ids = { '__manual__': [] };
		uci.sections(data[0], 'node', (res) => {
			let g = res.grouphash || '__manual__';
			if (!group_ids[g]) group_ids[g] = [];
			group_ids[g].push(res['.name']);
		});
		for (let g in group_ids) group_ids[g].sort();

		function make_effective(base, option) {
			let kind = /_groups$/.test(option) ? '_groups$' : '_nodes$';
			let prefix = base.slice(0, base.length - option.length);
			let gName = option.replace(new RegExp(kind), '_groups'),
			    lName = option.replace(new RegExp(kind), '_group_limit'),
			    nName = option.replace(new RegExp(kind), '_nodes');
			let val = (name) => {
				let el = document.getElementById(prefix + name);
				let inst = el ? dom.findClassInstance(el) : null;
				return inst ? inst.getValue() : null;
			};
			return function() {
				let groups = L.toArray(val(gName)), nodes = L.toArray(val(nName));
				let lim = val(lName);
				lim = (lim == null) ? '' : String(lim);
				let selectedIds = [];
				groups.forEach((g) => {
					let ids = group_ids[g] || [], keep = ids.length;
					if (lim === 'half') keep = Math.floor((ids.length + 1) / 2);
					else if (parseInt(lim) > 0 && parseInt(lim) < ids.length) keep = parseInt(lim);
					ids.slice(0, keep).forEach((id) => { if (selectedIds.indexOf(id) < 0) selectedIds.push(id); });
				});
				let fromGroups = selectedIds.length, extra = 0;
				nodes.forEach((id) => { if (selectedIds.indexOf(id) < 0) { extra++; selectedIds.push(id); } });
				let limText = (lim === 'half') ? '每组取一半' : (parseInt(lim) > 0 ? '每组取 ' + lim + ' 个' : '每组取全部');
				let text;
				if (!selectedIds.length)
					text = '实际参与测速：0 个——请点上面的订阅组卡片，或在下面挑选节点';
				else if (!groups.length)
					text = '实际参与测速：共 %d 个（只有单独挑选的节点，没有选订阅组）'.format(selectedIds.length);
				else
					text = '实际参与测速：共 %d 个 ＝ 订阅组带入 %d 个（已选 %d 个组，%s）＋ 单独挑选 %d 个（与组重复的已去掉）'.format(selectedIds.length, fromGroups, groups.length, limText, extra);
				return { text: text, zero: !selectedIds.length };
			};
		}

		function add_node_values(opt) {
			for (let i in list_nodes) opt.value(i, list_nodes[i]);
			opt.renderWidget = function(section_id, option_index, cfgvalue) {
				const widget = new UINodePicker(L.toArray((cfgvalue != null) ? cfgvalue : this.default), this.transformChoices(), {
					id: this.cbid(section_id),
					meta: node_meta,
					disabled: (this.readonly != null) ? this.readonly : this.map.readonly
				});
				return widget.render();
			};
		}

		function add_limit_values(opt) {
			opt.value('', '全部节点');
			opt.value('10', '每组只取 10 个');
			opt.value('20', '每组只取 20 个');
			opt.value('50', '每组只取 50 个');
			opt.value('100', '每组只取 100 个');
			opt.value('half', '每组只取一半');
			opt.default = '';
		}

		function add_group_values(opt) {
			for (let g in group_labels) opt.value(g, group_labels[g]);
			if (has_manual_nodes) opt.value('__manual__', '手动添加的节点（无订阅）');
			opt.renderWidget = function(section_id, option_index, cfgvalue) {
				const widget = new UIGroupPicker(L.toArray((cfgvalue != null) ? cfgvalue : this.default), this.transformChoices(), {
					id: this.cbid(section_id),
					meta: group_meta,
					effective: make_effective(this.cbid(section_id), this.option),
					disabled: (this.readonly != null) ? this.readonly : this.map.readonly
				});
				return widget.render();
			};
		}

		m = new form.Map('homeproxy', _('HomeProxy'),
			_('The modern ImmortalWrt proxy platform for ARM64/AMD64.'));

		s = m.section(form.TypedSection);
		s.render = function () {
			let lastNodeFetch = 0, cachedNode = {};

			const getCurrentNode = () => {
				/* the API query spawns a process, keep it to one call per poll tick */
				if (Date.now() - lastNodeFetch < 5000)
					return Promise.resolve(cachedNode);
				lastNodeFetch = Date.now();
				return L.resolveDefault(callCurrentNode(), {}).then((res) => {
					cachedNode = res;
					return res;
				});
			};

			const paintStatus = (isRunning, node) => {
				const view = document.getElementById('service_status');

				if (view)
					view.innerHTML = renderStatus(isRunning, features.version, node);
			};

			let quickChecks = 10;

			const refreshStatus = () => {
				return L.resolveDefault(getServiceStatus(), false).then((isRunning) => {
					paintStatus(isRunning, cachedNode);

					if (!isRunning) {
						if (quickChecks > 0) {
							quickChecks--;
							setTimeout(refreshStatus, 1000);
						}
						return;
					}

					quickChecks = 10;
					return getCurrentNode().then((node) => paintStatus(isRunning, node));
				});
			};

			poll.add(refreshStatus);

			return E('div', { class: 'cbi-section', id: 'status_bar' }, [
					E('p', { id: 'service_status' }, _('Collecting data...'))
			]);
		}

		s = m.section(form.NamedSection, 'config', 'homeproxy');

		s.tab('routing', _('Routing Settings'));
		s.tab('dns', _('DNS Settings'));

		o = s.taboption('routing', form.ListValue, 'main_node', _('Main node'));
		o.value('nil', _('Disable'));
		o.value('urltest', _('URLTest'));
		for (let i in proxy_nodes)
			o.value(i, proxy_nodes[i]);
		o.default = 'nil';
		o.rmempty = false;
		o.retain = true;

		o = s.taboption('routing', form.MultiValue, 'main_urltest_groups', '自动测速订阅组',
			'点一下卡片即选中整个订阅组：该订阅的节点（按下面「订阅组取用数量」）在生成配置时自动带入。');
		add_group_values(o);
		o.depends('main_node', 'urltest');
		o.rmempty = true;
		o.retain = true;

		o = s.taboption('routing', form.ListValue, 'main_urltest_group_limit', '订阅组取用数量',
			'对上面勾选的每个订阅组生效：只取其中固定的一部分节点参与测速（稳定抽取，订阅更新后尽量不变），可以大幅减少测速请求次数。');
		add_limit_values(o);
		o.depends('main_node', 'urltest');
		o.rmempty = true;
		o.retain = true;

		o = s.taboption('routing', form.MultiValue, 'main_urltest_nodes', '单独挑选节点',
			'左边点节点＝加入，右边点 × ＝移除（可搜索、可按订阅组筛选、可一键全部加入）；可与上面的订阅组叠加。');
		add_node_values(o);
		o.depends('main_node', 'urltest');
		o.rmempty = true;
		/* keep the selection when another main node is used */
		o.retain = true;

		o = s.taboption('routing', form.Value, 'main_urltest_interval', _('Test interval'),
			_('The test interval in seconds.'));
		o.datatype = 'uinteger';
		o.placeholder = '180';
		o.depends('main_node', 'urltest');
		o.retain = true;

		o = s.taboption('routing', form.Value, 'main_urltest_tolerance', _('Test tolerance'),
			_('The test tolerance in milliseconds.'));
		o.datatype = 'uinteger';
		o.placeholder = '50';
		o.depends('main_node', 'urltest');
		o.retain = true;

		o = s.taboption('dns', form.Value, 'dns_server', _('DNS server'),
			_('Support UDP, TCP, DoH, DoQ, DoT. TCP protocol will be used if not specified.'));
		o.value('wan', _('WAN DNS (read from interface)'));
		o.value('8.8.8.8', _('Google Public DNS (8.8.8.8)'));
		o.value('1.1.1.1', _('CloudFlare Public DNS (1.1.1.1)'));
		o.value('9.9.9.9', _('Quad9 Public DNS (9.9.9.9)'));
		o.value('94.140.14.14', _('AdGuard Public DNS (94.140.14.14)'));
		o.default = '8.8.8.8';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			if (section_id && !['wan'].includes(value)) {
				if (!value)
					return _('Expecting: %s').format(_('non-empty value'));

				let ipv6_support = this.section.formvalue(section_id, 'ipv6_support');
				try {
					let url = new URL(value.replace(/^.*:\/\//, 'http://'));
					if (stubValidator.apply('hostname', url.hostname))
						return true;
					else if (stubValidator.apply('ip4addr', url.hostname))
						return true;
					else if ((ipv6_support === '1') && stubValidator.apply('ip6addr', url.hostname.match(/^\[(.+)\]$/)?.[1]))
						return true;
					else
						return _('Expecting: %s').format(_('valid DNS server address'));
				} catch(e) {}

				if (!stubValidator.apply((ipv6_support === '1') ? 'ipaddr' : 'ip4addr', value))
					return _('Expecting: %s').format(_('valid DNS server address'));
			}

			return true;
		}

		o = s.taboption('dns', form.Value, 'china_dns_server', _('China DNS server'),
			_('The dns server for resolving China domains. Support UDP, TCP, DoH, DoQ, DoT.'));
		o.value('wan', _('WAN DNS (read from interface)'));
		o.value('223.5.5.5', _('Aliyun Public DNS (223.5.5.5)'));
		o.value('119.29.29.29', _('Tencent Public DNS (119.29.29.29)'));
		o.value('117.50.10.10', _('ThreatBook Public DNS (117.50.10.10)'));
		o.value('180.184.1.1', _('TrafficRoute Public DNS (180.184.1.1)'));
		o.depends('routing_mode', 'bypass_mainland_china');
		o.default = '223.5.5.5';
		o.rmempty = false;
		o.retain = true;
		o.validate = function(section_id, value) {
			if (section_id && !['wan'].includes(value)) {
				if (!value)
					return _('Expecting: %s').format(_('non-empty value'));

				try {
					let url = new URL(value.replace(/^.*:\/\//, 'http://'));
					if (stubValidator.apply('hostname', url.hostname))
						return true;
					else if (stubValidator.apply('ip4addr', url.hostname))
						return true;
					else if (stubValidator.apply('ip6addr', url.hostname.match(/^\[(.+)\]$/)?.[1]))
						return true;
					else
						return _('Expecting: %s').format(_('valid DNS server address'));
				} catch(e) {}

				if (!stubValidator.apply('ipaddr', value))
					return _('Expecting: %s').format(_('valid DNS server address'));
			}

			return true;
		}

		o = s.taboption('dns', form.DynamicList, 'dns_server_fallback', _('DNS server (fallback)'),
			_('Additional DNS servers used together with the DNS server above. Support UDP, TCP, DoH, DoQ, DoT.'));
		o.value('https://dns.google/dns-query', _('Google Public DNS (DoH)'));
		o.value('https://cloudflare-dns.com/dns-query', _('CloudFlare Public DNS (DoH)'));
		o.value('https://dns.quad9.net/dns-query', _('Quad9 Public DNS (DoH)'));
		o.value('https://dns.adguard-dns.com/dns-query', _('AdGuard Public DNS (DoH)'));
		o.retain = true;
		o.validate = validateDnsFallback;

		o = s.taboption('dns', form.DynamicList, 'china_dns_server_fallback', _('China DNS server (fallback)'),
			_('Additional DNS servers used together with the China DNS server above. Support UDP, TCP, DoH, DoQ, DoT.'));
		o.depends('routing_mode', 'bypass_mainland_china');
		o.value('https://dns.alidns.com/dns-query', _('Aliyun Public DNS (DoH)'));
		o.value('https://doh.pub/dns-query', _('Tencent Public DNS (DoH)'));
		o.value('https://doh.360.cn/dns-query', _('360 Public DNS (DoH)'));
		o.value('https://doh-pure.onedns.net/dns-query', _('ThreatBook Public DNS (DoH)'));
		o.retain = true;
		o.validate = validateDnsFallback;

		o = s.taboption('dns', form.ListValue, 'dns_fallback_strategy', _('DNS fallback strategy'),
			_('How to query the primary and fallback DNS servers when fallback servers are configured above.'));
		o.value('sequential', _('Sequential (try in order)'));
		o.value('parallel', _('Parallel (query all at once)'));
		o.default = 'sequential';
		o.rmempty = false;

		o = s.taboption('dns', form.Value, 'dns_fallback_timeout', _('DNS fallback timeout'),
			_('Overall time budget for the whole fallback exchange, in seconds. Leave empty for default (10s).'));
		o.datatype = 'uinteger';
		o.placeholder = '10';

		o = s.taboption('routing', form.ListValue, 'routing_mode', _('Routing mode'));
		o.value('bypass_mainland_china', _('Bypass mainland China'));
		o.value('global', _('Global'));
		o.default = 'bypass_mainland_china';
		o.rmempty = false;

		o = s.taboption('routing', form.Value, 'routing_port', _('Routing ports'),
			_('Specify target ports to be proxied. Multiple ports must be separated by commas.'));
		o.value('', _('All ports'));
		o.value('common', _('Common ports only (bypass P2P traffic)'));
		o.validate = function(section_id, value) {
			if (section_id && value && value !== 'common') {

				let ports = [];
				for (let i of value.split(',')) {
					if (!stubValidator.apply('port', i) && !stubValidator.apply('portrange', i))
						return _('Expecting: %s').format(_('valid port value'));
					if (ports.includes(i))
						return _('Port %s already exists!').format(i);
					ports = ports.concat(i);
				}
			}

			return true;
		}

		o = s.taboption('routing', form.ListValue, 'proxy_mode', _('Proxy mode'));
		o.value('redirect', _('Redirect TCP'));
		if (features.hp_has_tproxy)
			o.value('redirect_tproxy', _('Redirect TCP + TProxy UDP'));
		if (features.hp_has_ip_full && features.hp_has_tun) {
			o.value('redirect_tun', _('Redirect TCP + Tun UDP'));
			o.value('tun', _('Tun TCP/UDP'));
		} else {
			o.description = _('To enable Tun support, you need to install <code>ip-full</code> and <code>kmod-tun</code>');
		}
		o.default = 'redirect_tproxy';
		o.rmempty = false;

		o = s.taboption('routing', form.ListValue, 'tcpip_stack', _('TCP/IP stack'),
			_('TCP/IP stack used by the TUN inbound.'));
		o.value('system', 'System');
		o.value('gvisor', 'gVisor');
		o.value('mixed', 'Mixed');
		o.default = 'system';
		o.rmempty = false;
		o.depends('proxy_mode', /tun/);

		o = s.taboption('routing', form.Flag, 'ipv6_support', _('IPv6 support'));
		o.default = o.enabled;
		o.rmempty = false;

		/* Application routing start */
		s.tab('app_rules', _('Routing Rules'));
		o = s.taboption('app_rules', form.SectionValue, '_app_rules', form.GridSection, 'app_rule');

		ss = o.subsection;
		ss.addremove = true;
		ss.rowcolors = true;
		ss.sortable = true;
		ss.nodescriptions = true;
		ss.modaltitle = L.bind(hp.loadModalTitle, this, _('Routing rule'), _('Add a routing rule'), data[0]);
		ss.sectiontitle = L.bind(hp.loadDefaultLabel, this, data[0]);
		ss.renderSectionAdd = L.bind(hp.renderSectionAdd, this, ss);

		so = ss.option(form.Flag, 'enabled', _('Enable'));
		so.default = so.enabled;
		so.rmempty = false;
		so.editable = true;

		so = ss.option(form.ListValue, 'source', _('Service'));
		so.value('youtube', _('YouTube'));
		so.value('tiktok', _('TikTok'));
		so.value('telegram', _('Telegram'));
		so.value('twitter', _('Twitter/X'));
		so.value('google', _('Google'));
		so.value('cloudflare', _('Cloudflare'));
		so.value('github', _('GitHub'));
		so.value('ai_noncn', _('AI Services (Non-Mainland China)'));
		so.value('custom', _('Custom'));
		so.rmempty = false;
		so.editable = true;

		so = ss.option(form.Value, 'custom_service_name', _('Service name'));
		so.placeholder = _('e.g. My Service');
		so.depends('source', 'custom');
		so.modalonly = true;
		so.retain = true;

		so = ss.option(form.ListValue, 'custom_mode', _('Custom rule type'));
		so.value('url_domain', _('Domain rule-set'));
		so.value('url_ip', _('IP rule-set'));
		so.value('url_mixed', _('Mixed rule-set (domain + IP)'));
		so.value('domains', _('Domain list'));
		so.default = 'url_domain';
		so.rmempty = false;
		so.depends('source', 'custom');
		so.modalonly = true;
		so.retain = true;

		so = ss.option(form.DynamicList, 'custom_url', _('Domain rule-set URL'));
		so.placeholder = 'https://example.com/rule-set.srs';
		so.depends({'source': 'custom', 'custom_mode': 'url_domain'});
		so.depends({'source': 'custom', 'custom_mode': 'url_mixed'});
		so.modalonly = true;
		so.retain = true;
		so.validate = function(section_id, value) {
			if (section_id && value && !/^https?:\/\/.+/.test(value))
				return _('Expecting: %s').format(_('a valid URL starting with http:// or https://'));

			return true;
		};

		so = ss.option(form.DynamicList, 'custom_url_ip', _('IP rule-set URL'));
		so.placeholder = 'https://example.com/rule-set.srs';
		so.depends({'source': 'custom', 'custom_mode': 'url_ip'});
		so.depends({'source': 'custom', 'custom_mode': 'url_mixed'});
		so.modalonly = true;
		so.retain = true;
		so.validate = function(section_id, value) {
			if (section_id && value && !/^https?:\/\/.+/.test(value))
				return _('Expecting: %s').format(_('a valid URL starting with http:// or https://'));

			return true;
		};

		so = ss.option(form.ListValue, 'custom_format', _('Rule-set format'));
		so.value('binary', _('Binary (.srs)'));
		so.value('source', _('JSON (.json)'));
		so.default = 'binary';
		so.rmempty = false;
		so.depends({'source': 'custom', 'custom_mode': 'url_domain'});
		so.depends({'source': 'custom', 'custom_mode': 'url_ip'});
		so.depends({'source': 'custom', 'custom_mode': 'url_mixed'});
		so.modalonly = true;
		so.retain = true;

		so = ss.option(form.TextValue, 'custom_domains', _('Custom domains'),
			_('One domain (or domain keyword) per line.'));
		so.rows = 5;
		so.monospace = true;
		so.depends({'source': 'custom', 'custom_mode': 'domains'});
		so.modalonly = true;
		so.retain = true;
		so.validate = function(section_id, value) {
			if (section_id && value)
				for (let i of value.split('\n')) {
					i = i.trim();
					if (i && !stubValidator.apply('hostname', i))
						return _('Expecting: %s').format(_('valid hostname'));
				}

			return true;
		};

		so = ss.option(form.ListValue, 'node', _('Node'));
		so.value('main-out', _('Same as main node'));
		so.value('urltest', _('Separate URLTest'));
		so.value('direct-out', _('Direct'));
		so.value('reject-out', _('Reject'));
		so.value('tailscale', _('[Tailscale] Tailscale'));
		for (let i in proxy_nodes)
			so.value(i, proxy_nodes[i]);
		so.default = 'main-out';
		so.rmempty = false;
		so.editable = true;

		so = ss.option(form.MultiValue, 'urltest_groups', '自动测速订阅组',
			'点一下卡片即选中整个订阅组（如 YouTube、国外AI 直接指定某订阅）：该订阅的节点参与测速，订阅更新后自动跟随。可与下面单独挑选的节点叠加。');
		add_group_values(so);
		so.depends('node', 'urltest');
		so.rmempty = true;
		so.modalonly = true;
		so.retain = true;

		so = ss.option(form.ListValue, 'urltest_group_limit', '订阅组取用数量',
			'对上面勾选的每个订阅组生效：只取其中固定的一部分节点参与测速（稳定抽取，订阅更新后尽量不变），可以大幅减少测速请求次数。');
		add_limit_values(so);
		so.depends('node', 'urltest');
		so.rmempty = true;
		so.modalonly = true;
		so.retain = true;

		so = ss.option(form.MultiValue, 'urltest_nodes', '单独挑选节点',
			'左边点节点＝加入，右边点 × ＝移除（可搜索、可按订阅组筛选、可一键全部加入）；可与上面的订阅组叠加。');
		add_node_values(so);
		so.depends('node', 'urltest');
		so.rmempty = true;
		so.modalonly = true;
		so.retain = true;

		so = ss.option(form.Value, 'urltest_interval', _('Test interval'),
			_('The test interval in seconds.'));
		so.datatype = 'uinteger';
		so.placeholder = '120';
		so.depends('node', 'urltest');
		so.modalonly = true;
		so.retain = true;

		so = ss.option(form.Value, 'urltest_tolerance', _('Test tolerance'),
			_('The test tolerance in milliseconds.'));
		so.datatype = 'uinteger';
		so.placeholder = '40';
		so.depends('node', 'urltest');
		so.modalonly = true;
		so.retain = true;

		so = ss.option(form.Flag, 'urltest_interrupt_exist_connections', _('Interrupt existing connections'));
		so.default = so.disabled;
		so.rmempty = false;
		so.depends('node', 'urltest');
		so.modalonly = true;
		so.retain = true;
		/* Application routing end */

		/* Dashboard settings start */
		s.tab('dashboard', _('Dashboard'));

		o = s.taboption('dashboard', form.Value, 'dashboard_port', _('Listen port'));
		o.default = '9096';
		o.datatype = 'port';
		o.rmempty = false;

		o = s.taboption('dashboard', form.Value, 'dashboard_secret', _('API secret'));
		o.password = true;
		o.rmempty = true;

		o = s.taboption('dashboard', form.Button, '_open_dashboard', _('Dashboard'));
		o.inputtitle = _('Open dashboard');
		o.inputstyle = 'apply';
		o.onclick = function() {
			let host = window.location.hostname,
			    port = uci.get('homeproxy', 'config', 'dashboard_port') || '9096';
			if (host.includes(':') && !host.startsWith('['))
				host = '[' + host + ']';
			window.open('http://' + host + ':' + port + '/dashboard/', '_blank', 'noopener,noreferrer');
		};
		/* Dashboard settings end */

		/* ACL settings start */
		s.tab('control', _('Access Control'));

		o = s.taboption('control', form.SectionValue, '_control', form.NamedSection, 'control', 'homeproxy');
		ss = o.subsection;

		/* Interface control start */
		ss.tab('interface', _('Interface Control'));

		so = ss.taboption('interface', widgets.DeviceSelect, 'listen_interfaces', _('Listen interfaces'),
			_('Only process traffic from specific interfaces. Leave empty for all.'));
		so.multiple = true;
		so.noaliases = true;

		so = ss.taboption('interface', widgets.DeviceSelect, 'bind_interface', _('Bind interface'),
			_('Bind outbound traffic to specific interface. Leave empty to auto detect.'));
		so.multiple = false;
		so.noaliases = true;
		/* Interface control end */

		/* LAN IP policy start */
		ss.tab('lan_ip_policy', _('LAN IP Policy'));

		so = ss.taboption('lan_ip_policy', form.ListValue, 'lan_proxy_mode', _('Proxy filter mode'));
		so.value('disabled', _('Disable'));
		so.value('listed_only', _('Proxy listed only'));
		so.value('except_listed', _('Proxy all except listed'));
		so.default = 'disabled';
		so.rmempty = false;

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_direct_ipv4_ips', _('Direct IPv4 IP-s'), null, 'ipv4', hosts, true);
		so.depends('lan_proxy_mode', 'except_listed');

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_direct_ipv6_ips', _('Direct IPv6 IP-s'), null, 'ipv6', hosts, true);
		so.depends({'lan_proxy_mode': 'except_listed', 'homeproxy.config.ipv6_support': '1'});

		so = fwtool.addMACOption(ss, 'lan_ip_policy', 'lan_direct_mac_addrs', _('Direct MAC-s'), null, hosts);
		so.depends('lan_proxy_mode', 'except_listed');

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_proxy_ipv4_ips', _('Proxy IPv4 IP-s'), null, 'ipv4', hosts, true);
		so.depends('lan_proxy_mode', 'listed_only');

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_proxy_ipv6_ips', _('Proxy IPv6 IP-s'), null, 'ipv6', hosts, true);
		so.depends({'lan_proxy_mode': 'listed_only', 'homeproxy.config.ipv6_support': '1'});

		so = fwtool.addMACOption(ss, 'lan_ip_policy', 'lan_proxy_mac_addrs', _('Proxy MAC-s'), null, hosts);
		so.depends('lan_proxy_mode', 'listed_only');

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_gaming_mode_ipv4_ips', _('Gaming mode IPv4 IP-s'), null, 'ipv4', hosts, true);

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_gaming_mode_ipv6_ips', _('Gaming mode IPv6 IP-s'), null, 'ipv6', hosts, true);
		so.depends('homeproxy.config.ipv6_support', '1');

		so = fwtool.addMACOption(ss, 'lan_ip_policy', 'lan_gaming_mode_mac_addrs', _('Gaming mode MAC-s'), null, hosts);

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_global_proxy_ipv4_ips', _('Global proxy IPv4 IP-s'), null, 'ipv4', hosts, true);

		so = fwtool.addIPOption(ss, 'lan_ip_policy', 'lan_global_proxy_ipv6_ips', _('Global proxy IPv6 IP-s'), null, 'ipv6', hosts, true);
		so.depends('homeproxy.config.ipv6_support', '1');

		so = fwtool.addMACOption(ss, 'lan_ip_policy', 'lan_global_proxy_mac_addrs', _('Global proxy MAC-s'), null, hosts);
		/* LAN IP policy end */

		/* WAN IP policy start */
		ss.tab('wan_ip_policy', _('WAN IP Policy'));

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_proxy_ipv4_ips', _('Proxy IPv4 IP-s'));
		so.datatype = 'or(ip4addr, cidr4)';

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_proxy_ipv6_ips', _('Proxy IPv6 IP-s'));
		so.datatype = 'or(ip6addr, cidr6)';
		so.depends('homeproxy.config.ipv6_support', '1');
		so.retain = true;

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_direct_ipv4_ips', _('Direct IPv4 IP-s'));
		so.datatype = 'or(ip4addr, cidr4)';

		so = ss.taboption('wan_ip_policy', form.DynamicList, 'wan_direct_ipv6_ips', _('Direct IPv6 IP-s'));
		so.datatype = 'or(ip6addr, cidr6)';
		so.depends('homeproxy.config.ipv6_support', '1');
		so.retain = true;
		/* WAN IP policy end */

		/* Proxy domain list start */
		ss.tab('proxy_domain_list', _('Proxy Domain List'));

		so = ss.taboption('proxy_domain_list', form.TextValue, '_proxy_domain_list');
		so.rows = 10;
		so.monospace = true;
		so.datatype = 'hostname';
		so.load = function(/* ... */) {
			return L.resolveDefault(callReadDomainList('proxy_list')).then((res) => {
				return res.content;
			}, {});
		}
		so.write = function(_section_id, value) {
			return callWriteDomainList('proxy_list', value);
		}
		so.remove = function(/* ... */) {
			return callWriteDomainList('proxy_list', '');
		}
		so.validate = function(section_id, value) {
			if (section_id && value)
				for (let i of value.split('\n'))
					if (i && !stubValidator.apply('hostname', i))
						return _('Expecting: %s').format(_('valid hostname'));

			return true;
		}
		/* Proxy domain list end */

		/* Direct domain list start */
		ss.tab('direct_domain_list', _('Direct Domain List'));

		so = ss.taboption('direct_domain_list', form.TextValue, '_direct_domain_list');
		so.rows = 10;
		so.monospace = true;
		so.datatype = 'hostname';
		so.load = function(/* ... */) {
			return L.resolveDefault(callReadDomainList('direct_list')).then((res) => {
				return res.content;
			}, {});
		}
		so.write = function(_section_id, value) {
			return callWriteDomainList('direct_list', value);
		}
		so.remove = function(/* ... */) {
			return callWriteDomainList('direct_list', '');
		}
		so.validate = function(section_id, value) {
			if (section_id && value)
				for (let i of value.split('\n'))
					if (i && !stubValidator.apply('hostname', i))
						return _('Expecting: %s').format(_('valid hostname'));

			return true;
		}
		/* Direct domain list end */
		/* ACL settings end */

		/* Tailscale settings start */
		s.tab('tailscale', _('Tailscale'));

		o = s.taboption('tailscale', form.SectionValue, '_tailscale', form.NamedSection,
			'tailscale', 'homeproxy');
		ss = o.subsection;

		so = ss.option(form.Flag, 'enabled', _('Enable Tailscale'));
		so.default = so.disabled;
		so.rmempty = false;

		so = ss.option(form.Value, 'auth_key', _('Authentication key'),
			_('Only used when the node is created for the first time. Leave it empty to sign in with the login link below.'));
		so.password = true;
		so.rmempty = true;
		so.retain = true;
		so.depends('enabled', '1');

		so = ss.option(form.DummyValue, '_tailscale_status', _('Login status'));
		so.depends('enabled', '1');
		so.renderWidget = function() {
			const container = E('div', {}, _('Collecting data...'));

			const refresh = () => L.resolveDefault(callTailscaleStatus(), {}).then((status) => {
				dom.content(container, renderTailscaleStatus(status));
			});

			/* drop the previous closure, a re-render would keep polling it */
			if (this.statusRefresh)
				poll.remove(this.statusRefresh);

			this.statusRefresh = refresh;
			poll.add(refresh, 5);
			refresh();

			return container;
		};

		so = ss.option(form.Value, 'control_url', _('Control server'),
			_('Coordination server URL. Leave it empty to use the official Tailscale service.'));
		so.placeholder = 'https://controlplane.tailscale.com';
		so.rmempty = true;
		so.retain = true;
		so.depends('enabled', '1');
		so.validate = function(_section_id, value) {
			if (!value)
				return true;

			try {
				const url = new URL(value);
				return (url.hostname && ['http:', 'https:'].includes(url.protocol)) ||
					_('Expecting: %s').format(_('valid URL'));
			} catch (e) {
				return _('Expecting: %s').format(_('valid URL'));
			}
		};

		so = ss.option(form.Value, 'hostname', _('Hostname'),
			_('The device name shown in the Tailscale network. The system hostname is used when empty.'));
		so.datatype = 'hostname';
		so.rmempty = true;
		so.retain = true;
		so.depends('enabled', '1');

		so = ss.option(form.Flag, 'accept_routes', _('Accept routes'),
			_('Accept subnet routes advertised by other Tailscale nodes.'));
		so.default = so.disabled;
		so.rmempty = false;
		so.retain = true;
		so.depends('enabled', '1');

		so = ss.option(form.Value, 'exit_node', _('Exit node'),
			_('Exit node name or IP address. Used as the default route once the exit node is approved.'));
		so.rmempty = true;
		so.retain = true;
		so.depends('enabled', '1');
		so.validate = function(section_id, value) {
			if (!value)
				return true;

			if (this.section.formvalue(section_id, 'advertise_exit_node') === '1')
				return _('An exit node cannot be used and advertised at the same time.');

			return stubValidator.apply('hostname', value) ||
				stubValidator.apply('ip4addr', value) ||
				stubValidator.apply('ip6addr', value) ||
				_('Expecting: %s').format(_('valid hostname or IP address'));
		};

		so = ss.option(form.Flag, 'exit_node_allow_lan_access', _('Allow LAN access with exit node'),
			_('Keep locally reachable subnets outside the selected exit node.'));
		so.default = so.disabled;
		so.rmempty = false;
		so.retain = true;
		so.depends('enabled', '1');

		so = ss.option(form.DynamicList, 'advertise_routes', _('Advertised routes'),
			_('LAN subnets advertised as reachable through this router. Every route must also be approved on the coordination server.'));
		so.rmempty = true;
		so.retain = true;
		so.depends('enabled', '1');
		so.validate = function(_section_id, value) {
			/* Validate here, the CIDR datatype would replace the value by its prefix length */
			if (value && !stubValidator.apply('cidr', value))
				return _('Expecting: %s').format(_('valid network in CIDR notation'));

			if (value === '0.0.0.0/0' || value === '::/0')
				return _('Use "Advertise as exit node" instead of a default route.');

			return true;
		};

		so = ss.option(form.Flag, 'advertise_exit_node', _('Advertise as exit node'),
			_('Advertise this router as an exit node. It still has to be approved on the coordination server.'));
		so.default = so.disabled;
		so.rmempty = false;
		so.retain = true;
		so.depends('enabled', '1');
		so.validate = function(section_id, value) {
			if (value === '1' && this.section.formvalue(section_id, 'exit_node'))
				return _('An exit node cannot be used and advertised at the same time.');

			return true;
		};

		so = ss.option(form.Value, 'listen_port', _('Listen port'),
			_('UDP port used for WireGuard and peer-to-peer traffic. A port is chosen automatically when empty.'));
		so.datatype = 'port';
		so.rmempty = true;
		so.retain = true;
		so.depends('enabled', '1');
		/* Tailscale settings end */

		return m.render();
	}
});
