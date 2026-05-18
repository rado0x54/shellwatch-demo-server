#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

HOST_KEY_DIR=/var/lib/demo/host-keys
mkdir -p "$HOST_KEY_DIR"

# Generate any missing host keys. Persists across restarts when
# $HOST_KEY_DIR is volume-mounted; regenerates every boot otherwise.
for type in ed25519 rsa ecdsa; do
    keyfile="$HOST_KEY_DIR/ssh_host_${type}_key"
    if [ ! -f "$keyfile" ]; then
        ssh-keygen -q -t "$type" -f "$keyfile" -N "" -C ""
    fi
done

# sshd's AuthorizedKeysCommand runs in a scrubbed environment, so docker
# `-e` values don't reach auth-keys.sh directly. Snapshot the runtime
# config into a file the script can source. Single-quoted to make sure
# special chars in values can't get interpreted at source time.
cat > /var/lib/demo/auth-keys.conf <<EOF
AUTH_KEYS_ANY='${AUTH_KEYS_ANY:-}'
AUTH_KEYS_URL='${AUTH_KEYS_URL:-}'
AUTH_KEYS_TIMEOUT='${AUTH_KEYS_TIMEOUT:-4}'
EOF
chmod 0644 /var/lib/demo/auth-keys.conf

exec /usr/sbin/sshd -D -e -o "LogLevel=${SSHD_LOG_LEVEL:-INFO}"