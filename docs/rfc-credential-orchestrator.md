# RFC: Credential Orchestrator Plugin for para-llm-directory (v3 — Vault Ephemeral Credentials)

## Context

Autonomous Claude Code agents running in para-llm tmux panes need to interact with authenticated services (APIs, git remotes, Docker registries, cloud CLIs). Today there's no credential management — agents either can't authenticate or would need raw secrets exposed in their environment.

**Goal**: Agents get working credentials with minimal complexity and strong security properties.

## Evolution: v1 → v2 → v3

| Version | Approach | Code we write | Complexity |
|---------|----------|---------------|------------|
| v1 | Build everything from scratch (custom mitmproxy addon, custom credential helpers, custom provider plugins) | ~1,900 lines, 18 files | Very high |
| v2 | Compose existing tools (Secretless Broker, credential-1password, git-credential-oauth) | ~200 lines, 4 files | Medium |
| **v3** | **Vault generates ephemeral credentials, injected as env vars. No proxy, no custom helpers.** | **~150 lines, 3 files** | **Low** |

### Why v3?

v1 and v2 both try to prevent the agent from ever *seeing* a secret. This requires interposing on every credential channel (HTTP proxy, credential helper pipes, file permissions, denylists). That's a lot of moving parts.

v3 asks a different question: **does it matter if the agent sees a credential that expires in 1 hour and is scoped to minimum permissions?**

| Threat | Long-lived credential | Ephemeral (1h TTL, scoped) |
|--------|----------------------|---------------------------|
| Agent exfiltrates credential | Permanent unauthorized access | Useless after expiry |
| Credential appears in logs | Permanent risk | Already expired |
| Agent shares cred with external system | Long-term access | Brief window, auto-expires |
| Credential committed to code | Permanent risk | Expired before review |
| Lateral movement | Depends on scope | Tightly scoped IAM role |

For developer-facing AI agents in trusted environments, **ephemeral + scoped** is sufficient security for v1 of this feature. The proxy/credential-helper architecture (v2) remains available as a hardening layer for higher-risk deployments later.

## Architecture Overview

```
  Orchestrator (runs before agent session)
  │
  │  1. Authenticate to Vault
  │  2. Generate ephemeral credentials
  │  3. Inject as env vars into tmux pane
  │  4. Launch Claude Code
  │
  ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Agent's tmux pane (Claude Code)                                     │
│                                                                      │
│  Environment:                                                        │
│    GITHUB_TOKEN=ghs_xxxx         (1h TTL, repo:read + repo:write)    │
│    GCP_ACCESS_TOKEN=ya29.xxxx    (1h TTL, storage.objectViewer)      │
│    AWS_ACCESS_KEY_ID=AKIA...     (1h TTL, s3:GetObject only)         │
│    AWS_SECRET_ACCESS_KEY=xxxx    (1h TTL)                            │
│    DOCKER_TOKEN=dckr_xxxx        (1h TTL, pull-only)                 │
│                                                                      │
│  Agent uses these normally. They expire automatically.               │
└──────────────────────────────────────────────────────────────────────┘
  │
  │  Session ends (Ctrl+b k or env cleanup)
  │
  ▼
  Orchestrator revokes all Vault leases immediately
  (credentials invalid even before TTL expiry)
```

## Data Flow Diagrams

### Scenario 1: Session startup — Vault issues ephemeral credentials

