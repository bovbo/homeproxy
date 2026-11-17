#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2023 ImmortalWrt.org
 */

'use strict';

import { md5 } from 'digest';
import { open } from 'fs';
import { connect } from 'ubus';
import { cursor } from 'uci';

import { urldecode, urlencode } from 'luci.http';

import {
	wGETResult, decodeBase64Str, getTime, isEmpty, parseURL,
	reconcileUrltestNodes, validation, HP_DIR, RUN_DIR
} from 'homeproxy';

/* UCI config start */
const uci = cursor();

const uciconfig = 'homeproxy';
uci.load(uciconfig);

const ucimain = 'config',
      ucinode = 'node',
      ucisubscription = 'subscription';

const allow_insecure = uci.get(uciconfig, ucisubscription, 'allow_insecure') || '0',
      filter_mode = uci.get(uciconfig, ucisubscription, 'filter_nodes') || 'disabled',
      filter_keywords = uci.get(uciconfig, ucisubscription, 'filter_keywords') || [],
      packet_encoding = uci.get(uciconfig, ucisubscription, 'packet_encoding') || 'xudp',
      subscription_urls = uci.get(uciconfig, ucisubscription, 'subscription_url') || [],
      user_agent = uci.get(uciconfig, ucisubscription, 'user_agent'),
      via_proxy = uci.get(uciconfig, ucisubscription, 'update_via_proxy') || '0';

/* UCI config end */

/* String helper start */
function filter_check(name) {
	if (isEmpty(name) || filter_mode === 'disabled' || isEmpty(filter_keywords))
		return false;

	let ret = false;
	for (let i in filter_keywords) {
		const patten = regexp(i);
		if (match(name, patten))
			ret = true;
	}
	if (filter_mode === 'whitelist')
		ret = !ret;

	return ret;
}
/* String helper end */

/* Common var start */
const node_cache = {},
      node_result = [];
let service_was_stopped = false;

const ubus = connect();
const sing_features = ubus.call('luci.homeproxy', 'singbox_get_features', {}) || {};
/* Common var end */

/* Log */
system(`mkdir -p ${RUN_DIR}`);
function log(...args) {
	const logfile = open(`${RUN_DIR}/homeproxy.log`, 'a');
	logfile.write(`${getTime()} [SUBSCRIBE] ${join(' ', args)}\n`);
	logfile.close();
}

function service_action(action) {
	return system([ '/etc/init.d/homeproxy', action ]);
}

function progress(...args) {
	printf('%s [SUBSCRIBE] %s\n', getTime(), join(' ', args));
}

/* Map an XHTTP xmux object onto the xhttp_xmux_* UCI options */
function apply_xmux(config, prefix, xmux) {
	if (!xmux)
		return;

	config[`${prefix}_max_concurrency`] = xmux.maxConcurrency || null;
	config[`${prefix}_max_connections`] = xmux.maxConnections || null;
	config[`${prefix}_c_max_reuse_times`] = xmux.cMaxReuseTimes || null;
	config[`${prefix}_h_max_request_times`] = xmux.hMaxRequestTimes || null;
	config[`${prefix}_h_max_reusable_secs`] = xmux.hMaxReusableSecs || null;
	config[`${prefix}_h_keep_alive_period`] = xmux.hKeepAlivePeriod || null;
}

function decode_base64_safe(str) {
	if (isEmpty(str))
		return null;
	str = trim(str);
	str = replace(str, /[\t\r\n ]+/g, '');
	str = replace(str, /-/g, '+');
	str = replace(str, /_/g, '/');
	if (!match(str, /^[A-Za-z0-9+/]*={0,2}$/) || length(str) % 4 === 1)
		return null;
	const padding_pos = index(str, '=');
	if (padding_pos >= 0 &&
	    (length(str) % 4 !== 0 || !match(substr(str, padding_pos), /^={1,2}$/)))
		return null;
	try { return decodeBase64Str(str); }
	catch (e) { return null; }
}

function decode_ss_base64(str) {
	if (isEmpty(str)) return null;
	str = replace(str, /%3[dD]/g, '=');
	return decode_base64_safe(str);
}

