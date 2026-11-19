#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2023-2025 ImmortalWrt.org
 */

'use strict';

import { readfile, writefile } from 'fs';
import { isnan } from 'math';
import { connect } from 'ubus';
import { cursor } from 'uci';

import {
	isEmpty, normalizeList, parseURL, parseHeaderList, rangeValue, strToBool, strToInt, strToTime,
	removeBlankAttrs, validation, xhttpPadding, HP_DIR, RUN_DIR
} from 'homeproxy';

const ubus = connect();

/* const features = ubus.call('luci.homeproxy', 'singbox_get_features') || {}; */

/* UCI config start */
const uci = cursor();

const uciconfig = 'homeproxy';
uci.load(uciconfig);

const uciinfra = 'infra',
      ucimain = 'config',
      ucicontrol = 'control',
      ucitalscale = 'tailscale';

const ucinode = 'node';
const uciapprule = 'app_rule';

/* Rule sets used by the application based routing rules */
const app_rule_urls = {
	youtube: {
		domain: 'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/youtube.srs'
	},
	tiktok: {
		domain: 'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/tiktok.srs'
	},
	telegram: {
		domain: 'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/telegram.srs',
		ip: 'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/telegram.srs'
	},
	twitter: {
		domain: 'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/twitter.srs',
		ip: 'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/twitter.srs'
	},
	google: {
		domain: 'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/google.srs',
		ip: 'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/google.srs'
	},
	cloudflare: {
		domain: 'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/cloudflare.srs',
		ip: 'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/cloudflare.srs'
	},
	github: {
		domain: 'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/github.srs'
	},
	ai_noncn: {
		domain: 'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/category-ai-!cn.srs'
	}
};

let routing_mode = uci.get(uciconfig, ucimain, 'routing_mode') || 'bypass_mainland_china';
/* custom, gfwlist and proxy_mainland_china were removed, migrate_config.uc rewrites them */
if (routing_mode in ['custom', 'gfwlist', 'proxy_mainland_china'])
	routing_mode = 'bypass_mainland_china';

let wan_dns = ubus.call('network.interface', 'status', {'interface': 'wan'})?.['dns-server']?.[0];
if (!wan_dns)
	wan_dns = (routing_mode === 'global') ? '8.8.8.8' : '223.5.5.5';

const dns_port = uci.get(uciconfig, uciinfra, 'dns_port') || '5333';

const dns_server_fallback = normalizeList(uci.get(uciconfig, ucimain, 'dns_server_fallback')),
      china_dns_server_fallback = normalizeList(uci.get(uciconfig, ucimain, 'china_dns_server_fallback')),
      dns_fallback_strategy = uci.get(uciconfig, ucimain, 'dns_fallback_strategy') || 'sequential',
      dns_fallback_timeout = uci.get(uciconfig, ucimain, 'dns_fallback_timeout');

const ntp_server = uci.get(uciconfig, uciinfra, 'ntp_server') || 'time.apple.com';

const ipv6_support = uci.get(uciconfig, ucimain, 'ipv6_support') || '0';

let main_node, dns_server, china_dns_server,
    dns_default_strategy, direct_domain_list, proxy_domain_list;

main_node = uci.get(uciconfig, ucimain, 'main_node') || 'nil';

/* a stale reference (deleted node) must not break the configuration */
if (!isEmpty(main_node) && main_node !== 'urltest' &&
    type(uci.get_all(uciconfig, main_node)) !== 'object')
	main_node = 'nil';

/* an URLTest group without members cannot be generated */
/*
 * HPGROUP: 订阅组 → 节点。URLTest 可以直接选「订阅组」（grouphash，或 __manual__ = 手动节点），
 * 并按 limit（空 = 全部 / 数字 / half）稳定取用；再与单独挑选的节点合并、去重。
 */
function expand_urltest_nodes(nodes, groups, limit) {
	const result = [], seen = {};
	limit = trim('' + (limit ?? ''));

	for (let g in normalizeList(groups)) {
		let ids = [];
		uci.foreach(uciconfig, 'node', (c) => {
			if ((g === '__manual__' && isEmpty(c.grouphash)) || c.grouphash === g)
				push(ids, c['.name']);
		});
		ids = sort(ids);

		let keep = length(ids);
		if (limit === 'half')
			keep = int((length(ids) + 1) / 2);
		else if (int(limit) > 0 && int(limit) < length(ids))
			keep = int(limit);

		for (let i = 0; i < keep; i++) {
			if (!seen[ids[i]]) {
				seen[ids[i]] = true;
				push(result, ids[i]);
			}
		}
	}

	for (let n in normalizeList(nodes)) {
		if (!seen[n]) {
			seen[n] = true;
			push(result, n);
		}
	}

	return result;
}

const main_urltest_nodes = expand_urltest_nodes(
	uci.get(uciconfig, ucimain, 'main_urltest_nodes'),
	uci.get(uciconfig, ucimain, 'main_urltest_groups'),
	uci.get(uciconfig, ucimain, 'main_urltest_group_limit'));

if (main_node === 'urltest' && !length(main_urltest_nodes))
	main_node = 'nil';

dns_server = uci.get(uciconfig, ucimain, 'dns_server');
if (isEmpty(dns_server) || dns_server === 'wan')
	dns_server = wan_dns;

if (routing_mode === 'bypass_mainland_china') {
	china_dns_server = uci.get(uciconfig, ucimain, 'china_dns_server');
	if (isEmpty(china_dns_server) || type(china_dns_server) !== 'string' || china_dns_server === 'wan')
		china_dns_server = wan_dns;
}

/*
 * IPv6 ON:
 *   no IPv4-only DNS strategy.
 *
 * IPv6 OFF:
 *   keep the original IPv4-only fallback behavior.
 *
 * No query_type/AAAA filtering is used when IPv6 is enabled.
 */
dns_default_strategy = (ipv6_support !== '1') ? 'ipv4_only' : null;

direct_domain_list = trim(readfile(HP_DIR + '/resources/direct_list.txt'));
if (direct_domain_list)
	direct_domain_list = split(direct_domain_list, /[\r\n]/);

proxy_domain_list = trim(readfile(HP_DIR + '/resources/proxy_list.txt'));
if (proxy_domain_list)
	proxy_domain_list = split(proxy_domain_list, /[\r\n]/);

