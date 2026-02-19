#!/usr/bin/env bash
set -euo pipefail

# Trust the proxy CA certificate on the local system
# Usage: trust-ca.sh <ca-dir>

CA_DIR="${1:?Usage: trust-ca.sh <ca-dir>}"
CA_CERT="$CA_DIR/para-llm-ca.pem"

if [[ ! -f "$CA_CERT" ]]; then
    echo "CA certificate not found: $CA_CERT" >&2
    echo "Run generate-ca.sh first." >&2
    exit 1
fi

echo "Trusting CA certificate on macOS..."
echo "  (You may be prompted for your password)"

# Add to macOS system keychain as trusted
if sudo security add-trusted-cert -d -r trustRoot \
    -k /Library/Keychains/System.keychain \
    "$CA_CERT" 2>/dev/null; then
    echo "  CA added to system keychain."
else
    echo "  Warning: Could not add CA to system keychain."
    echo "  Tools will still work via explicit CA cert env vars."
fi

echo ""
echo "CA trusted. For tools that don't use the system keychain,"
echo "set these environment variables:"
echo ""
echo "  export NODE_EXTRA_CA_CERTS=\"$CA_CERT\""
echo "  export REQUESTS_CA_BUNDLE=\"$CA_CERT\""
echo "  export SSL_CERT_FILE=\"$CA_CERT\""
echo "  export GIT_SSL_CAINFO=\"$CA_CERT\""
