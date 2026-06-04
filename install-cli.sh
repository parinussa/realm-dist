#!/usr/bin/env bash
set -euo pipefail

# realm CLI installer — macOS + Linux (no Docker needed for server-mode use).
#   curl -fsSL https://raw.githubusercontent.com/parinussa/realm-dist/main/install-cli.sh | bash
REL_BASE="https://github.com/parinussa/realm-dist/releases"
CLI_HOME="${HOME}/.realm/cli"
BIN_DIR="${HOME}/.local/bin"

log() { printf '\033[1;36m[realm]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[realm] %s\033[0m\n' "$*" >&2; exit 1; }

mkdir -p "${CLI_HOME}" "${BIN_DIR}"

# 1. ensure babashka
if ! command -v bb >/dev/null 2>&1; then
  log "installing Babashka"
  curl -fsSL https://raw.githubusercontent.com/babashka/babashka/master/install -o /tmp/bb-install.sh
  bash /tmp/bb-install.sh --dir "${BIN_DIR}" || die "babashka install failed"
fi

# 2. fetch CLI source bundle (published to the realm-dist release as realm-cli.tar.gz)
log "installing realm CLI"
curl -fsSL "${REL_BASE}/latest/download/realm-cli.tar.gz" -o /tmp/realm-cli.tar.gz
rm -rf "${CLI_HOME:?}/src"
tar -xzf /tmp/realm-cli.tar.gz -C "${CLI_HOME}"   # extracts src/

# 3. wrapper on PATH
cat > "${BIN_DIR}/realm" <<EOF
#!/usr/bin/env bash
exec bb --classpath "${CLI_HOME}/src" -m realm.core "\$@"
EOF
chmod +x "${BIN_DIR}/realm"

# Ensure ~/.local/bin is on PATH: append to the user's shell rc(s) once (idempotent).
# shellcheck disable=SC2016  # single quotes intentional: literal $HOME/$PATH written to rc
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
case ":${PATH}:" in
  *":${BIN_DIR}:"*) ;;   # already on PATH, nothing to do
  *)
    added=0
    for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
      # only touch an rc that exists; always ensure ~/.bashrc exists so bash users get it
      if [ ! -e "$rc" ]; then
        [ "$rc" = "${HOME}/.bashrc" ] || continue
        : > "$rc"
      fi
      if ! grep -qF "$PATH_LINE" "$rc" 2>/dev/null; then
        printf '\n# added by realm install-cli.sh\n%s\n' "$PATH_LINE" >> "$rc"
        added=1
      fi
    done
    [ "$added" = 1 ] && log "added ~/.local/bin to PATH in your shell rc — open a new shell or: source ~/.bashrc"
    ;;
esac
log "installed. Next: realm login --server https://<server-host>:3001"
