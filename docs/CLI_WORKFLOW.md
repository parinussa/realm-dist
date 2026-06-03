# realm CLI — Day-to-Day Workflow (Interim Guide)

This guide covers the supported day-to-day loop for developers using the realm
CLI with a **server-mode** provider (central VM, no local Docker required).

---

## 1. The loop

A complete session from login to teardown. Run each command in your local
terminal.

### Step 1 — Log in (once per machine)

```bash
realm login --server https://realm.yourco.com:3001
# username: alice
# password: ········
# logged in; token stored in ~/.realm/config.edn
```

Your session token is stored in `~/.realm/config.edn`. You do not need to
log in again until the token expires or you switch servers.

### Step 2 — Verify your provider assignment

```bash
realm providers
# central-docker       docker     vault=default
```

### Step 3 — Provision a workspace

```bash
realm up https://github.com/yourorg/demo-repo
```

The CLI submits a provision request to the control plane. The server builds the
container on the central VM (this takes 1–3 minutes for a fresh image pull).
The CLI polls and prints progress; on success:

```
Provisioned on server (ws=demo-repo). Connect: realm ssh demo-repo
```

Use the printed `ws_id` in the next steps.

### Step 4 — Attach and work

```bash
realm ssh demo-repo
```

Your terminal is now relayed through the WebSocket proxy to a `devpod ssh`
session running on the server. Run non-interactive commands or `claude`:

```bash
# Inside the relay session:
claude -p "summarise the open issues in this repo"
claude -p "write tests for src/payments.ts"
```

When you are done, exit the session:

```bash
exit
```

### Step 5 — Tear down

```bash
realm down demo-repo
# Workspace 'demo-repo' stopped.
```

The control plane stops and deletes the container on the VM and marks the
workspace `stopped`.

---

## 2. Limitations today (stdio relay)

The `realm ssh` connection is a **stdio relay** — not a full PTY/TTY session.
This means:

- **Works:** `claude -p "…"` (non-interactive, pipe-friendly), shell scripts,
  `git`, `npm run`, `cat`, `grep`, and any other command that does not need a
  real terminal.
- **Does not work:** interactive TUI programs that use escape sequences — `vim`,
  `nano`, arrow-key navigation in shells, `less` with interactive paging,
  `htop`, etc.
- **Input is line-buffered.** Each line you type is sent as a WebSocket frame
  when you press Enter. There is no character-at-a-time mode.
- **No dev-laptop port-forwarding.** Ports exposed inside the container
  (e.g. a local dev server on `:3000`) are not forwarded to your machine.
  This is deferred to a future sprint.

If you need to run a command that requires a real TTY, restructure it as a
non-interactive invocation. For example, instead of `claude` (interactive
REPL), use `claude -p "your prompt here"`.

---

## 3. Coming later

A supported **text-editor extension** (VS Code, JetBrains) that connects to
the central VM is planned for a future sprint. Until that lands, the CLI loop
above (`realm up` → `realm ssh` → `realm down`) is the fully supported
workflow.

No timeline is committed. This document will be updated when the extension is
available.
