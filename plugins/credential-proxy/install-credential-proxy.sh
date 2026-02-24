#!/usr/bin/env bash
set -euo pipefail

# Credential Proxy Plugin Installer
# Called from main install.sh or run standalone.
# Usage: install-credential-proxy.sh [--non-interactive]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load para-llm config
BOOTSTRAP_FILE="$HOME/.para-llm-root"
if [[ -f "$BOOTSTRAP_FILE" ]]; then
    PARA_LLM_ROOT="$(cat "$BOOTSTRAP_FILE")"
else
    echo "Error: para-llm not installed. Run install.sh first." >&2
    exit 1
fi

NON_INTERACTIVE=false
[[ "${1:-}" == "--non-interactive" ]] && NON_INTERACTIVE=true

PLUGIN_DEST="$PARA_LLM_ROOT/plugins/credential-proxy"

echo ""
echo "=== Credential Proxy Plugin ==="
echo "Provides transparent authentication for agent tools."
echo "Agents never see secret values — they're injected transparently."
echo ""

# --- Step 1: Install mitmproxy ---
echo "Step 1: Checking mitmproxy..."
if command -v mitmdump &>/dev/null; then
    echo "  mitmproxy already installed: $(mitmdump --version 2>&1 | head -1)"
else
    echo "  Installing mitmproxy..."
    if command -v brew &>/dev/null; then
        brew install mitmproxy
    elif command -v pip3 &>/dev/null; then
        pip3 install mitmproxy
    else
        echo "  Error: Neither brew nor pip3 found. Install mitmproxy manually." >&2
        exit 1
    fi
fi

# --- Step 2: Install yq ---
echo ""
echo "Step 2: Checking yq (YAML processor)..."
if command -v yq &>/dev/null; then
    echo "  yq already installed: $(yq --version 2>&1)"
else
    echo "  Installing yq..."
    if command -v brew &>/dev/null; then
        brew install yq
    else
        echo "  Warning: brew not found. Install yq manually: https://github.com/mikefarah/yq"
    fi
fi

# --- Step 3: Copy plugin files ---
echo ""
echo "Step 3: Installing plugin files..."
mkdir -p "$PLUGIN_DEST"/{proxy/ca,helpers,oauth,providers,config}

# Copy all plugin files
cp "$SCRIPT_DIR/orchestrator.sh" "$PLUGIN_DEST/"
cp "$SCRIPT_DIR/proxy/proxy-manager.sh" "$PLUGIN_DEST/proxy/"
cp "$SCRIPT_DIR/proxy/credential-inject.py" "$PLUGIN_DEST/proxy/"
cp "$SCRIPT_DIR/proxy/ca/generate-ca.sh" "$PLUGIN_DEST/proxy/ca/"
cp "$SCRIPT_DIR/proxy/ca/trust-ca.sh" "$PLUGIN_DEST/proxy/ca/"
cp "$SCRIPT_DIR/helpers/"*.sh "$PLUGIN_DEST/helpers/"
cp "$SCRIPT_DIR/oauth/"*.sh "$PLUGIN_DEST/oauth/"
cp "$SCRIPT_DIR/providers/"*.sh "$PLUGIN_DEST/providers/"
cp "$SCRIPT_DIR/providers/provider-interface.md" "$PLUGIN_DEST/providers/"
cp "$SCRIPT_DIR/config/claude-md-snippet.md" "$PLUGIN_DEST/config/"

# Make scripts executable
chmod +x "$PLUGIN_DEST/orchestrator.sh"
chmod +x "$PLUGIN_DEST/proxy/proxy-manager.sh"
chmod +x "$PLUGIN_DEST/proxy/ca/"*.sh
chmod +x "$PLUGIN_DEST/helpers/"*.sh
chmod +x "$PLUGIN_DEST/oauth/"*.sh
chmod +x "$PLUGIN_DEST/providers/"*.sh

