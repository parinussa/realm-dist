# realm CLI — Developer Install Guide

This guide covers installing the `realm` CLI on your developer machine
(macOS or Linux). No local Docker is required when connecting to a
**server-mode** provider.

---

## 1. Install

Run the one-liner in your terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/parinussa/realm-dist/main/install-cli.sh | bash
```

The installer:

1. Checks for [Babashka](https://github.com/babashka/babashka) (`bb`) — installs
   it to `~/.local/bin` if missing.
2. Downloads the CLI source bundle (`realm-cli.tar.gz`) and unpacks it into
   `~/.realm/cli/src/`.
3. Writes an executable wrapper at `~/.local/bin/realm` that invokes
   `bb --classpath ~/.realm/cli/src -m realm.core`.

The installer is idempotent — re-running it upgrades the CLI without touching
your stored credentials.

---

## 2. Add `~/.local/bin` to PATH

The installer writes `realm` to `~/.local/bin`. If that directory is not
already on your PATH, add this line to your shell profile
(`~/.zshrc`, `~/.bashrc`, etc.) and reload it:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Reload your shell:

```bash
source ~/.zshrc   # or ~/.bashrc
```

Verify the install:

```bash
realm help
```

---

## 3. Log in

Authenticate against the control plane your operator set up:

```bash
realm login --server https://<server-host>:3001
```

The command prompts for your username and password (the credentials your
operator created for you). On success it prints:

```
logged in; token stored in ~/.realm/config.edn
```

Your session token is stored in `~/.realm/config.edn` and is used
automatically for all subsequent commands.

---

## 4. Verify your provider assignment

```bash
realm providers
```

This lists the providers your operator has assigned to you, for example:

```
central-docker       docker     vault=default
```

If the list is empty, ask your operator to assign a provider to your account.

---

## 5. No local Docker needed for server-mode providers

When your assigned provider has `mode=server`, workspace containers are built
and hosted on the central VM. The `realm` CLI on your machine acts as a thin
client — it sends provisioning requests to the control plane and relays your
terminal session over a WebSocket connection.

You do **not** need Docker installed on your laptop for server-mode use.

See [CLI_WORKFLOW.md](CLI_WORKFLOW.md) for the day-to-day usage loop.
