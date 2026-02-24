# RFC: Credential Manager Plugin for para-llm-directory (v4 — secret-mgr + secure-exec + age)

## Context

Autonomous Claude Code agents running in para-llm tmux panes need to interact with authenticated services (APIs, git remotes, Docker registries, cloud CLIs). Today there's no credential management — agents either can't authenticate or would need raw secrets exposed in their environment.

**Goal**: Agents get working credentials with minimal complexity, strong security properties, and **the agent never has direct access to the credential store or decryption tools**.

## Evolution: v1 → v2 → v3 → v4

| Version | Approach | Code we write | Complexity | Agent sees secrets? |
|---------|----------|---------------|------------|---------------------|
| v1 | Build everything from scratch (custom mitmproxy addon, custom credential helpers) | ~1,900 lines, 18 files | Very high | No |
| v2 | Compose existing tools (Secretless Broker, credential-1password) | ~200 lines, 4 files | Medium | No |
| v3 | Vault generates ephemeral credentials, injected as env vars | ~150 lines, 3 files | Low | Yes (ephemeral) |
| **v4** | **`secret-mgr` + `secure-exec` + `age` encryption. Agent blocked from credential tools at 4 layers.** | **~400 lines, 12 files** | **Low-Medium** | **No** |

### Why v4?

v3 relies on Vault (a heavyweight server dependency) and exposes ephemeral credentials as env vars the agent can read. v4 asks: **can we get the same security properties without a server, using only local tools, and without the agent ever seeing a credential?**

