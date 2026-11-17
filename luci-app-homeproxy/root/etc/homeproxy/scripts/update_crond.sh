#!/bin/sh

SCRIPTS_DIR="/etc/homeproxy/scripts"
RUN_DIR="/var/run/homeproxy"
mkdir -p "$RUN_DIR"
exec 200>"$RUN_DIR/update_crond.lock"
# Multiple subscription updates queue here, rather than being dropped.
flock 200 || exit 0

# No arguments = all subscriptions; one or more arguments = selected subscription MD5 hashes.
"$SCRIPTS_DIR"/update_subscriptions.uc "$@"
