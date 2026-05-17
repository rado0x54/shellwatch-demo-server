#!/bin/sh
# SPDX-License-Identifier: MIT
# AuthorizedKeysCommand helper. sshd invokes this once per offered key
# (and again per key that ends up signing). Args come from sshd token
# expansion in sshd_config: %u %t %f.
#
#   SHELLWATCH_KEYS_URL set  -> query the endpoint with (user, type,
#                               fingerprint) and emit the matching key.
#   SHELLWATCH_KEYS_URL unset -> fall back to /var/lib/demo/keys/<user>,
#                               the legacy bind-mount mode.
#
# sshd runs this as AuthorizedKeysCommandUser (nobody) — keep file-mode
# key files world-readable (0644) so the fallback path works.
set -eu

user="$1"
keytype="$2"
fingerprint="$3"

if [ -n "${SHELLWATCH_KEYS_URL:-}" ]; then
    exec curl -fsS --max-time "${SHELLWATCH_KEYS_TIMEOUT:-4}" \
        --get \
        --data-urlencode "user=${user}" \
        --data-urlencode "type=${keytype}" \
        --data-urlencode "fingerprint=${fingerprint}" \
        "${SHELLWATCH_KEYS_URL}"
fi

keyfile="/var/lib/demo/keys/${user}"
[ -r "$keyfile" ] && exec cat "$keyfile"