| Concern | v3 (Vault ephemeral) | v4 (secret-mgr + secure-exec) |
|---------|----------------------|-------------------------------|
| Infrastructure | Vault server required | None — just `age` binary |
| Cross-platform | Vault runs everywhere | `age` is a single static binary (mac/linux/windows) |
| Agent sees credentials | Yes (env vars) | No (injected at exec time, not in agent's env) |
| Credential storage | Vault server | `age`-encrypted files on disk |
| OAuth support | Vault secrets engines | Delegates to native CLIs (`gh`, `gcloud`, `aws`) |
| Offline capable | No (needs Vault server) | Yes |
| Setup complexity | High (Vault + secrets engines + policies) | Low (install `age`, register services) |

Key design principles:
- **Light touch**: Claude uses its existing knowledge of `gh`, `curl`, `gcloud`, etc. The wrapper just prefixes the command.
- **Compose existing tools**: `age` for encryption, native CLIs for OAuth, shell for orchestration.
- **Defense in depth**: 4 layers prevent agent access to credential tools.
- **Cross-platform**: Works on macOS, Linux, and Windows (WSL) with no OS-specific keychain dependencies.

## Architecture Overview

```
Human (direct)              Claude Code (agent)
     │                            │
 secret-mgr                   secure-exec
 (BLOCKED x4)                 (ALLOWED)
     │                            │
     ▼                            ▼
 age-encrypted              calls secret-mgr internally
 credential files                 │
 (0600 perms)                injects cred as env var
                                  │
                             exec gh/curl/gcloud/etc.
```

### How `secure-exec` works

```
Claude runs:  secure-exec gh pr list

  secure-exec                   secret-mgr                    age
  ───────────                   ──────────                    ───
       │                             │                          │
       │  Lookup: "gh" matches       │                          │
       │  github.conf (COMMANDS=gh)  │                          │
       │                             │                          │
       │  secret-mgr get github      │                          │
       │ ──────────────────────────▶ │                          │
       │                             │  age -d -i key.txt       │
       │                             │  registry/github.age     │
       │                             │ ────────────────────────▶│
       │                             │ ◀── ghp_xxx ────────────│
       │ ◀── ghp_xxx ────────────── │                          │
       │                             │                          │
       │  export GH_TOKEN=ghp_xxx   │                          │
       │  exec gh pr list            │                          │
       │                             │                          │

Claude only sees: the output of "gh pr list".
Claude never sees: ghp_xxx, secret-mgr, age, or the key file.
```

## Security Model — Four Layers of Agent Isolation

The agent (Claude Code) runs as the same OS user as the human. Since traditional Unix permissions can't distinguish them, we use **4 independent layers**:

### Layer 1: Claude deny rules (`.claude/settings.json`)

```json
{
  "deny": [
    "Bash(secret-mgr*)",
    "Bash(*secret-mgr*)",
    "Bash(*/secret-mgr.sh*)",
    "Bash(age *)",
    "Bash(*age -d*)",
    "Bash(*age -e*)",
    "Bash(*age --decrypt*)",
    "Bash(*age --encrypt*)",
    "Bash(*.age*)"
  ]
}
```

**What it stops**: Claude from requesting to run these commands.

### Layer 2: PreToolUse hook (belt-and-suspenders)

`hooks/deny-secret-mgr.sh` reads tool input JSON from stdin. If the command contains `secret-mgr` or `age`, it outputs `{"decision": "block", "reason": "Direct credential access not permitted"}`.

**What it stops**: Attempts that slip through deny rule patterns.

### Layer 3: Not on PATH

`secret-mgr` and `age` are installed to a non-standard directory (`$PLUGIN_DIR/.bin/`) that is **not** added to the agent's PATH. Only `secure-exec` is added to PATH. `secure-exec` references `secret-mgr` and `age` by absolute path internally.

**What it stops**: Claude from discovering or executing the binaries by name.

### Layer 4: Passphrase-protected age identity (cryptographic enforcement)

The `age` identity file (`key.txt`) is encrypted with a passphrase. The passphrase is:
- Generated at session start (random 32-byte hex)
- Written to a file descriptor or tmpfile with 0600 permissions
- Passed to `secure-exec` via an environment variable (`_SECURE_EXEC_PASSPHRASE`) that is **set only in the `secure-exec` wrapper's process context**, not exported to the agent's shell environment

Even if Claude somehow finds the `age` binary AND the encrypted identity file, it cannot decrypt without the passphrase.

**What it stops**: Actual credential decryption even if all other layers fail.

### Layer Summary

| Layer | Type | What it blocks | Bypass requires |
|-------|------|----------------|-----------------|
| 1. Deny rules | Config | Claude requesting the command | Pattern not in deny list |
| 2. PreToolUse hook | Runtime | Commands that match patterns | Hook disabled or bypassed |
| 3. Off PATH | Filesystem | Discovery by name | Knowing the absolute path |
| 4. Passphrase-protected key | Cryptographic | Decryption of stored credentials | Knowing the session passphrase |

## File Structure

```
plugins/credential-mgr/
├── secret-mgr.sh                  # Human-only credential manager
├── secure-exec.sh                 # Transparent auth wrapper (Claude uses this)
├── install-credential-mgr.sh      # Installer
├── lib/
│   ├── store.sh                   # Read/write age-encrypted credential files
│   └── inject.sh                  # Credential injection strategies (env-var, flag)
├── services.d/
│   ├── github.sh                  # GitHub: GH_TOKEN env var
│   ├── gcloud.sh                  # GCP: CLOUDSDK_AUTH_ACCESS_TOKEN
│   ├── aws.sh                     # AWS: AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY
│   └── docker.sh                  # Docker: DOCKER_TOKEN
├── config/
│   ├── hooks-config.json          # PreToolUse hook config
│   └── claude-md-snippet.md       # CLAUDE.md injection for agent awareness
└── hooks/
    └── deny-secret-mgr.sh         # Hook script that blocks secret-mgr + age access
```

Runtime data (created by installer/registration):
```
$PARA_LLM_ROOT/plugins/credential-mgr/
├── .bin/                          # 0700 — age binary lives here (OFF PATH)
│   └── age                        # age binary (downloaded by installer)
├── .keys/                         # 0700 — age identity
│   └── key.txt.age                # Passphrase-protected age identity
└── registry/                      # 0700 directory
    ├── github.conf                # 0600, shell-sourceable metadata
    ├── github.age                 # 0600, age-encrypted token
    ├── gcloud.conf
    ├── gcloud.age
    └── ...
```

## Data Model — Service Registration

Each service has two files:

### Metadata file (`registry/<service>.conf`) — shell-sourceable, not secret
```bash
# registry/github.conf
SERVICE_NAME="github"
AUTH_METHOD="env-var"              # env-var | flag
INJECT_ENV="GH_TOKEN"             # env var name (for env-var method)
INJECT_FLAG=""                     # CLI flag like --token (for flag method)
CREDENTIAL_SOURCE="static"        # static | cli
CLI_COMMAND=""                     # e.g., "gh auth token" (for cli source)
TOKEN_FILE="github.age"           # age-encrypted file (for static source)
CREATED_AT="2026-02-24T..."
LAST_ROTATED="2026-02-24T..."
COMMANDS="gh,git"                  # comma-separated commands this service handles
```

### Credential file (`registry/<service>.age`) — age-encrypted
Contains the raw token, encrypted with the age identity's public key.

### Credential sources

| Source | How it works | Use case |
|--------|-------------|----------|
| `static` | Token stored in age-encrypted file | API tokens, PATs, static secrets |
| `cli` | Runs a native CLI command to get a live token | `gh auth token`, `gcloud auth print-access-token`, `aws sts get-session-token` |

The `cli` source delegates OAuth entirely to the native tool. Those tools already handle:
- OAuth device flows
- Token refresh
- Secure storage (in their own credential stores)
- Cross-platform support

We don't reimplement OAuth — we call the tool that already does it.

## CLI Designs

### `secret-mgr --help`
```
secret-mgr - Credential manager for para-llm-directory

Usage:
  secret-mgr register <service>       Register a new service interactively
  secret-mgr set <service> <token>    Set/update a token (or --stdin)
  secret-mgr get <service>            Decrypt and print credential to stdout
  secret-mgr list                     List registered services
  secret-mgr remove <service>         Remove a service and its encrypted data
  secret-mgr status                   Show services with health info
  secret-mgr import-env <VAR> <svc>   Import from existing env var
  secret-mgr init-keys                Generate age identity (interactive)

Options:
  --help       Show this help
  --quiet      Suppress non-essential output
```

### `secure-exec --help`
```
secure-exec - Run commands with transparent credential injection

Usage:
  secure-exec <command> [args...]     Execute command with credentials
  secure-exec --list-services         List available services
  secure-exec --help                  Show this help

Examples:
  secure-exec gh pr list
  secure-exec curl -s https://api.github.com/user
  secure-exec gcloud storage ls
```

### `secure-exec` core logic (pseudocode)
```bash
main() {
    CMD="$1"; shift
    PASSPHRASE="${_SECURE_EXEC_PASSPHRASE:?Session passphrase not set}"
    AGE_BIN="$PLUGIN_DIR/.bin/age"

    for conf in "$REGISTRY_DIR"/*.conf; do
        source "$conf"
        if matches "$CMD" "$COMMANDS"; then
            case "$CREDENTIAL_SOURCE" in
                static)
                    TOKEN=$(echo "$PASSPHRASE" | \
                        "$AGE_BIN" -d -i "$KEYS_DIR/key.txt.age" \
                        "$REGISTRY_DIR/$TOKEN_FILE")
                    ;;
                cli)
                    TOKEN=$(eval "$CLI_COMMAND")
                    ;;
            esac
            case "$AUTH_METHOD" in
                env-var) export "$INJECT_ENV"="$TOKEN" ;;
                flag)    set -- "$INJECT_FLAG" "$TOKEN" "$@" ;;
            esac
        fi
    done
    exec "$CMD" "$@"
}
```

## Session Lifecycle — Passphrase Management

### Session start (`tmux-new-branch.sh`)

```bash
if [[ "${CRED_MGR_ENABLED:-0}" == "1" ]]; then
    # Generate session passphrase (random, never touches disk as plaintext
    # beyond the secure tmpfile)
    SESSION_PASSPHRASE=$(openssl rand -hex 32)

    # Write to a tmpfile readable only by current user
    PASSPHRASE_FILE="$ENV_DIR/.session-passphrase"
    echo "$SESSION_PASSPHRASE" > "$PASSPHRASE_FILE"
    chmod 0600 "$PASSPHRASE_FILE"

    # secure-exec reads this file; the var is NOT exported to Claude's env
    # Instead, secure-exec.sh reads PASSPHRASE_FILE directly
    PLUGIN_DIR="$SCRIPT_DIR/plugins/credential-mgr"

    # Only add secure-exec to PATH (not secret-mgr, not .bin/)
    tmux send-keys "export PATH=\"$PLUGIN_DIR:\$PATH\"" Enter

    # Set the passphrase file location for secure-exec
    # This env var is benign — it just points to a file.
    # The file requires the age key to be useful, and the age key
    # requires the passphrase to decrypt. Circular dependency
    # prevents exploitation.
    tmux send-keys "export _SECURE_EXEC_PASSFILE=\"$PASSPHRASE_FILE\"" Enter
fi
```

### Session end (`tmux-cleanup-branch.sh`)

```bash
# Destroy session passphrase
rm -f "$ENV_DIR/.session-passphrase"
```

## Integration Points

### `install.sh`
Replace the credential-proxy section with credential-mgr:
- Prompt user to install credential manager plugin
- Run `install-credential-mgr.sh` which:
  - Downloads `age` binary to `$PLUGIN_DIR/.bin/` (0700)
  - Generates age identity with passphrase protection
  - Creates registry directory (0700)
  - Merges deny rules into `.claude/settings.json`
  - Merges PreToolUse hook into global Claude settings (`~/.claude/settings.json`)
  - Optionally walks through registering first service (GitHub)
  - Saves `CRED_MGR_ENABLED=1` to config

### `tmux-new-branch.sh`
Replace `start_credential_proxy()` with `start_credential_mgr()`:
- Generates session passphrase
- Adds `secure-exec` (only) to PATH in the tmux pane
- Sets `_SECURE_EXEC_PASSFILE` env var
- Injects CLAUDE.md snippet into the project's CLAUDE.md

### `install.sh` chmod section
Add chmod for credential-mgr plugin scripts.

## CLAUDE.md Snippet (injected into projects)

```markdown
## Authenticated Services (secure-exec)
Use `secure-exec` to run commands that need authentication:
  secure-exec gh pr list
  secure-exec curl -s https://api.github.com/user
Run `secure-exec --list-services` to see available services.
Do NOT attempt to use `secret-mgr`, `age`, or read credentials directly.
```

## Data Flow Diagrams

### Scenario 1: Human registers a service

```
 Human                      secret-mgr                      age
 ─────                      ──────────                      ───
   │                             │                            │
   │  secret-mgr register       │                            │
   │  github                     │                            │
   │ ──────────────────────────▶│                            │
   │                             │                            │
   │ ◀── "Enter token:"         │                            │
   │ ── ghp_abc123 ───────────▶ │                            │
   │                             │  age -e -R key.pub         │
   │                             │  > registry/github.age     │
   │                             │ ──────────────────────────▶│
   │                             │                            │
   │                             │  Write github.conf         │
   │                             │  (SERVICE_NAME, COMMANDS,  │
   │                             │   AUTH_METHOD, etc.)        │
   │                             │                            │
   │ ◀── "github registered"    │                            │
   │                             │                            │

Token is encrypted at rest. Plaintext never stored on disk.
```

### Scenario 2: Agent runs `secure-exec gh pr list`

```
 Agent (Claude Code)        secure-exec              secret-mgr         age
 ─────────────────         ────────────             ──────────         ───
   │                            │                        │               │
   │  secure-exec gh pr list    │                        │               │
   │ ─────────────────────────▶│                        │               │
   │                            │                        │               │
   │                            │  Match: "gh" →         │               │
   │                            │  github.conf           │               │
   │                            │                        │               │
   │                            │  Read passphrase from   │               │
   │                            │  _SECURE_EXEC_PASSFILE  │               │
   │                            │                        │               │
   │                            │  secret-mgr get github  │               │
   │                            │ ──────────────────────▶│               │
   │                            │                        │  age -d ...   │
   │                            │                        │ ─────────────▶│
   │                            │                        │ ◀── ghp_xxx ─│
   │                            │ ◀── ghp_xxx ─────────  │               │
   │                            │                        │               │
   │                            │  export GH_TOKEN=ghp_xxx               │
   │                            │  exec gh pr list       │               │
   │                            │                        │               │
   │ ◀── (output of gh pr list) │                        │               │
   │                            │                        │               │

Agent sees: list of PRs.
Agent never sees: the token value.
```

### Scenario 3: Agent runs `secure-exec gcloud storage ls` (CLI credential source)

```
 Agent (Claude Code)        secure-exec              gcloud CLI
 ─────────────────         ────────────             ──────────
   │                            │                        │
   │  secure-exec gcloud        │                        │
   │  storage ls                │                        │
   │ ─────────────────────────▶│                        │
   │                            │                        │
   │                            │  Match: "gcloud" →     │
   │                            │  gcloud.conf           │
   │                            │  CREDENTIAL_SOURCE=cli │
   │                            │  CLI_COMMAND="gcloud   │
   │                            │    auth print-access-  │
   │                            │    token"              │
   │                            │                        │
   │                            │  gcloud auth           │
   │                            │  print-access-token    │
   │                            │ ──────────────────────▶│
   │                            │ ◀── ya29.xxxx ────────│
   │                            │                        │
   │                            │  export CLOUDSDK_AUTH_ACCESS_TOKEN=ya29.xxxx
   │                            │  exec gcloud storage ls
   │                            │
   │ ◀── (bucket listing)       │
   │                            │

OAuth handled entirely by gcloud's own credential store.
No age encryption needed — gcloud manages its own tokens.
```

### Scenario 4: Agent tries to access credentials directly (BLOCKED)

```
 Agent (Claude Code)        Claude Code Runtime
 ─────────────────         ──────────────────
   │                            │
   │  Bash: secret-mgr get     │
   │  github                    │
   │ ─────────────────────────▶│
   │                            │
   │  Layer 1: deny rule        │
   │  matches "secret-mgr*"    │
   │ ◀── BLOCKED ──────────────│
   │                            │
   │  (Or if deny rule missed:) │
   │                            │
   │  Layer 2: PreToolUse hook  │
   │  sees "secret-mgr" in cmd │
   │ ◀── BLOCKED ──────────────│
   │                            │
   │  (Or if hook missed:)      │
   │                            │
   │  Layer 3: "secret-mgr"    │
   │  is not on PATH            │
   │ ◀── "command not found" ──│
   │                            │
   │  (Or if agent finds path:) │
   │                            │
   │  Layer 4: age identity     │
   │  requires passphrase that  │
   │  agent doesn't have        │
   │ ◀── decryption failed ────│
   │                            │

Four independent layers. Each sufficient on its own.
```

## Prerequisites

- **`age`** — Single static binary (~5MB). No runtime dependencies. Cross-platform (mac/linux/windows).
  - Install: `brew install age` / `apt install age` / download from [github.com/FiloSottile/age](https://github.com/FiloSottile/age)
  - The installer downloads it automatically to `$PLUGIN_DIR/.bin/`
- **`jq`** — For JSON parsing in hooks (commonly pre-installed)
- **`openssl`** — For session passphrase generation (pre-installed on all platforms)

No server infrastructure. No Vault. No cloud dependencies.

## Configuration

Stored in `$PARA_LLM_ROOT/config` (same as other para-llm settings):

```bash
# Credential manager settings
CRED_MGR_ENABLED=1
CRED_MGR_PLUGIN_DIR="$INSTALL_DIR/plugins/credential-mgr"
```

Per-service configuration lives in the registry `.conf` files (see Data Model above).

## Comparison: v3 (Vault) vs v4 (secret-mgr + age)

```
v3: Orchestrator → Vault Server → Cloud Provider → ephemeral cred → env var → Agent
    Agent sees credential. Requires Vault server infrastructure.
    Security relies on: short TTL + scoped IAM + Vault lease revocation.

v4: Human → secret-mgr → age encrypt → disk
    Agent → secure-exec → secret-mgr → age decrypt → env var → exec command
    Agent never sees credential. No server infrastructure.
    Security relies on: 4 isolation layers + age encryption + passphrase.

v3 is better when: you already run Vault, need dynamic secrets, need audit logs.
v4 is better when: you want simplicity, offline support, no server infra, cross-platform.
Both are valid. v4 is the default; v3 is an advanced option for orgs with Vault.
```

## When to Use Vault (v3) Instead

v4 is sufficient when:
- Individual developer or small team
- Static tokens or CLI-managed OAuth
- No centralized audit requirements
- Want minimal infrastructure

Consider v3 (Vault) when:
- Organization already runs Vault
- Need centralized credential audit trail
- Need dynamic/ephemeral secrets from Vault secrets engines
- Multi-tenant environment with policy-based access
- Regulatory requirements mandate server-side credential management

## Phased Implementation

### Phase 1 — MVP (this PR)
1. Create `plugins/credential-mgr/` directory structure
2. Implement `secret-mgr.sh`: `register`, `set`, `get`, `list`, `remove`, `status`, `import-env`, `init-keys`
3. Implement `secure-exec.sh`: command matching, env-var injection, `--list-services`, `--help`
4. Implement `lib/store.sh`: age encrypt/decrypt helpers
5. Implement `lib/inject.sh`: env-var and flag injection
6. Create `services.d/github.sh` service definition template
7. Create `hooks/deny-secret-mgr.sh` + `config/hooks-config.json`
8. Add deny rules to `.claude/settings.json`
9. Create `install-credential-mgr.sh` (download age, init keys, create dirs)
10. Update `install.sh` to replace credential-proxy with credential-mgr
11. Update `tmux-new-branch.sh` to use `start_credential_mgr()` with session passphrase
12. Create `config/claude-md-snippet.md`

### Phase 2 — More services + flag injection (future)
- Service definitions for gcloud, aws, docker
- Flag-based injection method (for tools that don't use env vars)
- `secret-mgr rotate` command for token rotation tracking
- Config-file injection (write temp config file, clean up after exec)

### Phase 3 — Vault integration as optional backend (future)
- `CREDENTIAL_SOURCE="vault"` for dynamic secrets
- Vault lease tracking and revocation
- Vault AppRole authentication
- Can coexist with static/cli sources per-service

## Verification

1. `secret-mgr init-keys` → generates passphrase-protected age identity
2. `secret-mgr register github` → interactively register GitHub
3. `secret-mgr set github ghp_test123` → encrypts and stores token
4. `secret-mgr get github` → decrypts and prints token
5. `secret-mgr list` → shows github service
6. `secure-exec gh pr list` → succeeds with injected GH_TOKEN
7. `secure-exec --list-services` → shows github
8. Verify agent cannot run `secret-mgr` (Layer 1: deny rules)
9. Verify agent cannot run `age` (Layer 2: hook blocks it)
10. Verify `secret-mgr` not on agent PATH (Layer 3)
11. Verify age identity requires passphrase (Layer 4)
12. Run `install.sh` and confirm credential-mgr plugin installs correctly
13. Full lifecycle: register service → start tmux session → agent uses secure-exec → session cleanup destroys passphrase