```
 Orchestrator                  Vault Server               Cloud Providers
 (tmux-new-branch.sh)         ────────────               ───────────────
       │                            │                           │
       │  vault login               │                           │
       │  (AppRole / OIDC)          │                           │
       │ ──────────────────────▶    │                           │
       │                            │                           │
       │ ◀── vault token ─────────  │                           │
       │                            │                           │
       │  vault read                │                           │
       │  gcp/token/agent-role      │                           │
       │ ──────────────────────▶    │                           │
       │                            │ ── create OAuth token ──▶ │ (GCP IAM)
       │                            │ ◀── ya29.xxxx (1h TTL) ── │
       │ ◀── token + lease_id ────  │                           │
       │                            │                           │
       │  vault read                │                           │
       │  github/token              │                           │
       │ ──────────────────────▶    │                           │
       │                            │ ── create install token ▶ │ (GitHub App)
       │                            │ ◀── ghs_xxxx (1h TTL) ──  │
       │ ◀── token + lease_id ────  │                           │
       │                            │                           │
       │  vault read                │                           │
       │  aws/creds/agent-role      │                           │
       │ ──────────────────────▶    │                           │
       │                            │ ── STS AssumeRole ──────▶ │ (AWS IAM)
       │                            │ ◀── temp creds (1h) ────  │
       │ ◀── creds + lease_id ───   │                           │
       │                            │                           │
       │                            │                           │
       │  Save lease IDs to         │                           │
       │  $ENV_DIR/.vault-leases    │                           │
       │                            │                           │
       │  Inject into tmux pane:    │                           │
       │  export GCP_ACCESS_TOKEN=ya29.xxxx                     │
       │  export GITHUB_TOKEN=ghs_xxxx                          │
       │  export AWS_ACCESS_KEY_ID=AKIA...                      │
       │  export AWS_SECRET_ACCESS_KEY=xxxx                     │
       │                            │                           │
       │  Launch Claude Code        │                           │
       │                            │                           │

 All credentials have 1h TTL. Vault tracks leases for early revocation.
 Orchestrator saves lease IDs so cleanup can revoke them immediately.
```

### Scenario 2: Agent makes an API call with ephemeral credentials

```
 Agent (Claude Code)                                           API Server
 ─────────────────                                             ──────────
       │                                                            │
       │  curl -H "Authorization: Bearer $GCP_ACCESS_TOKEN" \       │
       │       https://storage.googleapis.com/bucket/object         │
       │ ──────────────────────────────────────────────────────▶    │
       │                                                            │
       │    Token ya29.xxxx is valid (issued <1h ago)               │
       │    IAM role allows storage.objectViewer only               │
       │                                                            │
       │ ◀── 200 OK + object contents ────────────────────────────  │
       │                                                            │

 No proxy. No interception. Agent uses the credential directly.
 Security relies on: short TTL + scoped IAM permissions.
```

### Scenario 3: Agent does `git push` with ephemeral GitHub token

```
 Agent (Claude Code)                                       GitHub
 ─────────────────                                         ──────
       │                                                      │
       │  GITHUB_TOKEN is set in environment                  │
       │  (git automatically uses it via credential helper    │
       │   or GIT_ASKPASS, or agent sets header directly)     │
       │                                                      │
       │  git push origin feature-branch                      │
       │ ─────────────────────────────────────────────────▶   │
       │    Authorization: Basic base64(x-token:ghs_xxxx)     │
       │                                                      │
       │    Token ghs_xxxx is valid:                          │
       │    - GitHub App installation token                   │
       │    - Scoped to: contents:write, pull_requests:write  │
       │    - Expires in: 47 minutes                          │
       │                                                      │
       │ ◀── push accepted ──────────────────────────────────  │
       │                                                      │

 If agent runs for >1h and token expires mid-session:
 - git push fails with 401
 - Agent reports failure to user
 - User can re-run credential injection or extend session
```

### Scenario 4: Agent runs `gcloud` / `gh` CLI with ephemeral credentials

```
 Agent (Claude Code)         gcloud CLI                        GCP API
 ─────────────────          ──────────                         ───────
       │                      │                                    │
       │  Environment has:    │                                    │
       │  GCP_ACCESS_TOKEN    │                                    │
       │  (or GOOGLE_APPLICATION_CREDENTIALS                       │
       │   pointing to temp SA key file)                           │
       │                      │                                    │
       │  gcloud storage ls   │                                    │
       │ ─────────────────▶   │                                    │
       │                      │                                    │
       │                      │  Uses GCP_ACCESS_TOKEN from env    │
       │                      │  (no need for refresh token)       │
       │                      │                                    │
       │                      │ ── API call + Bearer ya29.xxxx ─▶  │
       │                      │                                    │
       │                      │ ◀── bucket listing ────────────── │
       │                      │                                    │
       │ ◀── gs://bucket-a ── │                                    │
       │    gs://bucket-b     │                                    │
       │                      │                                    │

 gcloud, gsutil, bq, etc. all respect the GCP_ACCESS_TOKEN env var.
 No gcloud auth login needed. No refresh token on disk.
 Token expires in 1h — gcloud will get a 401 after that.

 For gh CLI:
 - GITHUB_TOKEN env var is natively supported
 - gh uses it for all API calls automatically
 - No gh auth login needed
```

