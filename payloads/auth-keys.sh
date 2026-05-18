#!/bin/sh
# SPDX-License-Identifier: MIT
# AuthorizedKeysCommand helper. sshd invokes this once per offered key
# (and again per key that ends up signing). Args come from sshd token
# expansion in sshd_config: %u %t %f %k.
#
# Modes, evaluated in order — first match wins:
#
#   AUTH_KEYS_ANY=true   Blanket-approve: echo the offered key back so
#                        sshd verifies the signature against it. The
#                        normal SSH handshake (challenge + signature)
#                        still runs; the server just doesn't gate on
#                        *which* keypair the client used.
#
#   AUTH_KEYS_URL=<url>  Endpoint mode: HTTP GET against the URL with
#                        ?user=&type=&fingerprint=, emit the body.
#                        AUTH_KEYS_TIMEOUT (seconds, default 2) caps
#                        each request via curl --max-time.
#
#   (neither set)        File mode: cat /var/lib/demo/keys/<user>.
#
# sshd runs this as AuthorizedKeysCommandUser (nobody) — keep file-mode
# key files world-readable (0644) so the fallback path works.
#
# sshd scrubs the parent environment when invoking AuthorizedKeysCommand,
# so docker `-e` values don't reach us. entrypoint.sh snapshots them
# into /tmp/auth-keys.conf at container start; source it here.
set -eu

[ -r /tmp/auth-keys.conf ] && . /tmp/auth-keys.conf

user="$1"
keytype="$2"
fingerprint="$3"
keyblob="$4"

case "${AUTH_KEYS_ANY:-}" in
    true|TRUE|1|yes|YES)
        echo "${keytype} ${keyblob}"
        exit 0
        ;;
esac

if [ -n "${AUTH_KEYS_URL:-}" ]; then
    exec curl -fsS --max-time "${AUTH_KEYS_TIMEOUT:-2}" \
        --get \
        --data-urlencode "user=${user}" \
        --data-urlencode "type=${keytype}" \
        --data-urlencode "fingerprint=${fingerprint}" \
        "${AUTH_KEYS_URL}"
fi

keyfile="/var/lib/demo/keys/${user}"
[ -r "$keyfile" ] && exec cat "$keyfile"

# Fall-through: no mode matched, or file-mode keyfile missing. Exit clean
# so sshd treats it as "no authorized keys" (deny without "command
# failed" noise in the log) — matches endpoint-mode 200+empty.
exit 0
