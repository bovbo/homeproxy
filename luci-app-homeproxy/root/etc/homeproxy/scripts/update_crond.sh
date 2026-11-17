#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2023 ImmortalWrt.org

SCRIPTS_DIR="/etc/homeproxy/scripts"
LOCK_FILE="/var/lock/homeproxy-subscription-update.lock"

mkdir -p /var/lock

update_resources() {
	for i in "china_ip4" "china_ip6"; do
		"$SCRIPTS_DIR/update_resources.sh" "$i"
	done
}

case "$1" in
	resources)
		update_resources
		;;
	subscription)
		[ "$#" -eq 2 ] || exit 2
		case "$2" in
			*[!0-9a-f]*|'') exit 2 ;;
		esac
		[ "${#2}" -eq 32 ] || exit 2
		exec flock -x "$LOCK_FILE" "$SCRIPTS_DIR/update_subscriptions.uc" --group "$2"
		;;
	subscriptions)
		exec flock -x "$LOCK_FILE" "$SCRIPTS_DIR/update_subscriptions.uc"
		;;
	'')
		update_resources
		exec flock -x "$LOCK_FILE" "$SCRIPTS_DIR/update_subscriptions.uc"
		;;
	*)
		exit 2
		;;
esac