### Scenario 5: Agent does `docker pull` with ephemeral registry token

```
 Agent (Claude Code)         docker CLI                        Registry
 ─────────────────          ──────────                         ────────
       │                      │                                    │
       │  docker pull         │                                    │
       │  us-docker.pkg.dev/  │                                    │
       │  project/repo/img    │                                    │
       │ ─────────────────▶   │                                    │
       │                      │                                    │
       │                      │  Checks ~/.docker/config.json      │
       │                      │  credHelpers → docker-credential-  │
       │                      │  gcloud (uses GCP_ACCESS_TOKEN)    │
       │                      │                                    │
       │                      │ ── pull + Bearer ya29.xxxx ─────▶  │
       │                      │                                    │
       │                      │ ◀── image layers ────────────────  │
       │                      │                                    │
       │ ◀── image pulled ──  │                                    │
       │                      │                                    │

 docker-credential-gcloud reads GCP_ACCESS_TOKEN from environment.
 Same ephemeral token used for both gcloud CLI and Docker registry.
 No separate Docker token needed for GCP registries.

 For non-GCP registries (Docker Hub, GHCR):
 - DOCKER_TOKEN injected as env var
 - Simple GIT_ASKPASS-style helper reads from env
 - Or: docker login with ephemeral token at session start
```

### Scenario 6: Session cleanup — immediate lease revocation

```
 Orchestrator                  Vault Server               Cloud Providers
 (tmux-cleanup-branch.sh)     ────────────               ───────────────
       │                            │                           │
       │  Read lease IDs from       │                           │
       │  $ENV_DIR/.vault-leases    │                           │
       │                            │                           │
       │  vault lease revoke        │                           │
       │  <gcp-lease-id>            │                           │
       │ ──────────────────────▶    │                           │
       │                            │ ── revoke token ────────▶ │ (GCP IAM)
       │                            │                           │
       │  vault lease revoke        │                           │
       │  <github-lease-id>         │                           │
       │ ──────────────────────▶    │                           │
       │                            │ ── revoke token ────────▶ │ (GitHub)
       │                            │                           │
       │  vault lease revoke        │                           │
       │  <aws-lease-id>            │                           │
       │ ──────────────────────▶    │                           │
       │                            │ ── revoke creds ────────▶ │ (AWS IAM)
       │                            │                           │
       │  rm $ENV_DIR/.vault-leases │                           │
       │  rm -rf $ENV_DIR           │                           │
       │                            │                           │

 Credentials are invalidated IMMEDIATELY on cleanup.
 Even if TTL was 1 hour, revocation makes them useless in seconds.
 If cleanup crashes, TTL expiry is the safety net.
```

### Scenario 7: Credential expires mid-session (TTL exceeded)

```
 Agent (Claude Code)                                           API Server
 ─────────────────                                             ──────────
       │                                                            │
       │  (60+ minutes into session)                                │
       │                                                            │
       │  curl -H "Authorization: Bearer $GCP_ACCESS_TOKEN" \       │
       │       https://storage.googleapis.com/bucket/object         │
       │ ──────────────────────────────────────────────────────▶    │
       │                                                            │
       │    Token ya29.xxxx has EXPIRED                              │
       │                                                            │
       │ ◀── 401 Unauthorized ─────────────────────────────────────  │
       │                                                            │
       │                                                            │
       │  Agent (per CLAUDE.md):                                    │
       │  "I'm getting a 401 from GCP Storage.                     │
       │   My credentials may have expired.                         │
       │   Please refresh them or extend the session."              │
       │                                                            │

 This is the expected failure mode. The user can:
 1. Re-run the orchestrator to get fresh credentials
 2. Or configure longer TTLs in Vault
 3. Or use Vault Agent for auto-renewal (advanced setup)
```

### Summary: Where Credentials Live in v3