echo "  Plugin files installed to $PLUGIN_DEST"

# --- Step 4: Create default config ---
echo ""
echo "Step 4: Configuration..."
if [[ ! -f "$PLUGIN_DEST/credentials.yaml" ]]; then
    cp "$SCRIPT_DIR/config/credentials.example.yaml" "$PLUGIN_DEST/credentials.yaml"
    echo "  Created default config: $PLUGIN_DEST/credentials.yaml"
    echo "  Edit this file to configure your credential rules."
else
    echo "  Config already exists: $PLUGIN_DEST/credentials.yaml"
fi

# --- Step 5: Generate CA certificate ---
echo ""
echo "Step 5: CA Certificate..."
"$PLUGIN_DEST/proxy/ca/generate-ca.sh" "$PLUGIN_DEST/proxy/ca"

# --- Step 6: Trust CA certificate ---
echo ""
echo "Step 6: Trusting CA certificate..."
if [[ "$NON_INTERACTIVE" == false ]]; then
    read -r -p "Trust the CA certificate in macOS keychain? (requires sudo) [y/N]: " trust_choice
    if [[ "$trust_choice" =~ ^[Yy] ]]; then
        "$PLUGIN_DEST/proxy/ca/trust-ca.sh" "$PLUGIN_DEST/proxy/ca"
    else
        echo "  Skipped. You can trust it later with:"
        echo "    $PLUGIN_DEST/proxy/ca/trust-ca.sh $PLUGIN_DEST/proxy/ca"
    fi
else
    echo "  Skipping CA trust in non-interactive mode."
    echo "  Run manually: $PLUGIN_DEST/proxy/ca/trust-ca.sh $PLUGIN_DEST/proxy/ca"
fi

# --- Step 7: Set up OAuth (interactive) ---
echo ""
echo "Step 7: OAuth setup..."
if [[ "$NON_INTERACTIVE" == false ]]; then
    read -r -p "Set up OAuth for CLI tools (gcloud, gh, az)? [y/N]: " oauth_choice
    if [[ "$oauth_choice" =~ ^[Yy] ]]; then
        "$PLUGIN_DEST/oauth/setup-oauth.sh"
    else
        echo "  Skipped. Run later: $PLUGIN_DEST/oauth/setup-oauth.sh"
    fi
else
    echo "  Skipping OAuth setup in non-interactive mode."
fi

# --- Step 8: Install credential helpers ---
echo ""
echo "Step 8: Credential helpers..."
if [[ "$NON_INTERACTIVE" == false ]]; then
    read -r -p "Install git and docker credential helpers? [y/N]: " helpers_choice
    if [[ "$helpers_choice" =~ ^[Yy] ]]; then
        "$PLUGIN_DEST/helpers/setup-helpers.sh" --all
    else
        echo "  Skipped. Run later: $PLUGIN_DEST/helpers/setup-helpers.sh --all"
    fi
else
    echo "  Skipping credential helpers in non-interactive mode."
fi

# --- Step 9: Save config ---
echo ""
echo "Step 9: Saving configuration..."
if ! grep -q "CRED_PROXY_ENABLED" "$PARA_LLM_ROOT/config" 2>/dev/null; then
    cat >> "$PARA_LLM_ROOT/config" << 'EOF'

# Credential proxy settings
CRED_PROXY_ENABLED=1
# CRED_PROXY_PORT_BASE=18080  # Starting port for proxy instances
EOF
    echo "  Added CRED_PROXY_ENABLED=1 to config"
else
    echo "  Config already has credential proxy settings"
fi

echo ""
echo "=== Credential Proxy Plugin Installed ==="
echo ""
echo "Next steps:"
echo "  1. Edit $PLUGIN_DEST/credentials.yaml to configure your credentials"
echo "  2. Create environments with 'Ctrl+b c' — proxy starts automatically"
echo "  3. Agents will have transparent authentication"
echo ""
