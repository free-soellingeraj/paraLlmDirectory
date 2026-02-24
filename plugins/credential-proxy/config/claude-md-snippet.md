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
