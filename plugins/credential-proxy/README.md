# Credential Proxy Plugin

Transparent credential management for autonomous Claude Code agents. Agents use authenticated tools normally — credentials are injected automatically and **never visible to the agent**.

## How It Works

The plugin uses a tiered approach, choosing the best auth mechanism per tool:

| Tier | Strategy | Tools | How Secrets Flow |
|------|----------|-------|-----------------|
| 1 | OAuth / Service Accounts | gcloud, gh, az | Token in tool's native storage (keychain) |
| 2 | Credential Helpers | git, docker, npm | Secret piped from helper to tool subprocess |
| 3 | HTTP Proxy (MITM) | curl, APIs, registries | Secret in proxy process memory only |
| 4 | Restricted Config Files | kubectl, terraform | Config file with 0600 permissions |

## Quick Start

```bash
# Install the plugin
./install-credential-proxy.sh

# Edit your credential rules
$PARA_LLM_ROOT/plugins/credential-proxy/credentials.yaml

# Create an environment — proxy starts automatically
# Ctrl+b c (in tmux)
```

## Configuration

See `config/credentials.example.yaml` for the full configuration format.

## Providers

Credential backends are pluggable shell scripts. Available providers:

- **gcp-secrets** — Google Cloud Secret Manager
- **env-var** — Environment variables (for testing)
- **file** — Files on disk (for testing)

See `providers/provider-interface.md` for how to create new providers.

## Architecture

```
Agent pane → HTTP Proxy (header injection)
           → Credential Helpers (git, docker)
           → OAuth CLI tools (gcloud, gh)
                    ↓
           Provider Plugin Layer
                    ↓
           Root of Trust (GCP, 1Password, Vault, etc.)
```
