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

For docker server-mode providers, `realm ssh` opens a **real interactive
terminal** — the server allocates a PTY, your local terminal enters raw mode,
and raw bytes are relayed in both directions. You get a proper shell prompt,
full-screen programs work, and your terminal is restored on exit:

```bash
# Inside the session — it's a real terminal:
$ vim src/payments.ts       # full-screen editor works
$ claude -p "write tests for src/payments.ts"
$ claude -p "summarise the open issues in this repo"
$ exit                      # restores your local terminal
```

> **Note for scripted / non-interactive use:** the PTY does terminal
> negotiation, which can interfere with piping commands into `realm ssh`
> non-interactively from your local shell. For automation, open the session
> interactively and run `claude -p "…"` (or other commands) at the prompt
> inside the session rather than piping them through the outer shell.

### Step 5 — Tear down

```bash
realm down demo-repo
# Workspace 'demo-repo' stopped.
```

The control plane stops and deletes the container on the VM and marks the
workspace `stopped`.

---

## 2. Limitations today

- **`realm ssh` is a real interactive terminal for docker server-mode.**
  Full-screen programs (`vim`, `htop`, `less`, etc.), arrow keys, and `Ctrl-C`
  all work as expected.

- **Non-docker server-mode providers** fall back to a stdio relay with no PTY.
  Interactive TUI programs do not work in that case; `claude -p "…"` and other
  non-interactive commands do.

- **No dev-laptop port-forwarding.** Ports exposed inside the container
  (e.g. a local dev server on `:3000`) are not forwarded to your machine.
  This is deferred to a future sprint.

---

## 3. Coming later

A supported **text-editor extension** (VS Code, JetBrains) that connects to
the central VM is planned for a future sprint. Until that lands, the CLI loop
above (`realm up` → `realm ssh` → `realm down`) is the fully supported
workflow.

No timeline is committed. This document will be updated when the extension is
available.
