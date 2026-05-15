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

exec /usr/sbin/sshd -D -e -o "LogLevel=${SSHD_LOG_LEVEL:-INFO}"