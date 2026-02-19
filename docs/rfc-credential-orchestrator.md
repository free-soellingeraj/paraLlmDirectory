# RFC: Credential Orchestrator Plugin for para-llm-directory

## Context

Autonomous Claude Code agents running in para-llm tmux panes need to interact with authenticated services (APIs, git remotes, Docker registries, cloud CLIs). Today there's no credential management — agents either can't authenticate or would need raw secrets exposed in their environment.

**Goal**: Build a credential orchestration layer where agents can use authenticated tools transparently, but **never see raw secret values**. The system uses each tool's best-available auth mechanism and fetches secrets from a pluggable backend (GCP Secret Manager first).

## Architecture Overview

```
  Agent's tmux pane (Claude Code)
  │
  │  HTTP requests         CLI commands
  │  ───────────┐         ─────────────┐
  │             │                      │
  │    ┌────────▼──────────┐  ┌────────▼──────────┐
  │    │  MITM HTTP Proxy  │  │  Credential        │
  │    │  (mitmproxy)      │  │  Helpers / OAuth    │
  │    │  - header inject  │  │  - git-credential   │
  │    │  - per host/path  │  │  - docker-credential│
  │    │  - secrets in     │  │  - gcloud SA impersonation
  │    │    process memory  │  │  - gh auth (OAuth)  │
  │    └────────┬──────────┘  └────────┬──────────┘
  │             │                      │
  │    ┌────────▼──────────────────────▼──────────┐
  │    │         Provider Plugin Layer             │
  │    │  gcp-secrets.sh | 1password.sh | file.sh  │
  │    └────────┬──────────────────────────────────┘
  │             │
  │    ┌────────▼──────────┐
  │    │  Root of Trust     │
  │    │  (GCP, 1Password,  │
  │    │   Vault, etc.)     │
  │    └───────────────────┘
```

## Tiered Auth Strategies (Best → Fallback)

### Tier 1: OAuth / Service Account Impersonation
- **gcloud**: `gcloud auth login` + service account impersonation. Tokens managed by gcloud SDK in its own config dir. Agent runs `gcloud` commands normally.
- **gh** (GitHub CLI): OAuth device flow. Tokens stored in `gh` config. Agent runs `gh` normally.
- **az** (Azure CLI): OAuth device flow.
- **Setup**: One-time interactive OAuth flow during `install.sh` or first env creation. Refresh tokens handle the rest.
- **Isolation**: Tokens live in tool-specific config dirs that are standard locations. Agent *could* read them but has no reason to. The CLAUDE.md instructions + Claude Code permission denylists prevent `cat`-ing credential files.

### Tier 2: Credential Helpers (tool-native, secrets invisible)
Tools with credential helper support get custom helpers that fetch from the provider backend:
- **git**: `credential.helper` → custom `para-llm-git-credential` script
- **docker**: `credHelpers` in `~/.docker/config.json` → custom `docker-credential-para-llm` helper
- **npm**: `.npmrc` pointing to credential helper via `_authToken` from `$(para-llm-cred get npm-token)`
- **Isolation**: The helper is invoked BY the tool as a subprocess. Secret passes through a pipe to the tool process. Agent never captures the output. The helper binary is a simple Bash script calling the provider.

### Tier 3: HTTP Proxy (secrets only in proxy process memory)
For REST API calls, private package registries, and any HTTP-based auth:
- MITM proxy (mitmproxy) intercepts HTTPS, matches host/path rules, injects headers
- Proxy CA cert trusted system-wide so TLS works transparently
- Agent sees `HTTP_PROXY`/`HTTPS_PROXY` env vars (these are just `localhost:port`, not secrets)
- **Isolation**: Secrets exist only in the mitmproxy process memory. Agent cannot read another process's memory.

### Tier 4: Restricted Config Files (fallback for odd tools)
For tools that support none of the above:
- Config files populated from provider at env start, 0600 permissions
- Cleaned up at env stop
- CLAUDE.md + denylist prevents agent from reading them
- Less ideal but practical for edge cases (e.g., `kubectl` with kubeconfig, `terraform` cloud tokens)

## Plugin Directory Structure