```
┌──────────────────────────────────────────────────────────────────────┐
│                        Agent Process (Claude Code)                    │
│                                                                      │
│  HAS (as env vars):                Properties:                       │
│  • GITHUB_TOKEN=ghs_xxxx          • Expires in ≤1h                  │
│  • GCP_ACCESS_TOKEN=ya29.xxxx     • Scoped to minimum IAM role      │
│  • AWS_ACCESS_KEY_ID=AKIA...      • Unique to this session          │
│  • AWS_SECRET_ACCESS_KEY=xxxx     • Revoked immediately on cleanup  │
│  • DOCKER_TOKEN=dckr_xxxx         • Audited by Vault                │
│                                                                      │
│  CANNOT DO (even with the credential):                               │
│  • Access resources outside IAM scope                                │
│  • Use credential after session ends (revoked)                       │
│  • Use credential after TTL (expired)                                │
│  • Escalate permissions (scoped IAM role)                            │
│                                                                      │
│  Acceptable risk:                                                    │
│  • Agent CAN see credential values (they're env vars)               │
│  • Agent COULD exfiltrate them (but they expire quickly)             │
│  • A leaked credential is useless after cleanup/expiry               │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────┐
│  Vault Server (self-hosted or HCP)               │
│                                                  │
│  Manages:                                        │
│  • Dynamic secret generation per session         │
│  • Lease tracking + TTL enforcement              │
│  • Early revocation on session cleanup           │
│  • Audit log of every credential issued          │
│                                                  │
│  Vault Secrets Engines in use:                   │
│  • gcp/    → OAuth access tokens                 │
│  • github/ → App installation tokens             │
│  • aws/    → STS session credentials             │
│  • database/ → ephemeral DB user/pass (optional) │
│  • ssh/    → signed certificates (optional)      │
└──────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────┐
│  Lease File: $ENV_DIR/.vault-leases              │
│                                                  │
│  gcp/token/agent-role:lease_abc123               │
│  github/token:lease_def456                       │
│  aws/creds/agent-role:lease_ghi789               │
│                                                  │
│  Used by cleanup to revoke all session creds.    │
│  Deleted when environment is torn down.          │
└──────────────────────────────────────────────────┘
```

### Comparison: v2 (proxy) vs v3 (ephemeral) data flow

```
v2: Agent → HTTP Proxy → (inject secret) → API Server
    Agent never sees secret. Requires proxy process + config + CA trust.

v3: Orchestrator → Vault → (get ephemeral cred) → env var → Agent → API Server
    Agent sees credential, but it expires in 1h and is scoped.
    No proxy. No interception. No CA. Just env vars.

v2 is more secure (agent never sees secret).
v3 is far simpler (no proxy, no credential helpers, no CA management).
v3 is sufficient for trusted developer environments.
v2 is better for untrusted/multi-tenant/production-access scenarios.
```

## Prerequisites

### Vault Server

One of:
- **HCP Vault** (HashiCorp cloud, managed) — simplest to get started
- **Self-hosted Vault** (single binary, `vault server -dev` for testing)
- **Vault in Docker** — `docker run -d --name vault -p 8200:8200 hashicorp/vault`

### Vault Secrets Engines (configure once per org)

