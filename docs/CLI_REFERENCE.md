# realm CLI Reference

Complete reference for all `realm` commands. Every command, flag, and
behaviour description was verified against `cli/src/realm/core.clj`.

---

## Configuration

The CLI reads and writes `~/.realm/config.edn`. After `realm login` the file
contains:

```edn
{:server {:url   "https://<server-host>:3001"
          :token "realm_<…>"}}
```

When a workspace is registered the CLI adds a workspace-to-UUID mapping under
`:workspaces`.

**Client-mode override:** in local (no-server) mode the CLI reads vault
configuration from `~/.realm/config.edn` under `:vault {:addr … :name …}` and
expects `AGENT_VAULT_TOKEN` to be exported in the shell environment. Exporting
`AGENT_VAULT_TOKEN` also overrides a server-supplied `vault_token` — the local
env var takes priority.

---

## Commands

### `realm login`

**Synopsis**

```
realm login --server <url>
```

**Description**

Authenticates against the realm control plane. Prompts interactively for a
username and password. On success stores the session token in
`~/.realm/config.edn`.

**Flags**

| Flag | Required | Description |
|---|---|---|
| `--server <url>` | yes | Base URL of the realm control plane, e.g. `https://realm.yourco.com:3001` |

**Example**

```bash
realm login --server https://realm.yourco.com:3001
# username: alice
# password: ········
# logged in; token stored in ~/.realm/config.edn
```

---

### `realm providers`

**Synopsis**

```
realm providers
```

**Description**

Lists the providers assigned to the currently authenticated user. Requires a
stored login token (run `realm login` first). Prints one provider per line in
the format `<name>   <type>   vault=<vault-name>`.

**Flags**

None.

**Example**

```bash
realm providers
# central-docker       docker     vault=default
```

---

### `realm up`

**Synopsis**

```
realm up <repo|path> [--provider <name>] [--id <name>] [--recreate]
```

**Description**

Provisions a dev-container workspace from a repository URL or local path.
Behaviour differs depending on whether a server login is configured and what
the assigned provider's `mode` is.

**Server mode (`mode=server`):**
The CLI calls `POST /v1/workspaces/provision` on the control plane. The server
runs `devpod up` asynchronously on the central VM. The CLI polls until the
workspace `provision_state` becomes `ready` (status `active` or `idle`) or
`failed`. On success it prints the `ws_id` to use with `realm ssh` and
`realm down`.

**Client mode (`mode=client` or local):**
The CLI configures a local DevPod provider and runs `devpod up` on the
developer's machine directly. Agent Vault credentials are injected from the
provider config or local environment.

**Flags**

| Flag | Required | Description |
|---|---|---|
| `--provider <name>` | no | Name of the assigned provider to use. Required only when more than one provider is assigned to you. |
| `--id <name>` | no | Override the workspace ID (defaults to the last path segment of the repo URL, lower-cased, non-alphanumeric chars replaced with `-`). |
| `--recreate` | no | Boolean flag (no value). Passes `--recreate` to `devpod up`, destroying and rebuilding the container from scratch. |

**Examples**

```bash
# Provision from a GitHub repo (server mode — build runs on central VM)
realm up https://github.com/yourorg/demo-repo

# Specify a provider when multiple are assigned
realm up https://github.com/yourorg/demo-repo --provider central-docker

# Override the workspace ID
realm up https://github.com/yourorg/demo-repo --id my-demo

# Force a clean rebuild
realm up https://github.com/yourorg/demo-repo --recreate
```

---

### `realm ssh`

**Synopsis**

```
realm ssh <id>
```

**Description**

Opens a shell session inside the named workspace.

**Server mode (workspace has a `provision_state`):**
Connects to the control plane's WebSocket proxy
(`GET /v1/workspaces/:uuid/proxy`) and relays a `devpod ssh` stdio session
running on the central VM. The relay is **stdio-only** — there is no PTY
allocation. Non-interactive commands and `claude -p "…"` work correctly;
interactive TUI programs (vim, arrow-key navigation, etc.) do not.

**Client mode:**
Calls `devpod ssh` directly on the local machine. Emits a `session-open`
telemetry event on start and `session-close` on exit; sends an `idle-tick`
heartbeat to the control plane every 60 seconds while the session is open.

**Flags**

None.

**Example**

```bash
realm ssh demo-repo
# Inside the session:
claude -p "explain the codebase"
```

---

### `realm down`

**Synopsis**

```
realm down <id>
```

**Description**

Stops and tears down the named workspace.

**Server mode (workspace has a `provision_state`):**
Calls `POST /v1/workspaces/:uuid/stop` on the control plane. The server runs
`devpod stop` followed by `devpod delete --force` on the VM (best-effort) and
marks the workspace `stopped`.

**Client mode (server configured, local provider):**
Runs `devpod delete` on the local machine to remove the container, then posts
a stop telemetry event to the control plane to mark the workspace `stopped`.

**Pure local mode (no server configured):**
Runs `devpod delete` on the local machine and prints "torn down." — no control
plane is contacted.

**Flags**

None.

**Example**

```bash
realm down demo-repo
# Workspace 'demo-repo' stopped.
```

---

### `realm status`

**Synopsis**

```
realm status
```

**Description**

Lists local DevPod workspaces and their provider. Uses Agent Vault credentials
from the local config or environment (client-mode command — does not query the
control plane).

**Flags**

None.

**Example**

```bash
realm status
# demo-repo                docker
# other-project            docker
```

---

### `realm doctor`

**Synopsis**

```
realm doctor
```

**Description**

Checks whether Agent Vault is configured and whether the `api.anthropic.com`
service is present in the vault. If the service is missing, generates a
proposal to create it and prints instructions to approve it in the Vault UI.
This is a client-mode command — it reads vault config from the local
environment.

**Flags**

None.

**Example**

```bash
realm doctor
# realm doctor: checking Agent Vault...
# ✓ anthropic service present (api.anthropic.com)
# ✓ Vault reachable; Claude Code traffic will be credential-injected.
```

---

### `realm help`

**Synopsis**

```
realm help
```

**Description**

Prints the usage summary for all commands. Also triggered by `--help`, `-h`,
or running `realm` with no arguments.

**Flags**

None.

**Example**

```bash
realm help
# realm — dev-container orchestrator with Agent Vault injection
#
#   realm up <repo|path> [--provider docker|k8s] [--id <name>] [--recreate]
#   realm ssh <id>
#   realm down <id>
#   realm status
#   realm doctor      verify/seed the Agent Vault anthropic service
#   realm login --server <url>   authenticate and store token
#   realm providers              list providers assigned to you
#   realm help
```