function parse_vmess_json(vmess) {
	if (type(vmess) !== 'object' || vmess.v != '2') return null;
	if (vmess.net === 'kcp') {
		log(sprintf('Skipping unsupported VMess node: %s.', vmess.ps || vmess.add));
		return null;
	}
	if (vmess.net === 'quic' &&
	    ((vmess.type && vmess.type !== 'none') || vmess.path || !sing_features.with_quic)) {
		log(sprintf('Skipping unsupported VMess node: %s.', vmess.ps || vmess.add));
		if (!sing_features.with_quic) log('Please rebuild sing-box with QUIC support!');
		return null;
	}
	const config = {
		label: vmess.ps ? urldecode(vmess.ps) : null,
		type: 'vmess', address: vmess.add, port: vmess.port, uuid: vmess.id,
		vmess_alterid: vmess.aid, vmess_encrypt: vmess.scy || 'auto',
		vmess_global_padding: '1',
		transport: (vmess.net !== 'tcp') ? vmess.net : null,
		tls: (vmess.tls === 'tls') ? '1' : '0',
		tls_sni: vmess.sni || vmess.host,
		tls_alpn: vmess.alpn ? split(vmess.alpn, ',') : null,
		tls_utls: sing_features.with_utls ? vmess.fp : null
	};
	switch (vmess.net) {
	case 'grpc': config.grpc_servicename = vmess.path; break;
	case 'h2':
	case 'tcp':
		if (vmess.net === 'h2' || vmess.type === 'http') {
			config.transport = 'http';
			config.http_host = vmess.host ? split(vmess.host, ',') : null;
			config.http_path = vmess.path;
		}
		break;
	case 'httpupgrade':
		config.httpupgrade_host = vmess.host;
		config.http_path = vmess.path;
		break;
	case 'ws':
		config.ws_host = vmess.host;
		config.ws_path = vmess.path;
		if (config.ws_path && match(config.ws_path, /\?ed=/)) {
			config.websocket_early_data_header = 'Sec-WebSocket-Protocol';
			config.websocket_early_data = split(config.ws_path, '?ed=')[1];
			config.ws_path = split(config.ws_path, '?ed=')[0];
		}
		break;
	}
	return config;
}