| Engine | Setup | What it needs |
|--------|-------|---------------|
| `gcp` | `vault secrets enable gcp` + configure GCP service account | GCP project with IAM admin |
| `github` | Install [vault-plugin-secrets-github](https://github.com/martinbaillie/vault-plugin-secrets-github) + configure GitHub App | GitHub App with desired permissions |
| `aws` | `vault secrets enable aws` + configure IAM user with STS permissions | AWS account with IAM admin |
| `database` | `vault secrets enable database` + configure connection | Database connection string |

### Vault Auth Method (how the orchestrator authenticates to Vault)

Recommended: **AppRole** for automated orchestration
```bash
vault auth enable approle
vault write auth/approle/role/para-llm-agent \
    token_ttl=2h \
    token_max_ttl=4h \
    policies="agent-creds"
```

Policy `agent-creds`:
```hcl
path "gcp/token/agent-role" {
  capabilities = ["read"]
}
path "github/token" {
  capabilities = ["read"]
}
path "aws/creds/agent-role" {
  capabilities = ["read"]
}
path "sys/leases/revoke" {
  capabilities = ["update"]
}
```

## Plugin Directory Structure

```
plugins/credential-auth/
├── README.md
├── credential-auth.sh           # Generate creds + inject into pane (~80 lines)
├── credential-cleanup.sh        # Revoke leases on session end (~30 lines)
├── install-credential-auth.sh   # Install + configure Vault connection (~80 lines)
└── config/
    ├── vault-policy.example.hcl # Example Vault policy for agent credentials
    └── claude-md-snippet.md     # CLAUDE.md template for agent awareness
```

**3 scripts + 2 config files.** That's it.

## Configuration

Stored in `$PARA_LLM_ROOT/config` (same as other para-llm settings):

```bash
# Credential auth settings
CRED_AUTH_ENABLED=1
VAULT_ADDR=https://vault.example.com:8200
# VAULT_ROLE_ID and VAULT_SECRET_ID stored in macOS Keychain (not in config file)
# Or: VAULT_TOKEN for dev/testing

# Which engines to use (space-separated)
CRED_AUTH_ENGINES="gcp github aws"

# Engine-specific settings
CRED_AUTH_GCP_ROLE="agent-role"
CRED_AUTH_GITHUB_ORG="my-org"
CRED_AUTH_AWS_ROLE="agent-role"

# TTL override (default: use Vault role defaults)
# CRED_AUTH_TTL="1h"
```

## Core Script: `credential-auth.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
# Generate ephemeral credentials from Vault and output env var exports.
# Usage: credential-auth.sh <env-dir>
# Outputs: export statements to stdout (eval'd or sent to tmux pane)
# Side effect: writes lease IDs to <env-dir>/.vault-leases

ENV_DIR="${1:?Usage: credential-auth.sh <env-dir>}"
LEASE_FILE="$ENV_DIR/.vault-leases"
> "$LEASE_FILE"  # truncate

# Authenticate to Vault (AppRole)
if [[ -n "${VAULT_TOKEN:-}" ]]; then
    : # Already authenticated
elif [[ -n "${VAULT_ROLE_ID:-}" ]]; then
    export VAULT_TOKEN=$(vault write -field=token auth/approle/login \
        role_id="$VAULT_ROLE_ID" secret_id="$VAULT_SECRET_ID")
fi

# GCP access token
if [[ " $CRED_AUTH_ENGINES " == *" gcp "* ]]; then
    RESULT=$(vault read -format=json "gcp/token/${CRED_AUTH_GCP_ROLE}")
    echo "export GCP_ACCESS_TOKEN=$(echo "$RESULT" | jq -r '.data.token')"
    echo "export CLOUDSDK_AUTH_ACCESS_TOKEN=$(echo "$RESULT" | jq -r '.data.token')"
    echo "$RESULT" | jq -r '.lease_id' >> "$LEASE_FILE"
fi

# GitHub token
if [[ " $CRED_AUTH_ENGINES " == *" github "* ]]; then
    RESULT=$(vault read -format=json "github/token" org_name="$CRED_AUTH_GITHUB_ORG")
    echo "export GITHUB_TOKEN=$(echo "$RESULT" | jq -r '.data.token')"
    echo "$RESULT" | jq -r '.lease_id' >> "$LEASE_FILE"
fi

# AWS credentials
if [[ " $CRED_AUTH_ENGINES " == *" aws "* ]]; then
    RESULT=$(vault read -format=json "aws/creds/${CRED_AUTH_AWS_ROLE}")
    echo "export AWS_ACCESS_KEY_ID=$(echo "$RESULT" | jq -r '.data.access_key')"
    echo "export AWS_SECRET_ACCESS_KEY=$(echo "$RESULT" | jq -r '.data.secret_key')"
    echo "export AWS_SESSION_TOKEN=$(echo "$RESULT" | jq -r '.data.security_token')"
    echo "$RESULT" | jq -r '.lease_id' >> "$LEASE_FILE"
fi

chmod 600 "$LEASE_FILE"
```

## Core Script: `credential-cleanup.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
# Revoke all Vault leases for a session.
# Usage: credential-cleanup.sh <env-dir>

ENV_DIR="${1:?Usage: credential-cleanup.sh <env-dir>}"
LEASE_FILE="$ENV_DIR/.vault-leases"

if [[ ! -f "$LEASE_FILE" ]]; then
    exit 0
fi

while IFS= read -r lease_id; do
    [[ -z "$lease_id" ]] && continue
    vault lease revoke "$lease_id" 2>/dev/null || true
done < "$LEASE_FILE"

rm -f "$LEASE_FILE"
```

## Environment Lifecycle Integration

### On `tmux-new-branch.sh` (create/resume):

```bash
if [[ "${CRED_AUTH_ENABLED:-0}" == "1" ]]; then
    PLUGIN_DIR="$SCRIPT_DIR/plugins/credential-auth"

    # Generate ephemeral credentials and inject into pane
    ENV_EXPORTS=$("$PLUGIN_DIR/credential-auth.sh" "$ENV_DIR" 2>/dev/null) || {
        echo "Warning: credential generation failed" >&2
    }

    if [[ -n "${ENV_EXPORTS:-}" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && tmux send-keys "$line" Enter
        done <<< "$ENV_EXPORTS"
    fi
fi
```

### On `tmux-cleanup-branch.sh` (cleanup):

```bash
if [[ -f "$ENV_DIR/.vault-leases" ]]; then
    PLUGIN_DIR="${SCRIPT_DIR:-$INSTALL_DIR}/plugins/credential-auth"
    "$PLUGIN_DIR/credential-cleanup.sh" "$ENV_DIR" 2>/dev/null || true
fi
```

## CLAUDE.md Snippet

```markdown
## Authenticated Services

This environment has temporary credentials for external services.
They are set as environment variables and expire after ~1 hour.

### What this means for you
- **Use tools normally** — git, docker, gcloud, gh, curl all work with the provided credentials
- **Do NOT** run auth commands (gcloud auth, gh auth, docker login) — credentials are pre-set
- **Do NOT** hardcode credentials in files — use the environment variables
- If you get a 401/403, tell the user — credentials may have expired
- Credentials are automatically revoked when this session ends
```

## Installation Flow

```
1. "Install credential auth plugin?"
   → Requires: Vault CLI (brew install vault), jq

2. Configure Vault connection:
   → VAULT_ADDR (Vault server URL)
   → Auth method: AppRole (store role_id/secret_id in Keychain)
   → Or: VAULT_TOKEN for dev/testing

3. Configure engines (which services need credentials):
   → GCP: role name for gcp/token/
   → GitHub: org name for github/token
   → AWS: role name for aws/creds/
   → (only configure what you need)

4. Test credential generation:
   → Run credential-auth.sh, verify tokens are issued

5. Save CRED_AUTH_ENABLED=1 to config
```

## When to Upgrade to v2 (Proxy Architecture)

v3 is sufficient when:
- Agents run in a trusted developer environment
- Credentials are scoped to non-destructive permissions
- 1-hour exposure window is acceptable

Consider upgrading to v2 (Secretless Broker proxy) when:
- Agents need write access to production systems
- Running in multi-tenant or untrusted environments
- Regulatory requirements mandate request-level audit trails
- You need operation-level filtering beyond IAM scoping
- Zero-trust: agent must NEVER see any credential value

## Verification

1. **Vault connectivity**: `vault status` returns sealed=false
2. **Credential generation**: `credential-auth.sh /tmp/test` outputs valid export statements
3. **GCP token works**: `curl -H "Authorization: Bearer $GCP_ACCESS_TOKEN" https://storage.googleapis.com/...`
4. **GitHub token works**: `GITHUB_TOKEN=<token> gh repo list`
5. **AWS creds work**: `aws sts get-caller-identity`
6. **Lease revocation**: `credential-cleanup.sh /tmp/test` → tokens become invalid
7. **TTL expiry**: Wait >1h → tokens expire naturally
8. **Full lifecycle**: Create env → creds injected → agent works → cleanup → creds revoked

## Implementation Sequence

1. Write `credential-auth.sh` (generate creds, ~80 lines)
2. Write `credential-cleanup.sh` (revoke leases, ~30 lines)
3. Write `install-credential-auth.sh` (install + configure, ~80 lines)
4. Create `vault-policy.example.hcl` and `claude-md-snippet.md`
5. Integrate with `tmux-new-branch.sh` (inject creds before Claude launch)
6. Integrate with `tmux-cleanup-branch.sh` (revoke on cleanup)
7. Add install section to `install.sh`
