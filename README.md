# shellwatch-demo-server

A minimal Alpine-based SSH server that hosts non-interactive ASCII payloads under `ForceCommand`. Designed to be auto-attached as an onboarding endpoint by [ShellWatch](https://github.com/rado0x54/ShellWatch) so new users have something to connect to immediately after passkey registration.

## What it is

- Single container, single open port (22).
- One Linux user per demo (`sw-matrix`, `sw-sudoku`).
- Each user's session runs **one** command and exits — no shell, no arbitrary execution.
- Authorized keys live in `/var/lib/demo/keys/%u` and are read at login time; mount this directory from your ShellWatch deployment to populate it dynamically.

## Principals

| User | Payload |
|---|---|
| `sw-matrix` | `cmatrix -s -u 5` (any key exits) |
| `sw-sudoku` | `nudoku` (built from source, `--without-cairo`) |

Each payload is wrapped in `timeout 600` so a wedged client cannot pin a session. Real-time arcade payloads (`ninvaders`, `bastet`, `nsnake`) were dropped early on because they don't compose well with the agent-driven demo use case ShellWatch is built around — turn-based payloads like `nudoku` are easier to reason about, observe in an audit log, and have an agent participate in.

## Authentication

Pubkey-only. The sshd is explicitly configured to accept ShellWatch's headline credential:

- `webauthn-sk-ecdsa-sha2-nistp256@openssh.com` — the rpID-validated WebAuthn-anchored sk key (the credential a ShellWatch user actually carries on their passkey).
- `webauthn-sk-ecdsa-sha2-nistp256-cert-v01@openssh.com` — the certificate variant. Enabled today; will start validating once `TrustedUserCAKeys` is pointed at a ShellWatch CA pubkey (see commented line in `sshd_config`). Tracks ShellWatch [#209](https://github.com/rado0x54/ShellWatch/issues/209).

OpenSSH's other default pubkey algorithms remain enabled (`ssh-ed25519`, `ecdsa-sha2-nistp256`, etc.) — useful for testing with a regular keypair before passkey integration is wired up end-to-end.

## Local development

The repo's `docker-compose.yml` is wired so every demo principal reads from the same `./authorized_keys` file (gitignored) — one pubkey works for all principals.

```sh
# 1. Create authorized_keys with your OpenSSH public key.
#    Do this before `docker compose up` so Docker doesn't auto-create
#    the path as an empty directory.
echo "ssh-ed25519 AAAA... your-comment" > authorized_keys

# 2. Build and start.
docker compose up --build

# 3. Connect to either principal on localhost:2222 (2222 avoids
#    clashing with the host's own sshd):
ssh -p 2222 -i ~/.ssh/your_key sw-sudoku@localhost
ssh -p 2222 -i ~/.ssh/your_key sw-matrix@localhost
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

- `/var/lib/demo/keys` (read-only mount): one file per principal containing OpenSSH-format public keys, one per line. Populated by ShellWatch's `authorizedKeyFile` key-delivery mechanism.
- `/var/lib/demo/host-keys` (named volume): persists SSH host keys across container restarts so clients don't see fingerprint changes. The rest of `/etc/ssh` (including `sshd_config`) lives in the image and is never shadowed — config changes always take effect on rebuild.

## Run alongside ShellWatch (docker compose)

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
