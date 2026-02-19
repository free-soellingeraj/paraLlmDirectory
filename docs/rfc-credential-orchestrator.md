# RFC: Credential Orchestrator Plugin for para-llm-directory (v2 — Compose Existing Tools)

## Context

Autonomous Claude Code agents running in para-llm tmux panes need to interact with authenticated services (APIs, git remotes, Docker registries, cloud CLIs). Today there's no credential management — agents either can't authenticate or would need raw secrets exposed in their environment.

**Goal**: Transparent credential orchestration where agents **never see raw secret values**.

## What Changed (v1 → v2)

v1 proposed building everything from scratch: custom mitmproxy addon, custom git/docker credential helpers, custom provider plugin system, custom YAML config format. That's a large surface area to maintain.

v2 composes existing, maintained tools:

| Concern | v1 (build from scratch) | v2 (compose existing tools) |
|---------|------------------------|----------------------------|
| HTTP proxy | Custom mitmproxy addon + proxy-manager.sh | **Secretless Broker** (CyberArk, 366 stars, production-grade) |
| Git credentials | Custom `para-llm-git-credential.sh` | **credential-1password** or **git-credential-oauth** (existing helpers) |
| Docker credentials | Custom `docker-credential-para-llm.sh` | **credential-1password** or native `docker-credential-gcloud` |
| Secret backend | Custom provider plugin system (3 scripts) | **1Password CLI** / **gcloud CLI** / **Vault** (use directly) |
| OAuth flows | Custom setup-oauth.sh + verify-oauth.sh | Just run `gcloud auth login`, `gh auth login` directly (they manage their own tokens) |
| Config format | Custom credentials.yaml + yq dependency | Secretless Broker's native `secretless.yml` + existing tool configs |
| CA management | Custom generate-ca.sh + trust-ca.sh | Secretless Broker handles its own TLS termination |
| Our code | ~1,900 lines across 18 new files | ~200 lines: thin orchestrator + install script |

## Architecture Overview

```
  Agent's tmux pane (Claude Code)
  │
  │  HTTP requests              CLI commands
  │  ───────────┐              ─────────────┐
  │             │                           │
  │    ┌────────▼──────────┐    ┌───────────▼───────────────┐
  │    │ Secretless Broker │    │  Existing credential       │
  │    │ (CyberArk)        │    │  helpers / native auth     │
  │    │ - header injection │    │  - git-credential-oauth    │
  │    │ - per host/path    │    │  - credential-1password    │
  │    │ - secrets in       │    │  - docker-credential-gcloud│
  │    │   process memory   │    │  - gcloud auth (native)    │
  │    └────────┬──────────┘    │  - gh auth (native)        │
  │             │               └───────────┬───────────────┘
  │    ┌────────▼───────────────────────────▼──────┐
  │    │           Secret Backend (pick one)        │
  │    │  1Password | GCP Secret Manager | Vault    │
  │    └───────────────────────────────────────────┘
```

## Component Breakdown

### 1. HTTP Proxy — Secretless Broker

