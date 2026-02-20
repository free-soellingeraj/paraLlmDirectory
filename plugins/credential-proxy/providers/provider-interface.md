# Provider Plugin Interface

Each credential provider is a shell script that bridges to a secrets backend.

## Contract

```
Usage: <provider>.sh <action> <secret-ref> [key=value ...]

Actions:
  get     Fetch a secret value. Print to stdout, exit 0. On failure: stderr + exit 1.
  health  Check if the backend is reachable. Print "ok" + exit 0, or stderr + exit 1.

Arguments:
  secret-ref   The name/path of the secret in the backend
  key=value    Optional provider-specific config (e.g., project=my-gcp-project)

Environment:
  PARA_LLM_ROOT   Always set. Points to the para-llm root directory.
```

## Example

```bash
# Fetch a secret
./gcp-secrets.sh get my-api-token project=my-project
# → prints the secret value to stdout

# Health check
./gcp-secrets.sh health
# → prints "ok" or error message
```

## Creating a New Provider

1. Create `<name>.sh` in this directory
2. Implement `get` and `health` actions
3. Make it executable: `chmod +x <name>.sh`
4. Reference it in `credentials.yaml` under `providers:`

## Guidelines

- Providers MUST NOT cache secrets themselves (the proxy handles caching)
- Providers MUST NOT write secrets to disk or environment variables
- Providers SHOULD timeout within 10 seconds
- Providers MUST exit non-zero on any failure
