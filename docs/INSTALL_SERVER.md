# realm — Server Install Guide (Operator)

This guide walks an operator through installing the realm control plane on a
dedicated VM and preparing it for developer use.

---

## 1. Prerequisites

- **OS:** Ubuntu 22.04+ or Debian 12+ (x86\_64 or arm64)
- **Access:** root or a user with full `sudo`
- **Network:** the VM must be reachable by developers on port **3001**
  (HTTPS reverse proxy recommended for production — see [Firewall](#5-firewall))

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

## 3. Seed Agent Vault (manual)

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

---

## 4. Create a server-mode provider and assign a developer

The one-line install (Section 2) printed an admin **password** (not a token).
Exchange that password for a bearer token via `POST /v1/auth/login` (shown in
step 4a below), then use that token for all subsequent API calls.

### 4a. Log in as admin and capture the token

```bash
TOKEN=$(curl -s -X POST http://localhost:3001/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"<admin-pw>"}' \
  | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
```

### 4b. Create a server-mode provider

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

### 4c. Create a developer user

```bash
curl -s -X POST http://localhost:3001/v1/users \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"<temp-pw>","role":"user"}'
# → {"id":"<user-uuid>","username":"alice","role":"user"}
```

### 4d. Assign the provider to the developer

```bash
curl -s -X POST http://localhost:3001/v1/providers/<provider-uuid>/assignments \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"user_id":"<user-uuid>"}'
# → {"status":"assigned"}
```

Hand the developer the server URL (`http://<this-host>:3001`), their username,
and their temporary password. They do not need Docker or a VPN — just the
`realm` CLI and network access to port 3001.

---

## 5. Firewall

```bash
# Allow developer access to the control plane
sudo ufw allow 3001

# Deny direct public access to internal services
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

## 6. Operate

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

## 7. Known limitations (MVP)

- **No TLS built in.** Token credentials travel in plaintext over HTTP. For
  anything beyond a trusted private network, put a TLS-terminating reverse proxy
  (nginx, Caddy) in front of port 3001.
- **`vault_token` stored in plaintext.** The provider `vault_token` is stored
  unencrypted in the Postgres `providers` table. Do not store high-value
  long-lived credentials here until at-rest encryption lands in a future sprint.
- **Provisioner jobs are in-memory.** If `realm-server` restarts while a
  `realm up` build is running, the workspace row stays `provisioning`
  indefinitely. The fix is to re-run `realm up <repo>` to re-trigger the build.