const proxy_mode = uci.get(uciconfig, ucimain, 'proxy_mode') || 'redirect_tproxy',
      default_interface = uci.get(uciconfig, ucicontrol, 'bind_interface');

const mixed_port = uci.get(uciconfig, uciinfra, 'mixed_port') || '5330';

let self_mark, redirect_port, tproxy_port, tun_name,
    tun_addr4, tun_addr6, tun_mtu, tcpip_stack, udp_timeout;

udp_timeout = uci.get(uciconfig, uciinfra, 'udp_timeout');

/*
 * Every mode needs the mark: the sockets sing-box creates for its own
 * outbounds (proxy nodes, direct, endpoints) carry it, so the redirect and
 * TUN rules never capture the traffic a second time.
 */
self_mark = uci.get(uciconfig, 'infra', 'self_mark') || '100';

if (match(proxy_mode, /redirect/))
	redirect_port = uci.get(uciconfig, 'infra', 'redirect_port') || '5331';

if (match(proxy_mode, /tproxy/))
	tproxy_port = uci.get(uciconfig, 'infra', 'tproxy_port') || '5332';

if (match(proxy_mode, /tun/)) {
	tun_name = uci.get(uciconfig, uciinfra, 'tun_name') || 'singtun0';
	tun_addr4 = uci.get(uciconfig, uciinfra, 'tun_addr4') || '172.19.0.1/30';
	tun_addr6 = uci.get(uciconfig, uciinfra, 'tun_addr6') || 'fdfe:dcba:9876::1/126';
	tun_mtu = uci.get(uciconfig, uciinfra, 'tun_mtu') || '9000';
	tcpip_stack = uci.get(uciconfig, ucimain, 'tcpip_stack') || 'system';
}

const log_level = uci.get(uciconfig, ucimain, 'log_level') || 'warn';

/* The bundled sing-box dashboard is served by the core itself */
const dashboard_path = HP_DIR + '/dashboard';

const dashboard_enabled = !isEmpty(readfile(dashboard_path + '/index.html')),
      dashboard_port = strToInt(uci.get(uciconfig, ucimain, 'dashboard_port')) || 9096,
      dashboard_secret = uci.get(uciconfig, ucimain, 'dashboard_secret');

/*
 * Tailscale endpoint (sing-box >= 1.14).
 */
const tailscale_tag = 'tailscale-out';
const tailscale_enabled = uci.get(uciconfig, ucitalscale, 'enabled') === '1';
const tailscale_auth_key = uci.get(uciconfig, ucitalscale, 'auth_key');
const tailscale_control_url = uci.get(uciconfig, ucitalscale, 'control_url');
const tailscale_hostname = uci.get(uciconfig, ucitalscale, 'hostname');
const tailscale_accept_routes = uci.get(uciconfig, ucitalscale, 'accept_routes') === '1';
const tailscale_exit_node = uci.get(uciconfig, ucitalscale, 'exit_node');

const tailscale_exit_node_allow_lan_access =
	uci.get(uciconfig, ucitalscale, 'exit_node_allow_lan_access') === '1';

const tailscale_advertise_routes =
	normalizeList(uci.get(uciconfig, ucitalscale, 'advertise_routes'));

const tailscale_listen_port =
	uci.get(uciconfig, ucitalscale, 'listen_port');

let tailscale_advertise_exit_node =
	uci.get(uciconfig, ucitalscale, 'advertise_exit_node') === '1';

/* A node cannot use an exit node and advertise itself as one at the same time */
if (tailscale_enabled && !isEmpty(tailscale_exit_node) && tailscale_advertise_exit_node) {
	warn('Tailscale: an exit node cannot be used and advertised at the same time, disabling the advertisement.\n');
	tailscale_advertise_exit_node = false;
}

/* UCI config end */


/*
 * Outbound tags are derived from node labels.
 */
const reserved_out_tags = {
	'direct-out': true,
	'block-out': true,
	'main-out': true,
	'tailscale-out': true
};

const node_out_tags = {};

uci.foreach(uciconfig, ucinode, (cfg) => {
	const base = trim(cfg.label || '') || cfg['.name'];
	let tag = base, suffix = 2;

	while (reserved_out_tags[tag])
		tag = `${base} (${suffix++})`;

	reserved_out_tags[tag] = true;
	node_out_tags[cfg['.name']] = tag;
});

function node_out_tag(id) {
	return node_out_tags[id] || ('cfg-' + id + '-out');
}

/*
 * The main outbound keeps the well-known tag only for the urltest group.
 */
let main_out_tag = (isEmpty(main_node) || main_node === 'urltest') ?
	'main-out' : node_out_tag(main_node);


/* Config helper start */

function parse_port(strport) {
	if (type(strport) !== 'array' || isEmpty(strport))
		return null;

	let ports = [];

	for (let i in strport)
		push(ports, int(i));

	return ports;
}

