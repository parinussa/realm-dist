#!/usr/bin/env bash
set -euo pipefail

# realm control-plane installer — Ubuntu/Debian, run as root.
#   curl -fsSL https://raw.githubusercontent.com/parinussa/realm-dist/main/install.sh | sudo bash
REALM_VERSION="${REALM_VERSION:-latest}"
RAW_BASE="https://raw.githubusercontent.com/parinussa/realm-dist/main"
REL_BASE="https://github.com/parinussa/realm-dist/releases"
DEVPOD_VERSION="v0.6.15"
AGENT_VAULT_VERSION="0.21.1"

log() { printf '\033[1;36m[realm]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[realm] %s\033[0m\n' "$*" >&2; exit 1; }
# Bounded read then substring — NOT `tr ... | head -c N`, which SIGPIPEs tr and,
# under `set -o pipefail`, aborts the script (exit 141).
genpw() { local raw; raw="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"; printf '%s' "${raw:0:24}"; }

# 1. preflight
[ "$(id -u)" = "0" ] || die "run as root (use sudo)"
# shellcheck disable=SC1091
. /etc/os-release 2>/dev/null || die "cannot read /etc/os-release"
case "${ID:-}" in ubuntu|debian) ;; *) die "unsupported OS '${ID:-unknown}' (need ubuntu/debian)";; esac
case "$(uname -m)" in x86_64) GOARCH=amd64;; aarch64|arm64) GOARCH=arm64;; *) die "unsupported arch $(uname -m)";; esac

# 2. apt deps
log "installing apt dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl openjdk-21-jre-headless docker.io
systemctl enable --now docker

# 3. pinned binaries (VERIFY asset URLs against the real release pages during the spike)
if ! command -v devpod >/dev/null 2>&1; then
  log "installing devpod ${DEVPOD_VERSION}"
  curl -fsSL "https://github.com/loft-sh/devpod/releases/download/${DEVPOD_VERSION}/devpod-linux-${GOARCH}" -o /usr/local/bin/devpod
  chmod +x /usr/local/bin/devpod
fi
if ! command -v agent-vault >/dev/null 2>&1; then
  log "installing agent-vault ${AGENT_VAULT_VERSION}"
  # Assets are tarballs: agent-vault_<ver>_linux_<arch>.tar.gz (verified v0.21.1 release page)
  AV_TGZ="agent-vault_${AGENT_VAULT_VERSION}_linux_${GOARCH}.tar.gz"
  curl -fsSL "https://github.com/Infisical/agent-vault/releases/download/v${AGENT_VAULT_VERSION}/${AV_TGZ}" \
    -o "/tmp/${AV_TGZ}"
  tar -xzf "/tmp/${AV_TGZ}" -C /tmp agent-vault
  install -m 755 /tmp/agent-vault /usr/local/bin/agent-vault
  rm -f "/tmp/${AV_TGZ}" /tmp/agent-vault
fi

# 4. system user + dirs
id realm >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin realm
usermod -aG docker realm
install -d -m 755 /opt/realm
install -d -m 700 /etc/realm
# agent-vault stores its DB under $HOME/.agent-vault and devpod writes config + ssh
# under $HOME; the realm service user has no home, so give it a writable data dir
# (both units set HOME to this).
install -d -o realm -g realm -m 700 /var/lib/realm
install -d -o realm -g realm -m 700 /var/lib/realm/.ssh

# 4b. register the devpod docker provider as the realm user (server shells out to
# devpod up --provider docker; without this it errors "couldn't find provider docker").
sudo -u realm env HOME=/var/lib/realm devpod provider add docker --use 2>/dev/null \
  || log "devpod docker provider already present"

# 5. Postgres (idempotent)
if ! docker ps -a --format '{{.Names}}' | grep -qx realm-db; then
  DB_PW="$(genpw)"
  log "starting Postgres container"
  docker run -d --name realm-db --restart unless-stopped \
    -e POSTGRES_USER=realm -e POSTGRES_PASSWORD="${DB_PW}" -e POSTGRES_DB=realm \
    -p 127.0.0.1:5432:5432 -v realm-db-data:/var/lib/postgresql/data postgres:16 >/dev/null
else
  log "realm-db already exists; reusing (DB password from /etc/realm/env)"
  DB_PW=""
  [ -f /etc/realm/env ] || die "realm-db container exists but /etc/realm/env is missing — restore it (it holds the DB password) and re-run"
fi

# 6. fetch uberjar + verify checksum
JAR_URL="${REL_BASE}/latest/download/realm-server.jar"
SUM_URL="${REL_BASE}/latest/download/realm-server.jar.sha256"
[ "$REALM_VERSION" = "latest" ] || { JAR_URL="${REL_BASE}/download/${REALM_VERSION}/realm-server.jar"; SUM_URL="${REL_BASE}/download/${REALM_VERSION}/realm-server.jar.sha256"; }
log "fetching realm-server.jar (${REALM_VERSION})"
curl -fsSL "$JAR_URL" -o /opt/realm/realm-server.jar
curl -fsSL "$SUM_URL" -o /tmp/realm-server.jar.sha256
( cd /opt/realm && echo "$(cut -d' ' -f1 /tmp/realm-server.jar.sha256)  realm-server.jar" | sha256sum -c - ) || die "checksum mismatch"

# 7. /etc/realm/env (write only on first install OR if missing)
if [ -n "${DB_PW}" ] || [ ! -f /etc/realm/env ]; then
  : "${DB_PW:=$(genpw)}"
  cat > /etc/realm/env <<EOF