[CyberArk Secretless Broker](https://github.com/cyberark/secretless-broker) is a production-grade connection broker that:
- Intercepts HTTP(S) traffic via `HTTP_PROXY` / `HTTPS_PROXY`
- Injects credentials from configurable backends (vault, env, file, keychain)
- Keeps secrets only in its own process memory
- Written in Go, single binary, actively maintained

**Config** (`secretless.yml`):
```yaml
version: 2
services:
  internal-api:
    protocol: http
    listenOn: tcp://0.0.0.0:18080
    credentials:
      api-token:
        from: vault
        get: secret/data/internal-api-token#value
    config:
      authenticationStrategy: header
      headers:
        Authorization: "Bearer {{ .api-token }}"
      match:
        - host: "api.internal.example.com"

  thirdparty:
    protocol: http
    listenOn: tcp://0.0.0.0:18080
    credentials:
      api-key:
        from: vault
        get: secret/data/thirdparty-key#value
    config:
      authenticationStrategy: header
      headers:
        X-API-Key: "{{ .api-key }}"
      match:
        - host: "api.thirdparty.com"
          pathPrefix: "/v2/"
```

**What we write**: Just a `secretless-manager.sh` (~50 lines) to start/stop Secretless Broker per environment and set `HTTP_PROXY`.

### 2. Git Credentials — Existing Helpers

Multiple mature options exist:

**Option A: git-credential-oauth** (if using GitHub/GitLab OAuth)
- `brew install git-credential-oauth`
- Handles OAuth device flow automatically
- No PATs needed

**Option B: credential-1password** (if using 1Password)
- [github.com/tlowerison/credential-1password](https://github.com/tlowerison/credential-1password)
- Works as both git and docker credential helper
- Reads from 1Password vault

**Option C: git-credential-store with `op run`** (1Password CLI)
- `op run --env-file=.env -- git push` injects credentials into subprocess

**What we write**: Nothing. We configure the user's chosen helper during install.

### 3. Docker Credentials — Existing Helpers

- **docker-credential-gcloud** — built into gcloud SDK, handles GCR/GAR natively
- **credential-1password** — same tool as git, also implements docker credential helper protocol
- **docker-credential-ecr-login** — AWS ECR native helper

**What we write**: Nothing. We configure `~/.docker/config.json` during install.

### 4. Cloud CLIs — Native Auth (Already Solved)

These tools already handle their own credential lifecycle:

- **gcloud**: `gcloud auth login` → stores refresh token in `~/.config/gcloud/`. Optionally add SA impersonation via `gcloud config set auth/impersonate_service_account`.
- **gh**: `gh auth login` → stores OAuth token in `~/.config/gh/`. Automatic refresh.
- **az**: `az login` → stores token in `~/.azure/`. Automatic refresh.

**What we write**: Nothing. We prompt during install, verify during env creation.

### 5. Agent Isolation — Denylist + CLAUDE.md

Same as v1, this is just config:
- `.claude/settings.json` deny rules prevent agent from reading credential files
- CLAUDE.md snippet tells agent auth is handled transparently
- File permissions (0600) on any config files

## Plugin Directory Structure (Dramatically Simpler)

```
plugins/credential-auth/
├── README.md
├── orchestrator.sh              # Start/stop/status all credential services (~100 lines)
├── install-credential-auth.sh   # Install + configure third-party tools (~100 lines)
├── config/
│   ├── secretless.example.yml   # Example Secretless Broker config
│   └── claude-md-snippet.md     # CLAUDE.md template for agent awareness
└── verify-auth.sh               # Check all auth tools are working (~50 lines)
```

**4 files we write** vs. 18 in v1.

## Installation Flow

```
1. "Install credential auth plugin?"

2. Choose secret backend:
   a) 1Password   → brew install 1password-cli, op signin
   b) GCP         → ensure gcloud installed + authenticated
   c) HashiCorp   → ensure vault CLI installed + authenticated

3. Choose HTTP proxy (if needed):
   → brew install secretless-broker  (or skip if no API auth needed)

4. Set up CLI auth:
   → gcloud auth login (if gcloud installed)
   → gh auth login (if gh installed)
   → Configure git credential helper (git-credential-oauth or credential-1password)
   → Configure docker credential helper (native or credential-1password)

5. Generate secretless.yml from template (if HTTP proxy enabled)

6. Add denylist rules to .claude/settings.json

7. Save CRED_AUTH_ENABLED=1 to config
```

## Environment Lifecycle Integration

### On `tmux-new-branch.sh` (create/resume):

```bash
if [[ "${CRED_AUTH_ENABLED:-0}" == "1" ]]; then
    # 1. Verify auth is healthy (non-blocking)
    "$PLUGIN_DIR/verify-auth.sh" --quiet || echo "Warning: auth needs refresh"

    # 2. Start Secretless Broker for this env (if configured)
    if [[ -f "$SECRETLESS_CONFIG" ]]; then
        PROXY_PORT=$("$PLUGIN_DIR/orchestrator.sh" start --env-dir "$ENV_DIR")
        tmux send-keys "export HTTP_PROXY=http://127.0.0.1:$PROXY_PORT" Enter
        tmux send-keys "export HTTPS_PROXY=http://127.0.0.1:$PROXY_PORT" Enter
    fi

    # 3. Inject CLAUDE.md snippet
    "$PLUGIN_DIR/orchestrator.sh" inject-claude-md "$PROJECT_DIR"
fi
```

### On `tmux-cleanup-branch.sh` (cleanup):

```bash
if [[ -f "$ENV_DIR/.secretless.pid" ]]; then
    "$PLUGIN_DIR/orchestrator.sh" stop --env-dir "$ENV_DIR"
fi
```

## What We're NOT Building

| Thing | Why not |
|-------|---------|
| Custom mitmproxy addon (credential-inject.py) | Secretless Broker does this better |
| Custom CA generation + trust | Secretless Broker handles TLS |
| Custom provider plugin system | Use backends directly (1Password CLI, gcloud, vault) |
| Custom YAML config format + yq dependency | Use Secretless Broker's native config |
| Custom git credential helper | Use git-credential-oauth or credential-1password |
| Custom docker credential helper | Use credential-1password or docker-credential-gcloud |
| Custom OAuth flow scripts | CLIs manage their own tokens |
| Secret caching layer | Secretless Broker has its own caching |

## Trade-offs

**Pros of v2:**
- ~90% less code to maintain
- Battle-tested tools (CyberArk, 1Password, Google) handle the hard parts
- Each tool has its own docs, community, and update cycle
- Faster to implement and ship

**Cons of v2:**
- More external dependencies to install (secretless-broker, credential helpers)
- Less unified config (Secretless Broker has its own YAML, git/docker have separate configs)
- User chooses a secret backend upfront (less flexible than v1's pluggable providers)
- Secretless Broker is a Go binary (~30MB) vs. mitmproxy (Python, already common)

## Verification

1. **Secretless Broker starts**: `orchestrator.sh start` → `curl -x http://localhost:$PORT http://httpbin.org/get` works
2. **Header injection**: Configure a test rule, verify via `curl -x ... http://httpbin.org/headers`
3. **Git auth**: `git clone` from private repo succeeds without prompting
4. **Docker auth**: `docker pull` from private registry succeeds
5. **CLI auth**: `gcloud`, `gh` commands work without re-authentication
6. **Agent isolation**: Claude Code cannot `cat` credential files (denylist blocks it)
7. **Full lifecycle**: Create env → proxy starts → agent works → cleanup → proxy stops

## Implementation Sequence

1. Write `install-credential-auth.sh` (interactive installer, ~100 lines)
2. Write `orchestrator.sh` (start/stop Secretless Broker + CLAUDE.md injection, ~100 lines)
3. Write `verify-auth.sh` (check all configured tools, ~50 lines)
4. Create `secretless.example.yml` and `claude-md-snippet.md`
5. Integrate with `tmux-new-branch.sh` (proxy start + env var injection)
6. Integrate with `tmux-cleanup-branch.sh` (proxy stop)
7. Update `.claude/settings.json` denylist template
8. Add install section to `install.sh`