function parse_uri(uri) {
	let config, url, params;

	if (type(uri) === 'object') {
		if (uri.nodetype === 'sip008') {
			/* https://shadowsocks.org/guide/sip008.html */
			config = {
				label: uri.remarks,
				type: 'shadowsocks',
				address: uri.server,
				port: uri.server_port,
				shadowsocks_encrypt_method: uri.method,
				password: uri.password,
				shadowsocks_plugin: uri.plugin,
				shadowsocks_plugin_opts: uri.plugin_opts
			};
		} else if (uri.v == '2') {
			config = parse_vmess_json(uri);
		}
	} else if (type(uri) === 'string') {
		const raw_uri = trim(uri);
		if (match(raw_uri, /^\{/)) {
			try {
				const raw_object = json(raw_uri);
				if (type(raw_object) === 'object') return parse_uri(raw_object);
			} catch (e) {}
		}
		uri = split(raw_uri, '://');

		switch (uri[0]) {
		case 'anytls':
			/* https://github.com/anytls/anytls-go/blob/v0.0.8/docs/uri_scheme.md */
			url = parseURL('http://' + uri[1]) || {};
			params = url.searchParams || {};

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'anytls',
				address: url.hostname,
				port: url.port,
				password: urldecode(url.username),
				tls: '1',
				tls_sni: params.sni,
				tls_insecure: (params.insecure === '1') ? '1' : '0'
			};

			break;
		case 'http':
		case 'https':
			url = parseURL('http://' + uri[1]) || {};

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'http',
				address: url.hostname,
				port: url.port,
				username: url.username ? urldecode(url.username) : null,
				password: url.password ? urldecode(url.password) : null,
				tls: (uri[0] === 'https') ? '1' : '0'
			};

			break;
		case 'hysteria':
			/* https://github.com/HyNetwork/hysteria/wiki/URI-Scheme */
			url = parseURL('http://' + uri[1]) || {};
			params = url.searchParams || {};

			if (!sing_features.with_quic || (params.protocol && params.protocol !== 'udp')) {
				log(sprintf('Skipping unsupported %s node: %s.', uri[0], urldecode(url.hash) || url.hostname));
				if (!sing_features.with_quic)
					log(sprintf('Please rebuild sing-box with %s support!', 'QUIC'));

				return null;
			}

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'hysteria',
				address: url.hostname,
				port: url.port,
				hysteria_protocol: params.protocol || 'udp',
				hysteria_auth_type: params.auth ? 'string' : null,
				hysteria_auth_payload: params.auth,
				hysteria_obfs_password: params.obfsParam,
				hysteria_down_mbps: params.downmbps,
				hysteria_up_mbps: params.upmbps,
				tls: '1',
				tls_insecure: (params.insecure in ['true', '1']) ? '1' : '0',
				tls_sni: params.peer,
				tls_alpn: params.alpn
			};

			break;
		case 'hysteria2':
		case 'hy2':
			/* https://v2.hysteria.network/docs/developers/URI-Scheme/ */
			url = parseURL('http://' + uri[1]) || {};
			params = url.searchParams || {};

			if (!sing_features.with_quic) {
				log(sprintf('Skipping unsupported %s node: %s.', uri[0], urldecode(url.hash) || url.hostname));
				log(sprintf('Please rebuild sing-box with %s support!', 'QUIC'));
				return null;
			}

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'hysteria2',
				address: url.hostname,
				port: url.port,
				password: url.username ? (
					urldecode(url.username + (url.password ? (':' + url.password) : ''))
				) : null,
				hysteria_obfs_type: params.obfs,
				hysteria_obfs_password: params['obfs-password'],
				tls: '1',
				tls_insecure: (params.insecure === '1') ? '1' : '0',
				tls_sni: params.sni
			};

			break;
		case 'socks':
		case 'socks4':
		case 'socks4a':
		case 'socks5':
		case 'socks5h':
			url = parseURL('http://' + uri[1]) || {};

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'socks',
				address: url.hostname,
				port: url.port,
				username: url.username ? urldecode(url.username) : null,
				password: url.password ? urldecode(url.password) : null,
				socks_version: (match(uri[0], /4/)) ? '4' : '5'
			};

			break;
		case 'ss':
			/* SS-only Base64 support: URL-safe alphabet, missing padding and %3D. */
			let ss_payload = uri[1];
			const ss_hash_index = index(ss_payload, '#');
			let ss_fragment = '';
			if (ss_hash_index >= 0) {
				ss_fragment = substr(ss_payload, ss_hash_index);
				ss_payload = substr(ss_payload, 0, ss_hash_index);
			}
			/* Legacy format may Base64-encode method:password@host:port as one value. */
			if (!match(ss_payload, /@/)) {
				const ss_legacy = decode_ss_base64(ss_payload);
				if (ss_legacy && match(ss_legacy, /@/)) ss_payload = ss_legacy;
			}
			/* Encode literal Base64 padding so parseURL accepts the userinfo. */
			const ss_at_index = index(ss_payload, '@');
			if (ss_at_index >= 0) {
				const raw_userinfo = substr(ss_payload, 0, ss_at_index);
				ss_payload = replace(raw_userinfo, /=/g, '%3D') + substr(ss_payload, ss_at_index);
			}
			url = parseURL('http://' + ss_payload + ss_fragment) || {};
			let ss_userinfo = [];
			if (url.username && url.password)
				ss_userinfo = [urldecode(url.username), urldecode(url.password)];
			else if (url.username) {
				const decoded_userinfo = decode_ss_base64(urldecode(url.username));
				const separator = decoded_userinfo ? index(decoded_userinfo, ':') : -1;
				if (separator >= 0)
					ss_userinfo = [substr(decoded_userinfo, 0, separator), substr(decoded_userinfo, separator + 1)];
			}
			if (!ss_userinfo[0]) {
				log('Skipping invalid Shadowsocks URI: missing cipher method.');
				return null;
			}
			let ss_plugin, ss_plugin_opts;
			if (url.search && url.searchParams.plugin) {
				const plugin_info = split(url.searchParams.plugin, ';', 2);
				ss_plugin = plugin_info[0];
				if (ss_plugin === 'simple-obfs') ss_plugin = 'obfs-local';
				ss_plugin_opts = plugin_info[1];
			}
			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'shadowsocks', address: url.hostname, port: url.port,
				shadowsocks_encrypt_method: ss_userinfo[0], password: ss_userinfo[1],
				shadowsocks_plugin: ss_plugin, shadowsocks_plugin_opts: ss_plugin_opts
			};
			break;

		case 'trojan':
			/* https://p4gefau1t.github.io/trojan-go/developer/url/ */
			url = parseURL('http://' + uri[1]) || {};
			params = url.searchParams || {};

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'trojan',
				address: url.hostname,
				port: url.port,
				password: urldecode(url.username),
				transport: (params.type !== 'tcp') ? params.type : null,
				tls: '1',
				tls_sni: params.sni
			};
			switch(params.type) {
			case 'grpc':
				config.grpc_servicename = params.serviceName;
				break;
			case 'ws':
				config.ws_host = params.host ? urldecode(params.host) : null;
				config.ws_path = params.path ? urldecode(params.path) : null;
				if (config.ws_path && match(config.ws_path, /\?ed=/)) {
					config.websocket_early_data_header = 'Sec-WebSocket-Protocol';
					config.websocket_early_data = split(config.ws_path, '?ed=')[1];
					config.ws_path = split(config.ws_path, '?ed=')[0];
				}
				break;
			}

			break;
		case 'tuic':
			/* https://github.com/daeuniverse/dae/discussions/182 */
			url = parseURL('http://' + uri[1]) || {};
			params = url.searchParams || {};

			if (!sing_features.with_quic) {
				log(sprintf('Skipping unsupported %s node: %s.', uri[0], urldecode(url.hash) || url.hostname));
				log(sprintf('Please rebuild sing-box with %s support!', 'QUIC'));

				return null;
			}

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'tuic',
				address: url.hostname,
				port: url.port,
				uuid: url.username,
				password: url.password ? urldecode(url.password) : null,
				tuic_congestion_control: params.congestion_control,
				tuic_udp_relay_mode: params.udp_relay_mode,
				tls: '1',
				tls_sni: params.sni,
				tls_alpn: params.alpn ? split(urldecode(params.alpn), ',') : null,
			};

			break;
		case 'vless':
			/* https://github.com/XTLS/Xray-core/discussions/716 */
			url = parseURL('http://' + uri[1]) || {};
			params = url.searchParams || {};

			/* Unsupported protocol */
			if (params.type === 'kcp') {
				log(sprintf('Skipping sunsupported %s node: %s.', uri[0], urldecode(url.hash) || url.hostname));
				return null;
			} else if (params.type === 'quic' && ((params.quicSecurity && params.quicSecurity !== 'none') || !sing_features.with_quic)) {
				log(sprintf('Skipping sunsupported %s node: %s.', uri[0], urldecode(url.hash) || url.hostname));
				if (!sing_features.with_quic)
					log(sprintf('Please rebuild sing-box with %s support!', 'QUIC'));

				return null;
			}

			config = {
				label: url.hash ? urldecode(url.hash) : null,
				type: 'vless',
				address: url.hostname,
				port: url.port,
				uuid: url.username,
				transport: (params.type !== 'tcp') ? params.type : null,
				tls: (params.security in ['tls', 'xtls', 'reality']) ? '1' : '0',
				tls_sni: params.sni,
				tls_alpn: params.alpn ? split(urldecode(params.alpn), ',') : null,
				tls_reality: (params.security === 'reality') ? '1' : '0',
				tls_reality_public_key: params.pbk ? urldecode(params.pbk) : null,
				tls_reality_short_id: params.sid,
				tls_utls: sing_features.with_utls ? params.fp : null,
				vless_flow: (params.security in ['tls', 'reality']) ? params.flow : null
			};
			switch(params.type) {
			case 'grpc':
				config.grpc_servicename = params.serviceName;
				break;
			case 'http':
			case 'tcp':
				if (params.type === 'http' || params.headerType === 'http') {
					config.http_host = params.host ? split(urldecode(params.host), ',') : null;
					config.http_path = params.path ? urldecode(params.path) : null;
				}
				break;
			case 'httpupgrade':
				config.httpupgrade_host = params.host ? urldecode(params.host) : null;
				config.http_path = params.path ? urldecode(params.path) : null;
				break;
			case 'ws':
				config.ws_host = params.host ? urldecode(params.host) : null;
				config.ws_path = params.path ? urldecode(params.path) : null;
				if (config.ws_path && match(config.ws_path, /\?ed=/)) {
					config.websocket_early_data_header = 'Sec-WebSocket-Protocol';
					config.websocket_early_data = split(config.ws_path, '?ed=')[1];
					config.ws_path = split(config.ws_path, '?ed=')[0];
				}
				break;
			case 'xhttp':
			case 'splithttp':
				config.transport = 'xhttp';
				config.xhttp_host = params.host ? urldecode(params.host) : null;
				config.xhttp_path = params.path ? urldecode(params.path) : null;
				config.xhttp_mode = params.mode || null;

				let xhttp_extra = {};
				if (params.extra) {
					try {
						xhttp_extra = json(urldecode(params.extra)) || {};
					} catch (e) {
						xhttp_extra = {};
					}
				}

				config.xhttp_method = xhttp_extra.uplinkHTTPMethod || xhttp_extra.method || params.method || null;
				config.xhttp_domain_strategy = xhttp_extra.domainStrategy || params.domainStrategy || null;
				config.xhttp_congestion_controller = xhttp_extra.congestionController || params.congestionController || null;
				config.xhttp_cwnd = xhttp_extra.cwnd || params.cwnd || null;
				if (xhttp_extra.headers) {
					config.xhttp_headers = [];
					for (let k, v in xhttp_extra.headers)
						push(config.xhttp_headers, sprintf('%s: %s', k, v));
				}

				config.xhttp_padding_bytes = xhttp_extra.xPaddingBytes || params.paddingBytes || null;
				config.xhttp_no_grpc_header = (xhttp_extra.noGRPCHeader === true || params.noGRPCHeader === '1') ? '1' : null;
				config.xhttp_sc_max_each_post_bytes = xhttp_extra.scMaxEachPostBytes || params.scMaxEachPostBytes || null;
				config.xhttp_sc_min_posts_interval_ms = xhttp_extra.scMinPostsIntervalMs || params.scMinPostsIntervalMs || null;

				config.xhttp_x_padding_obfs_mode = (xhttp_extra.xPaddingObfsMode === true) ? '1' : null;
				config.xhttp_x_padding_placement = xhttp_extra.xPaddingPlacement || null;
				config.xhttp_x_padding_key = xhttp_extra.xPaddingKey || null;
				config.xhttp_x_padding_header = xhttp_extra.xPaddingHeader || null;
				config.xhttp_x_padding_method = xhttp_extra.xPaddingMethod || null;

				config.xhttp_session_placement = xhttp_extra.sessionPlacement || null;
				config.xhttp_session_key = xhttp_extra.sessionKey || null;
				config.xhttp_session_id_table = xhttp_extra.sessionIdTable || null;
				config.xhttp_session_id_length = xhttp_extra.sessionIdLength || null;

				config.xhttp_seq_placement = xhttp_extra.seqPlacement || null;
				config.xhttp_seq_key = xhttp_extra.seqKey || null;

				config.xhttp_uplink_data_placement = xhttp_extra.uplinkDataPlacement || null;
				config.xhttp_uplink_data_key = xhttp_extra.uplinkDataKey || null;
				config.xhttp_uplink_chunk_size = xhttp_extra.uplinkChunkSize || null;

				if (xhttp_extra.downloadSettings || xhttp_extra.download) {
					let dl = xhttp_extra.downloadSettings || xhttp_extra.download;
					config.xhttp_download_host = dl.host || null;
					config.xhttp_download_path = dl.path || null;
					config.xhttp_download_server = dl.address || dl.server || null;
					config.xhttp_download_server_port = dl.port || dl.server_port || null;
					config.xhttp_download_domain_strategy = dl.domainStrategy || null;
					config.xhttp_download_padding_bytes = dl.xPaddingBytes || null;
					config.xhttp_download_method = dl.uplinkHTTPMethod || dl.method || null;
					config.xhttp_download_congestion_controller = dl.congestionController || null;
					config.xhttp_download_cwnd = dl.cwnd || null;
					config.xhttp_download_no_grpc_header = (dl.noGRPCHeader === true) ? '1' : null;
					if (dl.headers) {
						config.xhttp_download_headers = [];
						for (let k, v in dl.headers)
							push(config.xhttp_download_headers, sprintf('%s: %s', k, v));
					}
					config.xhttp_download_x_padding_obfs_mode = (dl.xPaddingObfsMode === true) ? '1' : null;
					config.xhttp_download_x_padding_placement = dl.xPaddingPlacement || null;
					config.xhttp_download_x_padding_key = dl.xPaddingKey || null;
					config.xhttp_download_x_padding_header = dl.xPaddingHeader || null;
					config.xhttp_download_x_padding_method = dl.xPaddingMethod || null;
					config.xhttp_download_session_placement = dl.sessionPlacement || null;
					config.xhttp_download_session_key = dl.sessionKey || null;
					config.xhttp_download_seq_placement = dl.seqPlacement || null;
					config.xhttp_download_seq_key = dl.seqKey || null;
					config.xhttp_download_uplink_data_placement = dl.uplinkDataPlacement || null;
					config.xhttp_download_uplink_data_key = dl.uplinkDataKey || null;
					config.xhttp_download_uplink_chunk_size = dl.uplinkChunkSize || null;
					if (dl.xmux)
						apply_xmux(config, 'xhttp_download_xmux', dl.xmux);
				}

				if (xhttp_extra.xmux)
					apply_xmux(config, 'xhttp_xmux', xhttp_extra.xmux);

				break;
			}

			break;
		case 'vmess':
			/* Accept plain JSON or standard Base64 JSON after vmess://. */
			const vmess_parts = split(uri[1], '#', 2);
			const vmess_payload = vmess_parts[0];
			let vmess_data = null;
			try { vmess_data = json(vmess_payload); }
			catch (e) {
				const decoded_vmess = decode_base64_safe(vmess_payload);
				if (decoded_vmess) {
					try { vmess_data = json(decoded_vmess); }
					catch (decode_error) { vmess_data = null; }
				}
			}
			config = parse_vmess_json(vmess_data);
			if (!config) {
				log('Skipping unsupported VMess JSON/URI format.');
				return null;
			}
			if (!config.label && length(vmess_parts) > 1)
				config.label = urldecode(vmess_parts[1]);
			break;
		}
	}

	if (!isEmpty(config)) {
		if (config.address)
			config.address = replace(config.address, /\[|\]/g, '');

		if (!validation('host', config.address) || !validation('port', config.port)) {
			log(sprintf('Skipping invalid %s node: %s.', config.type, config.label || 'NULL'));
			return null;
		} else if (!config.label)
			config.label = (validation('ip6addr', config.address) ?
				`[${config.address}]` : config.address) + ':' + config.port;
	}

	return config;
}

