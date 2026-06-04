# realm — Server Install Guide (Operator)

This guide walks an operator through installing the realm control plane on a
dedicated VM and preparing it for developer use.

---

## 1. Prerequisites

- **OS:** Ubuntu 22.04+ or Debian 12+ (x86\_64 or arm64)
- **Access:** root or a user with full `sudo`
- **Network:** the VM must be reachable by developers on port **3001** (plaintext)
  or **443** (TLS — see [TLS (production)](#3-tls-production))

---

## 2. One-line install

Run as root (or prefix with `sudo bash`):

```bash
curl -fsSL https://raw.githubusercontent.com/parinussa/realm-dist/main/install.sh | sudo bash
```

The script is idempotent — re-running it upgrades the JAR without touching
existing data.

### What it installs

| Component | Version / notes |
|---|---|
| `openjdk-21-jre-headless` | from apt |
| `docker.io` | from apt; daemon enabled |
| `devpod` | v0.6.15 (pinned) |
| `agent-vault` | 0.21.1 (pinned) |
| Postgres container `realm-db` | postgres:16, port 127.0.0.1:5432, data in `realm-db-data` volume |
| systemd unit `realm-server` | runs the control-plane uberjar on port 3001 |
| systemd unit `realm-vault` | runs the Agent Vault sidecar (enabled manually — see step 3) |
| First admin user | bootstrapped via `realm-server.jar bootstrap-admin` |

**Important:** the admin password is printed once in the terminal output under
the `seeding first admin` step. Store it immediately — it is not recoverable
from the installer after the session ends.

---

## 3. TLS (production)

For a production server, set `REALM_DOMAIN` (and optionally `REALM_TLS_EMAIL`)
before piping to bash:

```bash
REALM_DOMAIN=realm.example.com REALM_TLS_EMAIL=you@example.com \
  curl -fsSL https://raw.githubusercontent.com/parinussa/realm-dist/main/install.sh | sudo bash
```

`REALM_TLS_EMAIL` is optional — it defaults to `admin@<REALM_DOMAIN>` and is
used as the Let's Encrypt account email. Omit `REALM_DOMAIN` entirely to fall
back to plaintext `:3001` (dev/internal only).

### Prerequisites

- A DNS **A record** pointing `REALM_DOMAIN` at the VM's public IP, already
  propagated before running the installer.
- Inbound **ports 80 and 443** open in your cloud firewall / security group.
  Port 80 is required for the Let's Encrypt HTTP-01 challenge and for
  HTTP → HTTPS redirect — the installer will fail to obtain a cert if 80 is
  blocked.

### What the TLS block does

| Action | Detail |
|---|---|
| Installs Caddy | Pinned 2.8.4 (binary from GitHub releases) |
| Obtains + auto-renews cert | Let's Encrypt, HTTP-01 challenge |
| Writes Caddyfile | `/etc/caddy/Caddyfile` — reverse-proxies `https://<REALM_DOMAIN>` → `127.0.0.1:3001` |
| Binds realm-server to localhost | Sets `REALM_HOST=127.0.0.1` in `/etc/realm/env`; realm-server is no longer reachable directly from outside |
| Starts systemd unit | `realm-caddy` (enabled at boot) |
| Configures ufw (if active) | Opens 80/tcp and 443/tcp; **denies 3001/tcp** so Caddy is the only public entry point |

### Log in

Once TLS is active, point the CLI at the HTTPS URL — no port needed:

```bash
realm login --server https://realm.example.com
```

The CLI trusts the public Let's Encrypt certificate automatically. All
subsequent commands (`realm up`, `realm ssh`, `realm down`) communicate over
TLS; WebSocket traffic uses `wss://` automatically.

### Certificate renewal

Automatic — Caddy renews certificates before they expire. No operator action
required. Cert and ACME account data are stored under `/var/lib/caddy`.

### Operate Caddy

```bash
systemctl status realm-caddy
journalctl -u realm-caddy -f
```

The Caddyfile is at `/etc/caddy/Caddyfile`. After editing, reload with:

```bash
systemctl reload realm-caddy
```

---

## 4. Seed Agent Vault (manual)

The installer does not hold your Anthropic credentials. After the installer
finishes, complete the vault setup manually:

**Step 1 — First-run setup (sets the master password):**

```bash
agent-vault server
```

On first launch, `agent-vault server` prompts you to set a master password.
Follow the prompts, then create a vault named `default` and add a service for
`api.anthropic.com`. Store the credential `CLAUDE_CODE_OAUTH_TOKEN` in that
service.

**Step 2 — Write the master password to disk:**

```bash
printf '%s' '<your-master-password>' | sudo install -m 600 /dev/stdin /etc/realm/vault-master
```

The file is created with mode 600 from the start (no window where it is
world-readable). The `realm-vault` systemd unit reads this file on startup to
unlock the vault without interactive input.

**Step 3 — Enable and start the vault service:**

```bash
sudo systemctl enable --now realm-vault
```

**Step 4 — Mint a provider token (long-lived):**

```bash
agent-vault vault token --ttl 604800
```

Copy the printed token — you will need it in the next step when creating a
server-mode provider.

**Step 5 — (optional) Rate limiting:**

Agent Vault rate-limits proxied requests per instance and returns `429
too_many_requests` (with a `Retry-After` header) when the limit trips — under heavy
`claude` use a developer may hit this. It is **not configurable via the CLI**
(`agent-vault owner config set` only exposes `--invite-only` / `--allowed-domains`);
it is an **instance-owner setting in the web UI**: *Manage Instance → Settings → Rate
Limiting*.

The vault is bound to localhost + the docker bridge (never public), so reach the UI
through an SSH tunnel from your workstation:

```bash
ssh -L 14321:localhost:14321 <server-host>
# then open http://localhost:14321 and log in as the instance owner (the email/password
# you set in Step 1), → Manage Instance → Settings → Rate Limiting → raise or disable it.
```

Leave the default for normal use; raise it only if legitimate traffic is being throttled.
(If the 429 is Anthropic's *upstream* limit passed through the proxy, this setting won't
help — that's the Anthropic API's own rate limit.)

---

## 5. Create a server-mode provider and assign a developer

The one-line install (Section 2) printed an admin **password** (not a token).
Exchange that password for a bearer token via `POST /v1/auth/login` (shown in
step 5a below), then use that token for all subsequent API calls.

### 5a. Log in as admin and capture the token

```bash
TOKEN=$(curl -s -X POST http://localhost:3001/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"<admin-pw>"}' \
  | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
```

### 5b. Create a server-mode provider

```bash
curl -s -X POST http://localhost:3001/v1/providers \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "name":          "central-docker",
    "type":          "docker",
    "devpod_source": "docker",
    "mode":          "server",
    "options":       {},
    "vault_addr":    "http://host.docker.internal:14321",
    "vault_name":    "default",
    "vault_token":   "<vault-token-minted-above>"
  }'
# → {"id":"<provider-uuid>","name":"central-docker","mode":"server",...}
```

- `vault_addr` uses `host.docker.internal:14321` so workspace containers built
  on this VM can reach the vault sidecar running on the same host.
- `vault_token` is the token you minted with `agent-vault vault token` above.

### 5c. Create a developer user

```bash
curl -s -X POST http://localhost:3001/v1/users \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"<temp-pw>","role":"user"}'
# → {"id":"<user-uuid>","username":"alice","role":"user"}
```

### 5d. Assign the provider to the developer

```bash
curl -s -X POST http://localhost:3001/v1/providers/<provider-uuid>/assignments \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"user_id":"<user-uuid>"}'
# → {"status":"assigned"}
```

Hand the developer the server URL (`https://realm.example.com` with TLS, or
`http://<this-host>:3001` without), their username, and their temporary
password. They do not need Docker or a VPN — just the `realm` CLI and network
access to the server.

---

## 6. Firewall

The correct rules depend on whether TLS is enabled.

### With TLS (`REALM_DOMAIN` set)

The installer (when ufw is active) configures this automatically:

```bash
# Caddy handles all inbound traffic; realm-server is localhost-only
sudo ufw allow 80/tcp    # Let's Encrypt HTTP-01 challenge + HTTP→HTTPS redirect
sudo ufw allow 443/tcp   # HTTPS / WSS (Caddy)
sudo ufw deny  3001/tcp  # realm-server NOT public; Caddy reverse-proxies it
```

The installer also re-applies the docker-bridge → vault allows (`172.16.0.0/12` → 14321/14322).
With ufw's default-deny INPUT policy, 5432/14321/14322 are already unreachable from the
public; the explicit denies below are belt-and-suspenders the installer does **not** run —
add them manually if you want them recorded:

```bash
sudo ufw deny 5432    # Postgres
sudo ufw deny 14321   # Agent Vault HTTP API
sudo ufw deny 14322   # Agent Vault proxy port
```

### Without TLS (plaintext, dev/internal only)

```bash
# Allow developer access to the control plane
sudo ufw allow 3001

# Deny direct public access to internal services (manual; default-deny INPUT already blocks these)
sudo ufw deny 5432    # Postgres
sudo ufw deny 14321   # Agent Vault HTTP API
sudo ufw deny 14322   # Agent Vault proxy port

# REQUIRED: let workspace containers reach the vault over the docker bridge.
# Containers connect via host.docker.internal -> the host's docker-bridge IP, which
# hits the host INPUT chain; with a default-deny policy that traffic is dropped and
# `claude -p` fails with "context deadline exceeded". install.sh adds these when ufw
# is active; add them by hand if you enable ufw later:
sudo ufw allow from 172.16.0.0/12 to any port 14321 proto tcp
sudo ufw allow from 172.16.0.0/12 to any port 14322 proto tcp
```

> Native Linux Docker has no built-in `host.docker.internal`; the realm dev-container
> template maps it via `runArgs: --add-host=host.docker.internal:host-gateway`, so the
> alias resolves on both Linux and Docker Desktop/OrbStack.

Apply and enable ufw if not already active:

```bash
sudo ufw enable
sudo ufw status
```

---

## 7. Operate

### Service status and restart

```bash
systemctl status realm-server realm-vault
systemctl restart realm-server
systemctl restart realm-vault
```

### Follow live logs

```bash
journalctl -u realm-server -f
journalctl -u realm-vault -f
```

### Upgrade to a specific version

Re-run the installer with the `REALM_VERSION` env var:

```bash
curl -fsSL https://raw.githubusercontent.com/parinussa/realm-dist/main/install.sh \
  | sudo REALM_VERSION=vX.Y.Z bash
```

The installer is idempotent: it replaces the JAR and restarts the service but
leaves the database and `/etc/realm/env` intact.

---

## 8. Known limitations (MVP)

- **TLS requires a public domain.** The built-in Caddy TLS path (Section 3)
  requires a DNS A record and public ports 80/443. For a private network without
  a routable domain, the plaintext `:3001` path is the only option — restrict
  access at the network/VPN layer.
- **`vault_token` stored in plaintext.** The provider `vault_token` is stored
  unencrypted in the Postgres `providers` table. Do not store high-value
  long-lived credentials here until at-rest encryption lands in a future sprint.
- **Provisioner jobs are in-memory.** If `realm-server` restarts while a
  `realm up` build is running, the workspace row stays `provisioning`
  indefinitely. The fix is to re-run `realm up <repo>` to re-trigger the build.