function parse_dnsserver(server_addr, default_protocol) {
	if (isEmpty(server_addr))
		return null;

	if (!match(server_addr, /:\/\//))
		server_addr =
			(default_protocol || 'udp') + '://' +
			(validation('ip6addr', server_addr) ? `[${server_addr}]` : server_addr);

	server_addr = parseURL(server_addr);

	return {
		type: server_addr.protocol,
		server: server_addr.hostname,
		server_port: strToInt(server_addr.port),
		path: (server_addr.pathname !== '/') ? server_addr.pathname : null,
	};
}

/*
 * The core rejects max_connections together with max_concurrency.
 */
function normalize_xmux(xmux) {
	if (!xmux)
		return null;

	if (!isEmpty(xmux.max_concurrency) && !isEmpty(xmux.max_connections))
		xmux.max_connections = null;

	return xmux;
}

function generate_endpoint(node) {
	if (type(node) !== 'object' || isEmpty(node))
		return null;

	const endpoint = {
		type: node.type,
		tag: node_out_tag(node['.name']),
		address: node.wireguard_local_address,
		mtu: strToInt(node.wireguard_mtu),
		private_key: node.wireguard_private_key,

		peers: (node.type === 'wireguard') ? [
			{
				address: node.address,
				port: strToInt(node.port),

				allowed_ips: [
					'0.0.0.0/0',
					'::/0'
				],

				persistent_keepalive_interval:
					strToInt(node.wireguard_persistent_keepalive_interval),

				public_key: node.wireguard_peer_public_key,
				pre_shared_key: node.wireguard_pre_shared_key,
				reserved: parse_port(node.wireguard_reserved),
			}
		] : null,

		system: (node.type === 'wireguard') ? false : null,
		tcp_fast_open: strToBool(node.tcp_fast_open),
		tcp_multi_path: strToBool(node.tcp_multi_path),
		udp_fragment: strToBool(node.udp_fragment)
	};

	return endpoint;
}

/*
 * HPCHAIN: 链式代理。node.chain_node = 前置节点 id，本节点的连接先走前置节点（sing-box detour）。
 * 前置节点不存在 / 选了自己 / 链条绕回自己时忽略，避免生成无法启动的配置。
 */
function chain_detour(node) {
	let id = trim('' + (node.chain_node ?? ''));
	const self = node['.name'];

	if (isEmpty(id) || id === self)
		return null;

	let cur = id, hops = 0;

	while (!isEmpty(cur) && hops++ < 8) {
		const cfg = uci.get_all(uciconfig, cur);

		if (type(cfg) !== 'object' || isEmpty(cfg.type))
			return null;

		if (cur === self)
			return null;

		cur = trim('' + (cfg.chain_node ?? ''));
		if (cur === self)
			return null;
	}

	return node_out_tag(id);
}

/*
 * HPCHAIN: 后置落地。node.chain_next = 落地节点 id：选用本节点时，路径是
 * 路由器 → 本节点（含它自己的前置）→ 落地节点 → 目标网站，出口是落地节点。
 * 落地不存在 / 选了自己 / 是 WireGuard 时忽略。
 */
function chain_next_cfg(node) {
	const id = trim('' + (node.chain_next ?? ''));

	if (isEmpty(id) || id === node['.name'])
		return null;

	const cfg = uci.get_all(uciconfig, id);

	if (type(cfg) !== 'object' || isEmpty(cfg.type) || cfg.type === 'wireguard')
		return null;

	return cfg;
}

function generate_outbound(node) {
	if (type(node) !== 'object' || isEmpty(node))
		return null;

	const landing = chain_next_cfg(node);

	if (!landing)
		return generate_outbound_raw(node);

	/* 跳板：本节点自己，tag 加 -hop；真正对外的 tag 给落地节点配置，并 detour 到跳板 */
	const hop_tag = node_out_tag(node['.name']) + '-hop';

	if (!config.outbounds)
		config.outbounds = [];

	let hop_exists = false;
	for (let o in config.outbounds)
		if (o && o.tag === hop_tag) {
			hop_exists = true;
			break;
		}

	if (!hop_exists)
		push(config.outbounds, generate_outbound_raw(node, { tag: hop_tag }));

	return generate_outbound_raw(landing, { tag: node_out_tag(node['.name']), detour: hop_tag, landing: true });
}

function generate_outbound_raw(node, ov) {
	if (type(node) !== 'object' || isEmpty(node))
		return null;

	const is_xhttp = (node.transport === 'xhttp');

	const outbound = {
		type: node.type,
		tag: ov?.tag ?? node_out_tag(node['.name']),
		routing_mark: strToInt(self_mark),
		detour: ov?.landing ? ov.detour : chain_detour(node),

		server: node.address,
		server_port: strToInt(node.port),
		server_ports: node.hysteria_hopping_port,

		username: (node.type !== 'ssh') ? node.username : null,
		user: (node.type === 'ssh') ? node.username : null,
		password: node.password,

		override_address: node.override_address,
		override_port: strToInt(node.override_port),
		proxy_protocol: strToInt(node.proxy_protocol),

		idle_session_check_interval:
			strToTime(node.anytls_idle_session_check_interval),

		idle_session_timeout:
			strToTime(node.anytls_idle_session_timeout),

		min_idle_session:
			strToInt(node.anytls_min_idle_session),

		hop_interval:
			strToTime(node.hysteria_hop_interval),

		up_mbps:
			strToInt(node.hysteria_up_mbps),

		down_mbps:
			strToInt(node.hysteria_down_mbps),

		obfs: node.hysteria_obfs_type ? {
			type: node.hysteria_obfs_type,
			password: node.hysteria_obfs_password
		} : node.hysteria_obfs_password,

		auth: (node.hysteria_auth_type === 'base64') ?
			node.hysteria_auth_payload : null,

		auth_str: (node.hysteria_auth_type === 'string') ?
			node.hysteria_auth_payload : null,

		recv_window_conn:
			strToInt(node.hysteria_recv_window_conn),

		recv_window:
			strToInt(node.hysteria_revc_window),

		disable_mtu_discovery:
			strToBool(node.hysteria_disable_mtu_discovery),

		method:
			node.shadowsocks_encrypt_method,

		plugin:
			node.shadowsocks_plugin,

		plugin_opts:
			node.shadowsocks_plugin_opts,

		version:
			(node.type === 'shadowtls') ?
				strToInt(node.shadowtls_version) :
				((node.type === 'socks') ? node.socks_version : null),

		client_version:
			node.ssh_client_version,

		host_key:
			node.ssh_host_key,

		host_key_algorithms:
			node.ssh_host_key_algo,

		private_key:
			node.ssh_priv_key,

		private_key_passphrase:
			node.ssh_priv_key_pp,

		uuid:
			node.uuid,

		congestion_control:
			node.tuic_congestion_control,

		udp_relay_mode:
			node.tuic_udp_relay_mode,

		udp_over_stream:
			strToBool(node.tuic_udp_over_stream),

		zero_rtt_handshake:
			strToBool(node.tuic_enable_zero_rtt),

		heartbeat:
			strToTime(node.tuic_heartbeat),

		flow:
			node.vless_flow,

		alter_id:
			strToInt(node.vmess_alterid),

		security:
			node.vmess_encrypt,

		global_padding:
			strToBool(node.vmess_global_padding),

		authenticated_length:
			strToBool(node.vmess_authenticated_length),

		packet_encoding:
			node.packet_encoding,

		multiplex: (node.multiplex === '1') ? {
			enabled: true,
			protocol: node.multiplex_protocol,
			max_connections: strToInt(node.multiplex_max_connections),
			min_streams: strToInt(node.multiplex_min_streams),
			max_streams: strToInt(node.multiplex_max_streams),
			padding: strToBool(node.multiplex_padding),

			brutal: (node.multiplex_brutal === '1') ? {
				enabled: true,
				up_mbps: strToInt(node.multiplex_brutal_up),
				down_mbps: strToInt(node.multiplex_brutal_down)
			} : null
		} : null,

		tls: (node.tls === '1') ? {
			enabled: true,
			server_name: node.tls_sni,
			insecure: strToBool(node.tls_insecure),
			alpn: node.tls_alpn,
			min_version: node.tls_min_version,
			max_version: node.tls_max_version,
			cipher_suites: node.tls_cipher_suites,
			certificate_path: node.tls_cert_path,

			ech: (node.tls_ech === '1') ? {
				enabled: true,
				config: node.tls_ech_config,
				config_path: node.tls_ech_config_path
			} : null,

			utls: !isEmpty(node.tls_utls) ? {
				enabled: true,
				fingerprint: node.tls_utls
			} : null,

			reality: (node.tls_reality === '1') ? {
				enabled: true,
				public_key: node.tls_reality_public_key,
				short_id: node.tls_reality_short_id
			} : null
		} : null,

		transport: !isEmpty(node.transport) ? {
			type: node.transport,

			host:
				node.http_host ||
				node.httpupgrade_host ||
				node.xhttp_host,

			path:
				node.http_path ||
				node.ws_path ||
				node.xhttp_path,

			headers: node.ws_host ? {
				Host: node.ws_host
			} : (is_xhttp ? parseHeaderList(node.xhttp_headers) : null),

			method:
				(node.transport === 'http') ?
					node.http_method : null,

			max_early_data:
				strToInt(node.websocket_early_data),

			early_data_header_name:
				node.websocket_early_data_header,

			service_name:
				node.grpc_servicename,

			idle_timeout:
				strToTime(node.http_idle_timeout),

			ping_timeout:
				strToTime(node.http_ping_timeout),

			permit_without_stream:
				strToBool(node.grpc_permit_without_stream),

			mode:
				is_xhttp ?
					(node.xhttp_mode || null) : null,

			domain_strategy:
				is_xhttp ?
					(node.xhttp_domain_strategy || null) : null,

			x_padding_bytes:
				is_xhttp ?
					xhttpPadding(node.xhttp_padding_bytes) : null,

			no_grpc_header:
				is_xhttp ?
					strToBool(node.xhttp_no_grpc_header) : null,

			sc_max_each_post_bytes:
				is_xhttp ?
					rangeValue(node.xhttp_sc_max_each_post_bytes) : null,

			sc_min_posts_interval_ms:
				is_xhttp ?
					rangeValue(node.xhttp_sc_min_posts_interval_ms) : null,

			uplink_http_method:
				is_xhttp ?
					(node.xhttp_method || null) : null,

			congestion_controller:
				is_xhttp ?
					(node.xhttp_congestion_controller || null) : null,

			cwnd:
				is_xhttp ?
					strToInt(node.xhttp_cwnd) : null,

			x_padding_obfs_mode:
				is_xhttp ?
					strToBool(node.xhttp_x_padding_obfs_mode) : null,

			x_padding_placement:
				is_xhttp ?
					(node.xhttp_x_padding_placement || null) : null,

			x_padding_key:
				is_xhttp ?
					(node.xhttp_x_padding_key || null) : null,

			x_padding_header:
				is_xhttp ?
					(node.xhttp_x_padding_header || null) : null,

			x_padding_method:
				is_xhttp ?
					(node.xhttp_x_padding_method || null) : null,

			session_placement:
				is_xhttp ?
					(node.xhttp_session_placement || null) : null,

			session_key:
				is_xhttp ?
					(node.xhttp_session_key || null) : null,

			session_id_table:
				is_xhttp ?
					(node.xhttp_session_id_table || null) : null,

			session_id_length:
				is_xhttp ?
					(node.xhttp_session_id_length || null) : null,

			seq_placement:
				is_xhttp ?
					(node.xhttp_seq_placement || null) : null,

			seq_key:
				is_xhttp ?
					(node.xhttp_seq_key || null) : null,

			uplink_data_placement:
				is_xhttp ?
					(node.xhttp_uplink_data_placement || null) : null,

			uplink_data_key:
				is_xhttp ?
					(node.xhttp_uplink_data_key || null) : null,

			uplink_chunk_size:
				is_xhttp ?
					(node.xhttp_uplink_chunk_size || null) : null,

			download:
				(is_xhttp &&
				(node.xhttp_download_host ||
				 node.xhttp_download_path ||
				 node.xhttp_download_server)) ? {

					host:
						node.xhttp_download_host || null,

					path:
						node.xhttp_download_path || null,

					headers:
						parseHeaderList(node.xhttp_download_headers),

					domain_strategy:
						node.xhttp_download_domain_strategy || null,

					x_padding_bytes:
						xhttpPadding(
							node.xhttp_download_padding_bytes ||
							node.xhttp_padding_bytes
						),

					uplink_http_method:
						node.xhttp_download_method || null,

					congestion_controller:
						node.xhttp_download_congestion_controller || null,

					cwnd:
						strToInt(node.xhttp_download_cwnd),

					no_grpc_header:
						strToBool(node.xhttp_download_no_grpc_header),

					x_padding_obfs_mode:
						strToBool(node.xhttp_download_x_padding_obfs_mode),

					x_padding_placement:
						node.xhttp_download_x_padding_placement || null,

					x_padding_key:
						node.xhttp_download_x_padding_key || null,

					x_padding_header:
						node.xhttp_download_x_padding_header || null,

					x_padding_method:
						node.xhttp_download_x_padding_method || null,

					session_placement:
						node.xhttp_download_session_placement || null,

					session_key:
						node.xhttp_download_session_key || null,

					seq_placement:
						node.xhttp_download_seq_placement || null,

					seq_key:
						node.xhttp_download_seq_key || null,

					uplink_data_placement:
						node.xhttp_download_uplink_data_placement || null,

					uplink_data_key:
						node.xhttp_download_uplink_data_key || null,

					uplink_chunk_size:
						node.xhttp_download_uplink_chunk_size || null,

					xmux:
						(
							node.xhttp_download_xmux_max_concurrency ||
							node.xhttp_download_xmux_max_connections ||
							node.xhttp_download_xmux_c_max_reuse_times ||
							node.xhttp_download_xmux_h_max_request_times ||
							node.xhttp_download_xmux_h_max_reusable_secs ||
							node.xhttp_download_xmux_h_keep_alive_period
						) ? normalize_xmux({
							max_concurrency:
								node.xhttp_download_xmux_max_concurrency,

							max_connections:
								rangeValue(
									node.xhttp_download_xmux_max_connections
								),

							c_max_reuse_times:
								rangeValue(
									node.xhttp_download_xmux_c_max_reuse_times
								),

							h_max_request_times:
								node.xhttp_download_xmux_h_max_request_times,

							h_max_reusable_secs:
								node.xhttp_download_xmux_h_max_reusable_secs,

							h_keep_alive_period:
								strToInt(
									node.xhttp_download_xmux_h_keep_alive_period
								)
						}) : null,

					server:
						node.xhttp_download_server || null,

					server_port:
						strToInt(node.xhttp_download_server_port),

					tls:
						(node.xhttp_download_tls === '1') ? {
							enabled: true,
							server_name:
								node.xhttp_download_tls_server_name,
							alpn:
								node.xhttp_download_tls_alpn
						} : null,

					detour:
						node.xhttp_download_detour || null
				} : null,

			xmux:
				is_xhttp ? normalize_xmux({
					max_concurrency:
						node.xhttp_xmux_max_concurrency,

					max_connections:
						rangeValue(node.xhttp_xmux_max_connections),

					c_max_reuse_times:
						rangeValue(node.xhttp_xmux_c_max_reuse_times),

					h_max_request_times:
						node.xhttp_xmux_h_max_request_times,

					h_max_reusable_secs:
						node.xhttp_xmux_h_max_reusable_secs,

					h_keep_alive_period:
						strToInt(node.xhttp_xmux_h_keep_alive_period)
				}) : null
		} : null,

		udp_over_tcp:
			(node.udp_over_tcp === '1') ? {
				enabled: true,
				version: strToInt(node.udp_over_tcp_version)
			} : null,

		tcp_fast_open:
			strToBool(node.tcp_fast_open),

		tcp_multi_path:
			strToBool(node.tcp_multi_path),

		udp_fragment:
			strToBool(node.udp_fragment)
	};

	return outbound;
}

/* Config helper end */


const config = {};

function outbound_tag_defined(tag) {
	for (let out in (config.outbounds || []))
		if (out && out.tag === tag)
			return true;

	for (let ep in (config.endpoints || []))
		if (ep && ep.tag === tag)
			return true;

	return false;
}


/* Log */
config.log = {
	disabled: false,
	level: log_level,
	output: RUN_DIR + '/sing-box-c.log',
	timestamp: true
};


/* NTP */
if (!isEmpty(ntp_server))
	config.ntp = {
		enabled: true,
		server: ntp_server,
		detour: 'direct-out',
		domain_resolver: 'default-dns',
	};


/* DNS start */

/*
 * IPv6 behavior:
 *
 * ipv6_support = 1:
 *   DNS strategy is unrestricted.
 *   A and AAAA are both allowed.
 *
 * ipv6_support = 0:
 *   global DNS strategy remains ipv4_only.
 */
config.dns = {
	servers: [
		{
			tag: 'default-dns',
			type: 'udp',
			server: wan_dns,
			detour: self_mark ? 'direct-out' : null
		},
		{
			tag: 'system-dns',
			type: 'local',
			detour: self_mark ? 'direct-out' : null
		}
	],

	rules: [],

	strategy: dns_default_strategy,

	client_subnet: null
};


/*
 * Primary + fallback DNS servers.
 */
function push_dns_server_with_fallback(
	tag,
	server_addr,
	default_protocol,
	fallback_list,
	detour,
	resolver_strategy
) {
	const base = {
		domain_resolver: {
			server: 'default-dns',
			strategy: resolver_strategy
		},
		detour: detour
	};

	if (!length(fallback_list)) {
		push(config.dns.servers, {
			tag,
			...base,
			...parse_dnsserver(server_addr, default_protocol)
		});

		return;
	}

	const member_tags = [`${tag}-primary`];

	push(config.dns.servers, {
		tag: member_tags[0],
		...base,
		...parse_dnsserver(server_addr, default_protocol)
	});

	let idx = 0;

	for (let addr in fallback_list) {
		let member_tag = `${tag}-fallback-${idx++}`;

		push(config.dns.servers, {
			tag: member_tag,
			...base,
			...parse_dnsserver(addr, default_protocol)
		});

		push(member_tags, member_tag);
	}

	push(config.dns.servers, {
		tag,
		type: 'fallback',
		servers: member_tags,
		strategy: dns_fallback_strategy,
		timeout: strToTime(dns_fallback_timeout)
	});
}


if (tailscale_enabled) {
	/*
	 * MagicDNS.
	 */
	push(config.dns.servers, {
		type: 'tailscale',
		tag: 'tailscale-dns',
		endpoint: tailscale_tag
	});

	push(config.dns.rules, {
		preferred_by: 'tailscale-dns',
		action: 'route',
		server: 'tailscale-dns'
	});

	if (isEmpty(main_node))
		config.dns.final = 'default-dns';
}


if (!isEmpty(main_node)) {

	/* Main DNS */
	push_dns_server_with_fallback(
		'main-dns',
		dns_server,
		'tcp',
		dns_server_fallback,
		main_out_tag,
		(ipv6_support !== '1') ? 'ipv4_only' : null
	);

	config.dns.final = 'main-dns';


	/* Direct list */
	if (length(direct_domain_list))
		push(config.dns.rules, {
			rule_set: 'direct-domain',
			action: 'route',
			server:
				(routing_mode === 'bypass_mainland_china') ?
					'china-dns' :
					'default-dns'
		});


	/*
	 * HPV6: the proxy nodes (Cloudflare Worker based) refuse IPv6 literal targets
	 * ("出站被策略拒绝 ... 目标地址被策略拦截"), so a proxied domain must stay IPv4 only.
	 * Domains answered by main-dns get an empty AAAA/HTTPS/SVCB answer, the LAN client
	 * then connects over IPv4. Direct (China) domains keep full dual-stack DNS.
	 */
	/* uci set homeproxy.config.proxy_ipv6=1 : keep IPv6 for proxied domains (only for IPv6-capable nodes) */
	const proxy_keep_ipv6 = (uci.get(uciconfig, ucimain, 'proxy_ipv6') === '1');

	function push_no_aaaa(rule_set) {
		if (ipv6_support !== '1' || proxy_keep_ipv6)
			return;

		const rule = {
			query_type: [ 'AAAA', 'HTTPS', 'SVCB' ],
			action: 'predefined',
			rcode: 'NOERROR'
		};

		if (rule_set)
			rule.rule_set = rule_set;

		push(config.dns.rules, rule);
	}

	if (routing_mode !== 'bypass_mainland_china')
		push_no_aaaa(null);


	/*
	 * IMPORTANT:
	 *
	 * No query_type [28,64,65].
	 * No AAAA reject.
	 * No SVCB/HTTPS reject.
	 *
	 * IPv6 ON therefore keeps complete dual-stack DNS behavior.
	 */


	if (routing_mode === 'bypass_mainland_china') {

		/*
		 * China DNS:
		 *
		 * IPv6 is preferred, but IPv4 remains available.
		 * This is the direct dual-stack side.
		 */
		push_dns_server_with_fallback(
			'china-dns',
			china_dns_server,
			'udp',
			china_dns_server_fallback,
			self_mark ? 'direct-out' : null,
			'prefer_ipv6'
		);


		/*
		 * Proxy domain list always uses main-dns.
		 *
		 * No query_type filter here.
		 * A + AAAA + HTTPS/SVCB are all allowed.
		 */
		if (length(proxy_domain_list)) {
			push_no_aaaa('proxy-domain');

			push(config.dns.rules, {
				rule_set: 'proxy-domain',
				action: 'route',
				server: 'main-dns'
			});
		}


		/*
		 * Known mainland domains -> China DNS.
		 */
		push(config.dns.rules, {
			rule_set: 'geosite-cn',
			action: 'route',
			server: 'china-dns'
		});


		/*
		 * sing-box 1.14+ compatible replacement for the old:
		 *
		 * type: logical
		 *   geosite-noncn invert
		 *   geoip-cn
		 *
		 * We do NOT put geoip-cn directly into a DNS route rule.
		 *
		 * Instead:
		 *
		 *   1. Ask china-dns and save its response.
		 *   2. Match the evaluated response against geoip-cn.
		 *   3. If the returned IP is in China, route through china-dns.
		 *   4. Otherwise continue to the normal final main-dns.
		 *
		 * This preserves the domestic-IP DNS decision while complying
		 * with sing-box 1.14 response matching.
		 */


		/*
		 * Known non-mainland domains go directly to main-dns.
		 *
		 * This avoids sending known foreign domains through the
		 * China-DNS response probe.
		 */
		push_no_aaaa('geosite-noncn');

		push(config.dns.rules, {
			rule_set: 'geosite-noncn',
			action: 'route',
			server: 'main-dns'
		});


		/*
		 * Unknown domains:
		 *
		 * evaluate against China DNS.
		 *
		 * The evaluated response is only used for classification.
		 */
		push(config.dns.rules, {
			action: 'evaluate',
			server: 'china-dns',
			tag: 'china-dns-probe'
		});


		/*
		 * If China DNS returns a mainland IP, keep the DNS request
		 * on the China DNS side.
		 *
		 * geoip-cn is retained here in the new 1.14+ compliant form.
		 */
		push(config.dns.rules, {
			match_response: 'china-dns-probe',
			rule_set: 'geoip-cn',
			action: 'route',
			server: 'china-dns'
		});

		/* everything still unmatched goes to main-dns: IPv4 only */
		push_no_aaaa(null);


		/*
		 * If the evaluated China-DNS response is not mainland,
		 * fall through to config.dns.final = main-dns.
		 */
	}
}


/* DNS end */


/* Inbound start */

config.inbounds = [];

push(config.inbounds, {
	type: 'direct',
	tag: 'dns-in',
	listen: '::',
	listen_port: int(dns_port)
});

push(config.inbounds, {
	type: 'mixed',
	tag: 'mixed-in',
	listen: '::',
	listen_port: int(mixed_port),
	udp_timeout: strToTime(udp_timeout),
	set_system_proxy: false
});

if (match(proxy_mode, /redirect/))
	push(config.inbounds, {
		type: 'redirect',
		tag: 'redirect-in',
		listen: '::',
		listen_port: int(redirect_port)
	});

if (match(proxy_mode, /tproxy/) && !isEmpty(tproxy_port))
	push(config.inbounds, {
		type: 'tproxy',
		tag: 'tproxy-in',
		listen: '::',
		listen_port: int(tproxy_port),
		network: 'udp',
		udp_timeout: strToTime(udp_timeout)
	});

if (match(proxy_mode, /tun/))
	push(config.inbounds, {
		type: 'tun',
		tag: 'tun-in',
		interface_name: tun_name,

		address:
			(ipv6_support === '1') ?
				[tun_addr4, tun_addr6] :
				[tun_addr4],

		mtu: strToInt(tun_mtu),
		auto_route: false,
		udp_timeout: strToTime(udp_timeout),
		stack: tcpip_stack
	});

/* Inbound end */


/* Outbound start */

config.endpoints = [];


/* Tailscale endpoint */

if (tailscale_enabled)
	push(config.endpoints, {
		type: 'tailscale',
		tag: tailscale_tag,

		routing_mark:
			strToInt(self_mark),

		domain_resolver: {
			server: 'default-dns',
			strategy: dns_default_strategy
		},

		state_directory:
			HP_DIR + '/tailscale',

		taildrop_directory:
			HP_DIR + '/tailscale/taildrop',

		auth_key:
			tailscale_auth_key,

		control_url:
			tailscale_control_url,

		hostname:
			tailscale_hostname,

		accept_routes:
			tailscale_accept_routes,

		exit_node:
			tailscale_exit_node,

		exit_node_allow_lan_access:
			!isEmpty(tailscale_exit_node) ?
				tailscale_exit_node_allow_lan_access :
				null,

		advertise_routes:
			length(tailscale_advertise_routes) ?
				tailscale_advertise_routes :
				null,

		advertise_exit_node:
			tailscale_advertise_exit_node,

		listen_port:
			strToInt(tailscale_listen_port)
	});


/* Default outbounds */

config.outbounds = [
	{
		type: 'direct',
		tag: 'direct-out',
		routing_mark: strToInt(self_mark)
	},
	{
		type: 'block',
		tag: 'block-out'
	}
];


/* Main outbounds */

if (!isEmpty(main_node)) {

	let urltest_nodes = [];

	if (main_node === 'urltest') {

		const main_urltest_interval =
			uci.get(uciconfig, ucimain, 'main_urltest_interval');

		const main_urltest_tolerance =
			uci.get(uciconfig, ucimain, 'main_urltest_tolerance');

		push(config.outbounds, {
			type: 'urltest',
			tag: 'main-out',

			outbounds:
				map(main_urltest_nodes, (k) => node_out_tag(k)),

			interval:
				strToTime(main_urltest_interval),

			tolerance:
				strToInt(main_urltest_tolerance),

			idle_timeout:
				(strToInt(main_urltest_interval) > 1800) ?
					`${main_urltest_interval * 2}s` :
					null
		});

		urltest_nodes = main_urltest_nodes;

	} else {

		const main_node_cfg =
			uci.get_all(uciconfig, main_node) || {};

		if (main_node_cfg.type === 'wireguard') {

			push(
				config.endpoints,
				generate_endpoint(main_node_cfg)
			);

			config.endpoints[length(config.endpoints)-1].tag =
				main_out_tag;

		} else {

			push(
				config.outbounds,
				generate_outbound(main_node_cfg)
			);

			config.outbounds[length(config.outbounds)-1].tag =
				main_out_tag;
		}
	}

	for (let i in urltest_nodes) {

		const urltest_node =
			uci.get_all(uciconfig, i) || {};

		if (
			isEmpty(urltest_node.type) ||
			outbound_tag_defined(node_out_tag(i))
		)
			continue;

		if (urltest_node.type === 'wireguard') {

			push(
				config.endpoints,
				generate_endpoint(urltest_node)
			);

			config.endpoints[length(config.endpoints)-1].tag =
				node_out_tag(i);

		} else {

			push(
				config.outbounds,
				generate_outbound(urltest_node)
			);

			config.outbounds[length(config.outbounds)-1].tag =
				node_out_tag(i);
		}
	}
}

/* Outbound end */


/* Application routing helper start */

function rule_set_defined(tag) {
	for (let rs in config.route.rule_set)
		if (rs.tag === tag)
			return true;

	return false;
}

function add_node_outbound(id) {
	if (isEmpty(id) || outbound_tag_defined(node_out_tag(id)))
		return;

	const cfg = uci.get_all(uciconfig, id) || {};

	if (isEmpty(cfg.type))
		return;

	if (cfg.type === 'wireguard')
		push(config.endpoints, generate_endpoint(cfg));
	else
		push(config.outbounds, generate_outbound(cfg));
}

function valid_node_list(list) {
	let nodes = [];

	for (let id in normalizeList(list)) {

		const cfg =
			uci.get_all(uciconfig, id);

		if (
			!isEmpty(id) &&
			type(cfg) === 'object' &&
			!isEmpty(cfg.type) &&
			!(id in nodes)
		)
			push(nodes, id);
	}

	return nodes;
}

function app_rule_label(cfg) {
	if (cfg.source !== 'custom')
		return cfg.source;

	const name =
		trim(cfg.custom_service_name || '') || 'custom';

	return name + '-' + cfg['.name'];
}

/* Resolve the outbound an application rule should use */

function app_rule_outbound(cfg) {

	const node = cfg.node || 'main-out';

	switch (node) {

	case 'main-out':
		return main_out_tag;

	case 'direct-out':
		return 'direct-out';

	case 'reject-out':
		return 'block-out';

	case 'tailscale':
		return tailscale_enabled ?
			tailscale_tag :
			main_out_tag;

	case 'urltest': {

		const nodes =
			valid_node_list(expand_urltest_nodes(cfg.urltest_nodes, cfg.urltest_groups, cfg.urltest_group_limit));

		if (!length(nodes))
			return main_out_tag;

		const tag =
			'app-' + app_rule_label(cfg) + '-out';

		if (!outbound_tag_defined(tag)) {

			push(config.outbounds, {
				type: 'urltest',
				tag,

				outbounds:
					map(nodes, (k) => node_out_tag(k)),

				interval:
					strToTime(cfg.urltest_interval || '120'),

				tolerance:
					strToInt(cfg.urltest_tolerance),

				interrupt_exist_connections:
					strToBool(cfg.urltest_interrupt_exist_connections)
			});
		}

		for (let id in nodes)
			add_node_outbound(id);

		return tag;
	}

	default: {

		const node_cfg =
			uci.get_all(uciconfig, node);

		if (
			type(node_cfg) === 'object' &&
			!isEmpty(node_cfg.type)
		) {
			add_node_outbound(node);
			return node_out_tag(node);
		}

		return main_out_tag;
	}
	}
}

/* Application routing helper end */


/* Routing rules start */

config.route = {

	rules: [
		{
			inbound: 'dns-in',
			action: 'hijack-dns'
		},
		{
			action: 'sniff'
		}
	],

	rule_set: [],

	auto_detect_interface:
		isEmpty(default_interface) ?
			true :
			null,

	default_interface:
		default_interface
};


/*
 * Avoid DNS loop.
 */
config.route.default_domain_resolver = {
	action: 'route',

	server:
		(!isEmpty(main_node) &&
		 routing_mode === 'bypass_mainland_china') ?
			'china-dns' :
			'default-dns',

	strategy:
		(ipv6_support !== '1') ?
			'prefer_ipv4' :
			null
};


/* Tailscale routing */

if (tailscale_enabled) {

	push(config.route.rules, {
		inbound: tailscale_tag,
		action: 'route',
		outbound: 'direct-out'
	});

	push(config.route.rules, {
		preferred_by: tailscale_tag,
		action: 'route',
		outbound: tailscale_tag
	});

	if (isEmpty(main_node))
		config.route.final = 'direct-out';
}


/* Routing rules */

if (!isEmpty(main_node)) {

	/* Direct list */

	if (length(direct_domain_list))
		push(config.route.rules, {
			rule_set: 'direct-domain',
			action: 'route',
			outbound: 'direct-out'
		});

	config.route.final = main_out_tag;


	/* Rule set */

	if (length(direct_domain_list))
		push(config.route.rule_set, {
			type: 'inline',
			tag: 'direct-domain',
			rules: [
				{
					domain_keyword: direct_domain_list
				}
			]
		});


	if (length(proxy_domain_list))
		push(config.route.rule_set, {
			type: 'inline',
			tag: 'proxy-domain',
			rules: [
				{
					domain_keyword: proxy_domain_list
				}
			]
		});


	/* Application based routing rules */

	uci.foreach(uciconfig, uciapprule, (cfg) => {

		if (
			cfg.enabled !== '1' ||
			isEmpty(cfg.source)
		)
			return;

		const outbound =
			app_rule_outbound(cfg);

		const base_tag =
			'app-rule-' + app_rule_label(cfg);

		let domain_tags = [],
		    all_tags = [];


		const add_remote = (tag, format, url) => {

			if (rule_set_defined(tag))
				return;

			push(config.route.rule_set, {
				type: 'remote',
				tag,
				format,
				url,
				download_detour: main_out_tag
			});
		};


		if (cfg.source === 'custom') {

			const mode =
				cfg.custom_mode || 'url_domain';

			if (mode === 'domains') {

				let domains = [];

				for (let d in split(
					trim(cfg.custom_domains || ''),
					/\r?\n/
				)) {

					d = trim(d);

					if (!isEmpty(d))
						push(domains, d);
				}

				if (!length(domains))
					return;

				if (!rule_set_defined(base_tag))
					push(config.route.rule_set, {
						type: 'inline',
						tag: base_tag,
						rules: [
							{
								domain_keyword: domains
							}
						]
					});

				all_tags = [base_tag];

			} else {

				const format =
					(cfg.custom_format === 'source') ?
						'source' :
						'binary';

				let idx = 0;

				if (mode !== 'url_ip')
					for (let url in normalizeList(cfg.custom_url)) {

						if (isEmpty(url))
							continue;

						const tag =
							`${base_tag}-domain-${idx++}`;

						push(domain_tags, tag);
						push(all_tags, tag);

						add_remote(tag, format, url);
					}

				idx = 0;

				if (mode !== 'url_domain')
					for (let url in normalizeList(cfg.custom_url_ip)) {

						if (isEmpty(url))
							continue;

						const tag =
							`${base_tag}-ip-${idx++}`;

						push(all_tags, tag);

						add_remote(tag, format, url);
					}
			}

		} else {

			const urls =
				app_rule_urls[cfg.source];

			if (isEmpty(urls))
				return;

			if (!isEmpty(urls.domain)) {

				const tag =
					base_tag + '-domain';

				push(domain_tags, tag);
				push(all_tags, tag);

				add_remote(
					tag,
					'binary',
					urls.domain
				);
			}

			if (!isEmpty(urls.ip)) {

				const tag =
					base_tag + '-ip';

				push(all_tags, tag);

				add_remote(
					tag,
					'binary',
					urls.ip
				);
			}
		}


		if (!length(all_tags))
			return;


		push(config.route.rules, {
			rule_set: all_tags,
			action: 'route',
			outbound
		});


		/*
		 * Corresponding DNS server.
		 *
		 * No query_type filtering.
		 */
		if (!length(domain_tags))
			return;


		if (outbound === 'block-out') {

			push(config.dns.rules, {
				rule_set: domain_tags,
				action: 'reject'
			});

		} else {

			push(config.dns.rules, {
				rule_set: domain_tags,
				action: 'route',
				server:
					(outbound === 'direct-out') ?
						(
							(routing_mode === 'bypass_mainland_china') ?
								'china-dns' :
								'default-dns'
						) :
						'main-dns'
			});
		}
	});


	/*
	 * Mainland routing rule sets.
	 *
	 * IMPORTANT:
	 *
	 * geoip-cn remains here.
	 * This is ROUTE matching, not DNS response filtering.
	 * Therefore it is valid and is intentionally preserved.
	 */
	if (routing_mode === 'bypass_mainland_china') {

		push(config.route.rule_set, {
			type: 'remote',
			tag: 'geoip-cn',
			format: 'binary',
			url:
				'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/cn.srs',
			download_detour: main_out_tag
		});

		push(config.route.rule_set, {
			type: 'remote',
			tag: 'geosite-cn',
			format: 'binary',
			url:
				'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/cn.srs',
			download_detour: main_out_tag
		});

		push(config.route.rule_set, {
			type: 'remote',
			tag: 'geosite-noncn',
			format: 'binary',
			url:
				'https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/geolocation-!cn.srs',
			download_detour: main_out_tag
		});
	}


	if (isEmpty(config.route.rule_set))
		config.route.rule_set = null;
}

/* Routing rules end */


/*
 * HPCHAIN: make sure every chain (detour) target exists as an outbound,
 * also for targets that are themselves chained.
 */
const tag_to_node = {};
for (let nid, ntag in node_out_tags)
	tag_to_node[ntag] = nid;

for (let round = 0; round < 8; round++) {
	let added = false;

	for (let out in slice(config.outbounds || [])) {
		if (out?.detour && !outbound_tag_defined(out.detour) && tag_to_node[out.detour]) {
			add_node_outbound(tag_to_node[out.detour]);
			added = true;
		}
	}

	if (!added)
		break;
}


/* Normalize empty collections */

if (config.endpoints && isEmpty(config.endpoints))
	config.endpoints = null;

if (config.route.rule_set && isEmpty(config.route.rule_set))
	config.route.rule_set = null;

if (config.dns.rules && isEmpty(config.dns.rules))
	config.dns.rules = null;


/* Experimental start */

/*
 * Persistent DNS cache.
 */
config.experimental = {
	cache_file: {
		enabled: true,
		path: HP_DIR + '/cache/cache.db',
		store_dns: true
	}
};


/* Unified delay measuring */
if (!isEmpty(main_node))
	config.experimental.unified_delay = {
		enabled: true
	};

/* Experimental end */


/* API service */

const api_console_enabled =
	dashboard_enabled ||
	main_node === 'urltest' ||
	tailscale_enabled;

if (api_console_enabled)
	config.services = [
		{
			type: 'api',

			tag: 'api-dashboard',

			listen:
				dashboard_enabled ?
					'::' :
					'127.0.0.1',

			listen_port:
				dashboard_port,

			secret:
				dashboard_secret,

			dashboard:
				dashboard_enabled ? {
					enabled: true,
					path: dashboard_path
				} : null
		}
	];

/* API service end */


/* Write generated configuration */

system('mkdir -p ' + RUN_DIR);

writefile(
	RUN_DIR + '/sing-box-c.json',
	sprintf('%.J\n', removeBlankAttrs(config))
);