function main() {
	let failed_subscriptions = 0;

	if (via_proxy !== '1') {
		log('Stopping service...');
		service_action('stop');
		service_was_stopped = true;
	}

	for (let sub_index = 0; sub_index < length(subscription_urls); sub_index++) {
		let url = replace(subscription_urls[sub_index], /#.*$/, '');
		const groupHash = md5(url);
		node_cache[groupHash] = {};

		progress(sprintf('Fetching subscription %d/%d...', sub_index + 1, length(subscription_urls)));

		const fetchResult = wGETResult(url, user_agent);
		if (isEmpty(fetchResult.content)) {
			failed_subscriptions++;
			log(sprintf('Failed to fetch resources from %s: %s.', url, fetchResult.error || 'unknown error'));
			progress(sprintf('Fetch failed for subscription %d: %s', sub_index + 1, fetchResult.error || 'unknown error'));
			continue;
		}

		const res = fetchResult.content;
		let parsed = null, is_json = false, body = res, nodes = null;

		try {
			parsed = json(body);
			is_json = true;
		} catch(e) {
			is_json = false;
		}

		if (!is_json) {
			const decoded = decode_base64_safe(res);

			if (decoded) {
				body = decoded;
				try {
					parsed = json(body);
					is_json = true;
				} catch(e) {
					is_json = false;
				}
			}
		}

		if (is_json) {
			if (type(parsed) === 'array')
				nodes = parsed;
			else if (type(parsed) === 'object' && type(parsed.servers) === 'array')
				nodes = parsed.servers;
			else if (type(parsed) === 'object' && parsed.v == '2')
				nodes = [ parsed ];
			else {
				failed_subscriptions++;
				log(sprintf('Unsupported JSON subscription structure from %s.', url));
				progress(sprintf('Unsupported JSON subscription format at subscription %d.', sub_index + 1));
				continue;
			}
		}
		else {
			/* Decode URI lists only when the result looks like a real URI payload. */
			const decoded = decode_base64_safe(res);
			if (decoded && (
				match(decoded, /[a-z][a-z0-9+.-]*:\/\//i) ||
				match(decoded, /^[[:space:]]*(proxies|proxy-providers)[[:space:]]*:/)
			))
				body = decoded;

			body = replace(body, /\r/g, '');

			if (match(body, /^[[:space:]]*(proxies|proxy-providers)[[:space:]]*:/)) {
				failed_subscriptions++;
				log(sprintf('Unsupported Clash/Mihomo YAML subscription from %s; use a URI list or SIP008 JSON feed.', url));
				progress(sprintf('Unsupported YAML subscription format at subscription %d.', sub_index + 1));
				continue;
			}

			nodes = split(trim(body), '\n');
		}

		if (type(nodes) !== 'array') {
			failed_subscriptions++;
			log(sprintf('Invalid subscription payload from %s.', url));
			progress(sprintf('Invalid subscription payload at subscription %d.', sub_index + 1));
			continue;
		}

		/* Shadowsocks SIP008 format; guard empty arrays and non-object entries. */
		if (length(nodes) && type(nodes[0]) === 'object' && nodes[0].server && nodes[0].method)
			map(nodes, (_, i) => nodes[i].nodetype = 'sip008');

		let count = 0;
		for (let node in nodes) {
			let config;
			if (!isEmpty(node))
				config = parse_uri(node);
			if (isEmpty(config))
				continue;

			if (config.tls === '1') {
				if (isEmpty(config.tls_min_version)) config.tls_min_version = '1.2';
				if (isEmpty(config.tls_max_version)) config.tls_max_version = '1.3';
			}

			const label = config.label;
			config.label = null;
			const confHash = md5(sprintf('%J', config)),
			      nameHash = md5(label);
			config.label = label;

			if (filter_check(config.label))
				log(sprintf('Skipping blacklist node: %s.', config.label));
			else if (node_cache[groupHash][confHash] || node_cache[groupHash][nameHash])
				log(sprintf('Skipping duplicate node: %s.', config.label));
			else {
				if (config.tls === '1' && allow_insecure === '1')
					config.tls_insecure = '1';
				if (config.type in ['vless', 'vmess'])
					config.packet_encoding = packet_encoding;

				config.grouphash = groupHash;
				push(node_result, []);
				push(node_result[length(node_result)-1], config);
				node_cache[groupHash][confHash] = config;
				node_cache[groupHash][nameHash] = config;

				count++;
			}
		}

		if (count == 0) {
			failed_subscriptions++;
			log(sprintf('No valid node found in %s.', url));
			progress(sprintf('No valid nodes in subscription %d; its existing nodes will be kept.', sub_index + 1));
		}
		else {
			log(sprintf('Successfully fetched %s nodes of total %s from %s.', count, length(nodes), url));
			progress(sprintf('Subscription %d: parsed %s nodes.', sub_index + 1, count));
		}
	}

	if (isEmpty(node_result)) {
		log('Failed to update subscriptions: no valid node found.');
		progress('FAILED: no valid node was parsed; existing subscription nodes were left unchanged.');

		if (service_was_stopped) {
			log('Starting service...');
			const start_status = service_action('start');
			service_was_stopped = (start_status !== 0);

			if (service_was_stopped) {
				log(sprintf('Failed to restore HomeProxy after an unsuccessful subscription update (status %s).', start_status));
				progress(sprintf('WARNING: HomeProxy start returned status %s after the subscription failure.', start_status));
			}
		}

		return false;
	}

	let added = 0, removed = 0;
	uci.foreach(uciconfig, ucinode, (cfg) => {
		/* Nodes created by the user */
		if (!cfg.grouphash)
			return null;

		/* A configured subscription that failed to fetch/parse keeps its
		 * existing nodes. A hash absent from the current URL list was removed
		 * by the user and its orphaned nodes must be deleted. */
		if (cfg.grouphash in node_cache && length(node_cache[cfg.grouphash]) === 0)
			return null;

		if (!(cfg.grouphash in node_cache) || !node_cache[cfg.grouphash][cfg['.name']]) {
			uci.delete(uciconfig, cfg['.name']);
			removed++;

			log(sprintf('Removing node: %s.', cfg.label || cfg['name']));
		} else {
			const refreshedNode = node_cache[cfg.grouphash][cfg['.name']];
			if (refreshedNode.tls === '1') {
				if (!isEmpty(cfg.tls_min_version)) refreshedNode.tls_min_version = cfg.tls_min_version;
				if (!isEmpty(cfg.tls_max_version)) refreshedNode.tls_max_version = cfg.tls_max_version;
			}
			map(keys(cfg), (v) => {
				if (v in refreshedNode)
					uci.set(uciconfig, cfg['.name'], v, refreshedNode[v]);
				else
					uci.delete(uciconfig, cfg['.name'], v);
			});
			if (refreshedNode.tls === '1') {
				if (isEmpty(cfg.tls_min_version))
					uci.set(uciconfig, cfg['.name'], 'tls_min_version', '1.2');
				if (isEmpty(cfg.tls_max_version))
					uci.set(uciconfig, cfg['.name'], 'tls_max_version', '1.3');
			}
			refreshedNode.isExisting = true;
		}
	});
	for (let nodes in node_result)
		map(nodes, (node) => {
			if (node.isExisting)
				return null;

			const nameHash = md5(node.label);
			uci.set(uciconfig, nameHash, 'node');
			map(keys(node), (v) => uci.set(uciconfig, nameHash, v, node[v]));

			added++;
			log(sprintf('Adding node: %s.', node.label));
		});
	uci.commit(uciconfig);

	let need_restart = (via_proxy !== '1');

	/* Drop references to nodes that disappeared with this update: the URLTest
	   lists of the main node and of the routing rules, and stale main nodes. */
	const reconcile = reconcileUrltestNodes(uci, uciconfig, log);

	if (reconcile.changed) {
		uci.commit(uciconfig);
		need_restart = true;
	}

	if (need_restart) {
		log('Restarting service...');
		service_action('stop');
		const start_status = service_action('start');

		if (start_status !== 0) {
			service_was_stopped = true;
			log(sprintf('Failed to start HomeProxy after subscription update (status %s).', start_status));
			progress(sprintf('FAILED: HomeProxy did not start successfully (status %s).', start_status));
			return false;
		}

		service_was_stopped = false;
	}

	log(sprintf('%s nodes added, %s removed.', added, removed));
	log('Successfully updated subscriptions.');

	if (failed_subscriptions)
		progress(sprintf('WARNING: %s subscription(s) failed or contained no valid nodes; their existing nodes were kept.', failed_subscriptions));
	else
		progress(sprintf('COMPLETE: %s nodes added, %s removed.', added, removed));

	return { success: true, failed: failed_subscriptions, added, removed };
}

if (isEmpty(subscription_urls)) {
	log('No subscription URL configured; skipping subscription update.');
	progress('SKIPPED: no subscription URL configured.');
	exit(0);
}

try {
	const result = call(main);

	if (!result || result.success !== true) {
		if (service_was_stopped) {
			log('Retrying HomeProxy start after an unsuccessful update...');
			const retry_status = service_action('start');
			service_was_stopped = (retry_status !== 0);

			if (service_was_stopped)
				log(sprintf('HomeProxy start retry failed (status %s).', retry_status));
		}

		progress('FAILED: subscription update did not complete.');
		exit(1);
	}
} catch(e) {
	log('[FATAL ERROR] An error occurred during updating subscriptions:');
	log(sprintf('%s: %s', e.type || 'Error', e.message || e));

	if (e.stacktrace && length(e.stacktrace))
		log(e.stacktrace[0].context || '');

	progress(sprintf('FAILED: %s', e.message || e));

	if (service_was_stopped) {
		log('Starting service after failed update...');
		const restore_status = service_action('start');
		service_was_stopped = (restore_status !== 0);

		if (service_was_stopped)
			log(sprintf('HomeProxy restore attempt failed (status %s).', restore_status));
	}

	exit(1);
}