REALM_PORT=3001
JDBC_DATABASE_URL=jdbc:postgresql://127.0.0.1:5432/realm?user=realm&password=${DB_PW}
REALM_ACTIVE_WINDOW_SECONDS=300
STREAM_POLL_SECONDS=3
EOF
  chmod 600 /etc/realm/env
fi
chown -R realm:realm /opt/realm

# 8. systemd units
log "installing systemd units"
curl -fsSL "${RAW_BASE}/systemd/realm-server.service" -o /etc/systemd/system/realm-server.service
curl -fsSL "${RAW_BASE}/systemd/realm-vault.service"  -o /etc/systemd/system/realm-vault.service
systemctl daemon-reload

# 9. start server (migrates on boot)
log "starting realm-server"
systemctl enable realm-server
systemctl restart realm-server

# 10. seed admin
log "waiting for realm-server to be ready"
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 2 -X POST http://127.0.0.1:3001/v1/auth/login -H 'content-type: application/json' -d '{}' 2>/dev/null || true)"
  [ "$code" = "401" ] && break
  sleep 2
done
log "seeding first admin"
JDBC_DATABASE_URL="$(grep '^JDBC_DATABASE_URL=' /etc/realm/env | cut -d= -f2-)"
export JDBC_DATABASE_URL
ADMIN_OUT="$(java -jar /opt/realm/realm-server.jar bootstrap-admin || true)"
echo "$ADMIN_OUT"

# 10b. TLS (opt-in): when REALM_DOMAIN is set, front the control plane with Caddy
# (auto-HTTPS via Let's Encrypt) and bind realm-server to localhost.
if [ -n "${REALM_DOMAIN:-}" ]; then
  CADDY_VERSION="2.8.4"
  log "configuring TLS (Caddy) for ${REALM_DOMAIN}"
  if ! command -v caddy >/dev/null 2>&1; then
    curl -fsSL "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${GOARCH}.tar.gz" -o /tmp/caddy.tgz
    tar -xzf /tmp/caddy.tgz -C /tmp caddy
    install -m 755 /tmp/caddy /usr/local/bin/caddy
    rm -f /tmp/caddy.tgz /tmp/caddy
  fi
  id caddy >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin caddy
  install -d -o caddy -g caddy -m 700 /var/lib/caddy
  install -d -m 755 /etc/caddy
  cat > /etc/caddy/Caddyfile <<EOF
{
    email ${REALM_TLS_EMAIL:-admin@${REALM_DOMAIN}}
}
${REALM_DOMAIN} {
    reverse_proxy 127.0.0.1:3001
}
EOF
  chmod 644 /etc/caddy/Caddyfile
  if grep -q '^REALM_HOST=' /etc/realm/env; then
    sed -i 's/^REALM_HOST=.*/REALM_HOST=127.0.0.1/' /etc/realm/env
  else
    printf 'REALM_HOST=127.0.0.1\n' >> /etc/realm/env
  fi
  systemctl restart realm-server
  curl -fsSL "${RAW_BASE}/systemd/realm-caddy.service" -o /etc/systemd/system/realm-caddy.service
  systemctl daemon-reload
  systemctl enable --now realm-caddy
fi

# 10c. firewall: when ufw is active, workspace containers reach the vault via the
# docker bridge (host.docker.internal → host-gateway), which hits the host's INPUT
# chain. With a default-deny INPUT policy that traffic is dropped, so allow the
# docker private range to the vault ports. Public access to them stays denied.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  log "allowing docker subnet -> vault ports (14321/14322)"
  ufw allow from 172.16.0.0/12 to any port 14321 proto tcp >/dev/null 2>&1 || true
  ufw allow from 172.16.0.0/12 to any port 14322 proto tcp >/dev/null 2>&1 || true
  if [ -n "${REALM_DOMAIN:-}" ]; then
    log "TLS firewall: allow 80/443, deny 3001"
    ufw allow 80/tcp   >/dev/null 2>&1 || true
    ufw allow 443/tcp  >/dev/null 2>&1 || true
    ufw deny  3001/tcp >/dev/null 2>&1 || true
  fi
fi

# 11. operator checklist
if [ -n "${REALM_DOMAIN:-}" ]; then
  SERVER_URL="https://${REALM_DOMAIN}  (TLS via Caddy; ensure DNS A record -> this host and ports 80+443 are open)"
  FIREWALL_NOTE="FIREWALL: 80+443 open; 3001 DENIED (Caddy only); DENY 5432, 14321, 14322 from public. (ufw already allowed docker subnet 172.16.0.0/12 -> 14321/14322 for the vault; keep those.)"
else
  SERVER_URL="http://<this-host>:3001  (plaintext; dev/internal only — set REALM_DOMAIN to enable TLS)"
  FIREWALL_NOTE="FIREWALL: allow 3001; DENY 5432, 14321, 14322 from public. (ufw already allowed docker subnet 172.16.0.0/12 -> 14321/14322 for the vault; keep those.)"
fi
printf '\n================ realm installed ================\nServer:  %s\n\n' "$SERVER_URL"
cat <<'EOF'
Admin:   see the 'admin created' line above (store the password now)

NEXT — Agent Vault (operator, manual; the installer does not hold your credentials):
  1) agent-vault server  (first run: set a master password)
     create vault 'default', add service 'anthropic-oauth' (host api.anthropic.com),
     store credential CLAUDE_CODE_OAUTH_TOKEN.
  2) Write the vault master password to /etc/realm/vault-master (chmod 600).
  3) systemctl enable --now realm-vault
  4) Mint a provider token:  agent-vault vault token --ttl 604800
     Create a server-mode provider (vault_addr=http://host.docker.internal:14321,
     vault_name=default, that token), then assign developers.

EOF
printf '%s\n=================================================\n' "$FIREWALL_NOTE"
