# shellwatch-demo-server

A minimal Alpine-based SSH server that hosts non-interactive ASCII payloads under `ForceCommand`. Designed to be auto-attached as an onboarding endpoint by [ShellWatch](https://github.com/rado0x54/ShellWatch) so new users have something to connect to immediately after passkey registration.

## What it is

- Single container, single open port (22).
- One Linux user per demo (`sw-snake`, `sw-matrix`, `sw-sudoku`, `sw-2048`).
- Each user's session runs **one** command and exits — no shell, no arbitrary execution.
- Authorized keys come from one of two sources, selected at runtime: a bind-mounted per-user file or a live HTTP lookup against ShellWatch. See [Key delivery](#key-delivery).

## Principals

| User | Payload |
|---|---|
| `sw-snake` | `snake` (from `bsd-games`) |
| `sw-matrix` | `cmatrix -s -u 5` (any key exits) |
| `sw-sudoku` | `nudoku` (built from source, `--without-cairo`) |
| `sw-2048` | `2048` (built from source — [mevdschee/2048.c](https://github.com/mevdschee/2048.c)) |

Each payload is wrapped in `timeout 600` so a wedged client cannot pin a session. Turn-based payloads like `nudoku` are the agent-friendly headline — they compose well with the audit-log/HITL story. Real-time payloads (`snake`, `cmatrix`) stay for quick visual smoke tests of the SSH path; `ninvaders` and `bastet` were dropped early on for being too action-heavy.

## Authentication

Pubkey-only. The sshd is explicitly configured to accept ShellWatch's headline credential:

- `webauthn-sk-ecdsa-sha2-nistp256@openssh.com` — the rpID-validated WebAuthn-anchored sk key (the credential a ShellWatch user actually carries on their passkey).
- `webauthn-sk-ecdsa-sha2-nistp256-cert-v01@openssh.com` — the certificate variant. Enabled today; will start validating once `TrustedUserCAKeys` is pointed at a ShellWatch CA pubkey (see commented line in `sshd_config`). Tracks ShellWatch [#209](https://github.com/rado0x54/ShellWatch/issues/209).

OpenSSH's other default pubkey algorithms remain enabled (`ssh-ed25519`, `ecdsa-sha2-nistp256`, etc.) — useful for testing with a regular keypair before passkey integration is wired up end-to-end.

## Key delivery

sshd resolves authorized keys through an `AuthorizedKeysCommand` helper (`/usr/local/lib/demo/auth-keys.sh`) rather than a static `AuthorizedKeysFile`. The helper picks its mode from one env var:

| `SHELLWATCH_KEYS_URL` | Mode | What the helper does |
|---|---|---|
| unset | **File** | `cat /var/lib/demo/keys/<user>` — same shape as before; bind-mount the directory from ShellWatch or supply it locally. |
| set | **Endpoint** | `GET $SHELLWATCH_KEYS_URL?user=<u>&type=<t>&fingerprint=<f>` against ShellWatch on every offered key. |

`SHELLWATCH_KEYS_TIMEOUT` (seconds, default `4`) caps each HTTP call via `curl --max-time` — OpenSSH itself doesn't ship a directive for this, so the script enforces it.

`AuthorizedKeysFile` is set to `none` so the helper is the *only* key source. Without that, sshd would also probe each user's default `~/.ssh/authorized_keys` first — wasted work in this image where demo users have no home dir.

### Endpoint contract

```
GET /demo/authorized-keys?user=sw-matrix&type=ssh-ed25519&fingerprint=SHA256:abc123…
→ 200 text/plain
ssh-ed25519 AAAAC3Nz... matching-key-comment
```

- One key per line, OpenSSH `authorized_keys` format (per-key `options` prefix permitted).
- 200 + empty body → no match → sshd denies cleanly (no error log).
- Anything non-2xx (404, 5xx, timeout) → curl exits non-zero → sshd logs `AuthorizedKeysCommand … failed` and denies.
- `fingerprint` is the full `SHA256:<base64>` form sshd already computes; index on it directly.

The helper passes the fingerprint of the *specific key being offered*, so the endpoint should answer with just the matching key, not the user's full keyring. That keeps payloads small and lets ShellWatch log "user X attempted auth as sw-matrix with fingerprint Y at T" trivially.

### Request volume per SSH connection

SSH pubkey auth is two-phase: clients first *offer* a public key, sshd answers yes/no, and only then does the client sign. Each phase invokes `AuthorizedKeysCommand` independently (stock OpenSSH has no in-process cache between them). So a client offering N keys where the Kth one works produces **K offer-phase calls + 1 prove-phase call** to the endpoint. Mitigations:

- **Client side:** `IdentitiesOnly yes` + a single `IdentityFile` collapses this to two calls. Worth recommending to demo users with full ssh-agents.
- **Endpoint side:** short-TTL cache in ShellWatch keyed on `(user, fingerprint)` — the prove-phase call hits cache.
- **Server side:** `MaxAuthTries 3` (sshd default 6 — consider lowering) bounds the worst case from a misbehaving client.

### File-mode permissions note

In file mode the helper runs as `nobody` (via `AuthorizedKeysCommandUser`), not as the target user, so per-user key files need to be world-readable (`0644`). The image bakes this in; if you bind-mount a host file in its place, make sure it's `chmod 0644` or owned by a UID `nobody` can read. Previously sshd opened the file itself as the target user, which is why the config used to carry `StrictModes no` — that workaround is now gone.

## Local development

The repo's `docker-compose.yml` is wired so every demo principal reads from the same `./authorized_keys` file (gitignored) — one pubkey works for all principals.

```sh
# 1. Create authorized_keys with your OpenSSH public key.
#    Do this before `docker compose up` so Docker doesn't auto-create
#    the path as an empty directory.
echo "ssh-ed25519 AAAA... your-comment" > authorized_keys

# 2. Build and start.
docker compose up --build

# 3. Connect to any principal on localhost:2222 (2222 avoids
#    clashing with the host's own sshd):
ssh -p 2222 -i ~/.ssh/your_key sw-sudoku@localhost
ssh -p 2222 -i ~/.ssh/your_key sw-matrix@localhost
ssh -p 2222 -i ~/.ssh/your_key sw-snake@localhost
ssh -p 2222 -i ~/.ssh/your_key sw-2048@localhost
```

Host keys are persisted in the `shellwatch-demo-host-keys` named volume, so subsequent `docker compose up` runs don't trigger fingerprint-change warnings on your client. In production every principal has its own `authorized_keys` file populated by ShellWatch — the all-principals-share-one-file pattern here is a local-dev convenience only.

## Run standalone

```sh
docker run -d \
  --name shellwatch-demo \
  -p 22:22 \
  -v /your/path/demo-keys:/var/lib/demo/keys:ro \
  -v shellwatch-demo-host-keys:/var/lib/demo/host-keys \
  --memory=256m --cpus=0.5 --pids-limit=200 \
  --read-only --tmpfs /tmp:size=10m,mode=1777 \
  ghcr.io/rado0x54/shellwatch-demo-server:latest
```

- `/var/lib/demo/keys` (read-only mount, **file mode only**): one file per principal containing OpenSSH-format public keys, one per line, mode `0644`. Populated by ShellWatch's `authorizedKeyFile` key-delivery mechanism. Omit the mount entirely when running in endpoint mode (`SHELLWATCH_KEYS_URL` set).
- `/var/lib/demo/host-keys` (named volume): persists SSH host keys across container restarts so clients don't see fingerprint changes. The rest of `/etc/ssh` (including `sshd_config`) lives in the image and is never shadowed — config changes always take effect on rebuild.

To run in endpoint mode instead, drop the `/var/lib/demo/keys` mount and pass `-e SHELLWATCH_KEYS_URL=https://shellwatch.example/demo/authorized-keys`.

## Run alongside ShellWatch (docker compose)

### File mode — shared volume

```yaml
services:
  shellwatch:
    image: ghcr.io/rado0x54/shellwatch:latest
    volumes:
      - demo-keys:/var/lib/shellwatch/demo-keys      # ShellWatch writes here

  shellwatch-demo:
    image: ghcr.io/rado0x54/shellwatch-demo-server:latest
    ports:
      - "22:22"
    volumes:
      - demo-keys:/var/lib/demo/keys:ro              # sshd reads here
      - demo-ssh-host-keys:/var/lib/demo/host-keys   # only host keys persist; sshd_config stays in image
    restart: unless-stopped
    mem_limit: 256m
    pids_limit: 200
    read_only: true
    tmpfs:
      - /tmp:size=10m,mode=1777

volumes:
  demo-keys:
  demo-ssh-host-keys:
```

ShellWatch's `onboardingEndpoints` config writes per-principal authorized-keys files to `/var/lib/shellwatch/demo-keys/<principal>`; the demo container reads the same volume read-only at `/var/lib/demo/keys/<principal>`. sshd re-reads each file on every connection — no signal or restart needed.

### Endpoint mode — live HTTP lookup

```yaml
services:
  shellwatch:
    image: ghcr.io/rado0x54/shellwatch:latest
    # ShellWatch exposes GET /demo/authorized-keys?user=&type=&fingerprint=
    # to the demo server on the internal network.

  shellwatch-demo:
    image: ghcr.io/rado0x54/shellwatch-demo-server:latest
    ports:
      - "22:22"
    environment:
      SHELLWATCH_KEYS_URL: "http://shellwatch:8080/demo/authorized-keys"
      # SHELLWATCH_KEYS_TIMEOUT: "4"
    volumes:
      - demo-ssh-host-keys:/var/lib/demo/host-keys
    restart: unless-stopped
    mem_limit: 256m
    pids_limit: 200
    read_only: true
    tmpfs:
      - /tmp:size=10m,mode=1777

volumes:
  demo-ssh-host-keys:
```

No shared volume needed — the demo server asks ShellWatch on every offered key. Removes the file-sync coupling, at the cost of putting ShellWatch on the SSH critical path. See [Key delivery](#key-delivery) for the endpoint contract and the per-connection request volume.

## Hardening defaults baked in

- No password auth, root login disabled, pubkey-only.
- Per-user `ForceCommand` — no interactive shell.
- TCP, agent, X11, and tunnel forwarding all disabled.
- `PermitUserRC no`, `PermitUserEnvironment no`.
- `timeout 600` wall-clock cap per payload.
- `MaxStartups 10:30:60` + `LoginGraceTime 10` to blunt connect storms.
- Read-only rootfs and ephemeral tmpfs for `/tmp` are expected at runtime (set them in your compose/run command).

## Releases

Releases run via the **Release** workflow's `workflow_dispatch` trigger from `main`:

1. Actions → Release → Run workflow.
2. Enter the version as `X.Y.Z` (no `v` prefix — the `v` is added automatically).
3. The workflow validates the version (format, monotonic vs previous tag, no existing tag/release), builds the image, pushes it to GHCR, then tags the commit and creates the GitHub Release. Tagging happens after a successful push, so failed builds leave no orphan tags.

Each successful release publishes:

- `ghcr.io/rado0x54/shellwatch-demo-server:vX.Y.Z`
- `ghcr.io/rado0x54/shellwatch-demo-server:latest`
- `ghcr.io/rado0x54/shellwatch-demo-server:sha-<short>`

## License

MIT — see `LICENSE`.