```
plugins/credential-proxy/
├── README.md
├── orchestrator.sh            # Main entry: start/stop/status all credential services
├── proxy/
│   ├── proxy-manager.sh       # Start/stop mitmproxy per-env
│   ├── credential-inject.py   # mitmproxy addon (header injection)
│   └── ca/
│       ├── generate-ca.sh     # Generate local CA cert+key
│       └── trust-ca.sh        # Add CA to macOS keychain
├── helpers/
│   ├── para-llm-git-credential.sh    # git credential helper
│   ├── docker-credential-para-llm.sh # docker credential helper
│   └── setup-helpers.sh              # Install/configure credential helpers
├── oauth/
│   ├── setup-oauth.sh         # Run OAuth flows for gcloud, gh, etc.
│   └── verify-oauth.sh        # Check if OAuth tokens are still valid
├── providers/
│   ├── provider-interface.md  # Documents the provider contract
│   ├── gcp-secrets.sh         # GCP Secret Manager provider
│   ├── env-var.sh             # Read from env var (testing)
│   └── file.sh                # Read from file (testing)
├── config/
│   ├── credentials.example.yaml  # Example configuration
│   └── claude-md-snippet.md      # CLAUDE.md template for agent awareness
└── install-credential-proxy.sh   # Installation sub-script
```

## Configuration Format

File: `$PARA_LLM_ROOT/plugins/credential-proxy/credentials.yaml`
Per-project override: `<project-root>/.para-llm/credentials.yaml`

```yaml
version: 1

settings:
  cache_ttl: 300          # seconds to cache resolved secrets in proxy memory
  retry_on_401: true      # invalidate cache + re-fetch on 401 responses
  default_provider: gcp-secrets

# Provider configuration
providers:
  gcp-secrets:
    project: my-gcp-project    # default GCP project for secrets

# Tier 1: OAuth / CLI auth (agent just uses the CLI normally)
oauth:
  gcloud:
    enabled: true
    strategy: service-account-impersonation
    service_account: my-sa@project.iam.gserviceaccount.com
  gh:
    enabled: true
    strategy: oauth-device-flow
  # az:
  #   enabled: false

# Tier 2: Credential helpers (tool-native, secret invisible)
credential_helpers:
  git:
    enabled: true
    provider: gcp-secrets
    secret_ref: github-pat     # secret name in GCP
  docker:
    enabled: true
    registries:
      ghcr.io:
        provider: gcp-secrets
        secret_ref: ghcr-token
      us-docker.pkg.dev:
        provider: gcp-secrets
        secret_ref: gar-token
  npm:
    enabled: false
    registry: https://npm.internal.example.com
    secret_ref: npm-token

# Tier 3: HTTP proxy rules (header injection for API calls)
http_proxy:
  enabled: true
  port_base: 18080           # each env gets port_base + N
  rules:
    - name: "Internal API"
      match:
        host: "api.internal.example.com"
      inject:
        headers:
          Authorization: "Bearer {secret:api-internal-token}"

    - name: "Third-party API"
      match:
        host: "api.thirdparty.com"
        path_prefix: "/v2/"
      inject:
        headers:
          X-API-Key: "{secret:thirdparty-api-key}"

  # Don't proxy these hosts (bypass)
  passthrough:
    - "api.anthropic.com"
    - "*.anthropic.com"

# Tier 4: Config file population (fallback)
config_files:
  kubectl:
    enabled: false
    template: "~/.kube/config.template"
    output: "~/.kube/config"
    secrets:
      CLUSTER_TOKEN: "k8s-cluster-token"
```

## Provider Plugin Interface

Each provider is a shell script in `providers/`. Contract:

```bash
# $1 = action: "get" | "health"
# $2 = secret reference name
# $3+ = optional key=value config pairs
#
# get: print secret value to stdout, exit 0. On failure: stderr + exit 1.
# health: print "ok" to stdout if backend is reachable, exit 0. Otherwise exit 1.
#
# Environment: PARA_LLM_ROOT is always set.
```

**gcp-secrets.sh** (first implementation):
```bash
#!/usr/bin/env bash
set -euo pipefail
ACTION="${1:?}"; SECRET_REF="${2:?}"; shift 2
GCP_PROJECT=""
for arg in "$@"; do
    case "$arg" in project=*) GCP_PROJECT="${arg#project=}" ;; esac
done
case "$ACTION" in
    get)
        if [[ -n "$GCP_PROJECT" ]]; then
            gcloud secrets versions access latest --secret="$SECRET_REF" --project="$GCP_PROJECT"
        else
            gcloud secrets versions access latest --secret="$SECRET_REF"
        fi ;;
    health)
        gcloud auth print-access-token >/dev/null 2>&1 && echo "ok" || { echo "not authenticated" >&2; exit 1; } ;;
esac
```

## Credential Helper Implementation

### Git Credential Helper

`helpers/para-llm-git-credential.sh`:
```bash
#!/usr/bin/env bash
# Called by git as: git-credential-para-llm get
# Reads host from stdin, fetches token from provider, outputs to stdout
set -euo pipefail
ACTION="$1"
[[ "$ACTION" != "get" ]] && exit 0

# Parse git's input (protocol, host, path)
declare -A INPUT=()
while IFS='=' read -r key value; do
    [[ -z "$key" ]] && break
    INPUT[$key]="$value"
done

HOST="${INPUT[host]:-}"
PROVIDER_DIR="$PARA_LLM_ROOT/plugins/credential-proxy/providers"
# Look up which secret_ref to use for this host from config
SECRET_REF=$(yq ".credential_helpers.git.secret_ref" "$CONFIG_FILE")
TOKEN=$("$PROVIDER_DIR/gcp-secrets.sh" get "$SECRET_REF")

echo "protocol=${INPUT[protocol]:-https}"
echo "host=$HOST"
echo "username=x-token"
echo "password=$TOKEN"
```

Installed via: `git config --global credential.helper "/path/to/para-llm-git-credential.sh"`

### Docker Credential Helper

`helpers/docker-credential-para-llm.sh` — follows the [docker credential helper protocol](https://docs.docker.com/engine/reference/commandline/login/#credential-helpers):
- `get` (stdin: registry URL) → output JSON `{"Username":"x","Secret":"<token>"}`
- `store` / `erase` → no-op (secrets managed by backend)

Installed via `~/.docker/config.json`:
```json
{ "credHelpers": { "ghcr.io": "para-llm" } }
```

## Strict Isolation Enforcement

**How secrets are prevented from reaching the agent LLM:**

| Channel | Protection |
|---------|-----------|
| HTTP proxy | Secrets in mitmproxy process memory only. Agent can't read another process's memory. |
| Credential helpers | Secret passes through pipe from helper → tool. Agent doesn't invoke the helper directly. |
| OAuth tokens | Stored in tool-specific config dirs (e.g., `~/.config/gcloud/`). Agent has no reason to read these. |
| Environment variables | Only `HTTP_PROXY`, `HTTPS_PROXY`, CA cert paths — **never** actual secrets. |
| Denylist enforcement | Add to `.claude/settings.json`: deny `Bash(cat ~/.config/gcloud/*)`, `Bash(cat ~/.docker/*)`, etc. |
| CLAUDE.md instructions | Agent is told not to look for secrets — auth "just works." |
| File permissions | Tier 4 config files get 0600 permissions. |

**New deny rules for `.claude/settings.json`:**
```json
"Bash(cat ~/.config/gcloud/*)",
"Bash(cat ~/.docker/config.json)",
"Bash(cat ~/.npmrc)",
"Bash(cat ~/.kube/config)",
"Bash(cat *credential*)",
"Bash(cat *secret*)",
"Bash(cat *token*)",
"Bash(env | grep -i secret*)",
"Bash(env | grep -i token*)",
"Bash(env | grep -i password*)"
```

## Installation Flow

Added to `install.sh` as optional plugin (following STT pattern):

1. **Prompt**: "Install credential proxy plugin? Provides transparent auth for agent tools."
2. **Install mitmproxy**: `brew install mitmproxy` or `pip3 install mitmproxy`
3. **Install yq**: `brew install yq` (YAML processing for config)
4. **Generate CA**: `openssl req -x509 ...` → `$PARA_LLM_ROOT/plugins/credential-proxy/proxy/ca/`
5. **Trust CA**: `sudo security add-trusted-cert ...` on macOS keychain
6. **Copy plugin files** to `$PARA_LLM_ROOT/plugins/credential-proxy/`
7. **Create default config** from `credentials.example.yaml`
8. **Run OAuth flows** (interactive): `gcloud auth login`, `gh auth login` etc. (skippable)
9. **Install credential helpers**: git credential helper, docker credential helper
10. **Update `.claude/settings.json`**: add denylist rules for credential file reads
11. **Save config**: `CRED_PROXY_ENABLED=1` in `$PARA_LLM_ROOT/config`

## Environment Lifecycle Integration

### On `tmux-new-branch.sh` (create/resume):

```bash
if [[ "${CRED_PROXY_ENABLED:-0}" == "1" ]]; then
    # 1. Verify provider health
    "$PLUGIN_DIR/providers/gcp-secrets.sh" health || warn "GCP secrets unreachable"

    # 2. Verify OAuth tokens are fresh
    "$PLUGIN_DIR/oauth/verify-oauth.sh"

    # 3. Start HTTP proxy for this env (if enabled)
    PROXY_PORT=$("$PLUGIN_DIR/proxy/proxy-manager.sh" start \
        --env-dir "$ENV_DIR" --project "$REPO_NAME" --branch "$BRANCH_NAME")

    # 4. Inject proxy env vars into the pane (before launching claude)
    tmux send-keys "export HTTP_PROXY=http://127.0.0.1:$PROXY_PORT" Enter
    tmux send-keys "export HTTPS_PROXY=http://127.0.0.1:$PROXY_PORT" Enter
    tmux send-keys "export NODE_EXTRA_CA_CERTS=$CA_CERT" Enter
    tmux send-keys "export REQUESTS_CA_BUNDLE=$CA_CERT" Enter
    tmux send-keys "export SSL_CERT_FILE=$CA_CERT" Enter
    tmux send-keys "export GIT_SSL_CAINFO=$CA_CERT" Enter

    # 5. Append CLAUDE.md snippet to env's project (if not already present)
    "$PLUGIN_DIR/orchestrator.sh" inject-claude-md "$ENV_DIR/$REPO_NAME"
fi
```

### On `tmux-cleanup-branch.sh` (cleanup):

```bash
if [[ -f "$ENV_DIR/.credential-proxy.pid" ]]; then
    "$PLUGIN_DIR/proxy/proxy-manager.sh" stop --env-dir "$ENV_DIR"
fi
```

### Proxy Manager (proxy-manager.sh):

- `start`: Find available port, resolve rules file (project-level > global), start `mitmdump` in background, write PID + port files
- `stop`: Kill proxy process, clean up PID/port files
- `status`: Check if proxy is running, report port
- Idempotent: `start` checks if already running before spawning new instance

## CLAUDE.md Template for Agent Awareness

Injected into each environment's project:

```markdown
## Authenticated Services (Credential Proxy)

This environment has transparent authentication for external services.
You do NOT need to handle authentication yourself.

### How it works
- HTTP traffic goes through a local proxy that injects auth headers
- CLI tools (git, docker, gcloud, gh) are pre-authenticated via credential helpers
- Secret values never appear in your environment or shell history

### What this means for you
- **Do NOT** set Authorization headers, API keys, or tokens manually
- **Do NOT** look for .env files, credentials, or secrets
- **Do NOT** run auth commands (gcloud auth, gh auth, docker login, npm login)
- Just use tools normally — authentication happens transparently
- If you get a 401/403, tell the user — the credential config likely needs updating
```

## Implementation Sequence

1. Create plugin directory structure + scaffold scripts
2. Implement provider interface + `gcp-secrets.sh` provider
3. Implement CA generation and trust (`ca/generate-ca.sh`, `ca/trust-ca.sh`)
4. Implement mitmproxy addon (`credential-inject.py`) with rule matching + header injection
5. Implement `proxy-manager.sh` (start/stop/status)
6. Implement git credential helper (`para-llm-git-credential.sh`)
7. Implement docker credential helper (`docker-credential-para-llm.sh`)
8. Implement `orchestrator.sh` (unified start/stop for all credential services)
9. Implement OAuth setup + verify scripts
10. Add installation section to `install.sh` (following STT plugin pattern)
11. Integrate with `tmux-new-branch.sh` (proxy start + env var injection + CLAUDE.md)
12. Integrate with `tmux-cleanup-branch.sh` (proxy stop)
13. Update `.claude/settings.json` denylist template
14. Create example `credentials.yaml` and documentation

## Critical Files to Modify

- `install.sh` — add credential proxy optional install section (~lines 112-170 area, after STT)
- `tmux-new-branch.sh` — add proxy start + env injection before Claude launch
- `tmux-cleanup-branch.sh` — add proxy stop before env deletion
- `para-llm-config.sh` — export `CRED_PROXY_ENABLED` and related vars
- `.claude/settings.json` — add credential-file-read deny rules
- `plugins/claude-state-monitor/hooks/hooks-config.json` — no changes needed (credential proxy is orthogonal to state monitoring)

## Verification

1. **Provider health**: `gcp-secrets.sh health` returns "ok"
2. **Proxy starts**: `proxy-manager.sh start` → `curl -x http://localhost:$PORT http://httpbin.org/get` works
3. **Header injection**: Configure a test rule, verify injected header via `curl -x ... http://httpbin.org/headers`
4. **Git credential helper**: `git clone` from private repo succeeds without prompting
5. **Docker credential helper**: `docker pull` from private registry succeeds
6. **Agent isolation**: Claude Code session cannot `cat` credential files (denylist blocks it)
7. **Full lifecycle**: Create env → proxy starts → agent uses authenticated tools → cleanup → proxy stops
8. **Proxy failure**: Kill proxy → agent gets "connection refused" (not silent auth bypass)
