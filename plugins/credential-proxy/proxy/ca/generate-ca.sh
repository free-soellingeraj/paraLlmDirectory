#!/usr/bin/env bash
set -euo pipefail

# Generate a local CA certificate for the MITM proxy
# Usage: generate-ca.sh <ca-dir>

CA_DIR="${1:?Usage: generate-ca.sh <ca-dir>}"

CA_KEY="$CA_DIR/para-llm-ca.key"
CA_CERT="$CA_DIR/para-llm-ca.pem"

if [[ -f "$CA_CERT" ]] && [[ -f "$CA_KEY" ]]; then
    echo "CA already exists at $CA_DIR"
    echo "  Key:  $CA_KEY"
    echo "  Cert: $CA_CERT"
    exit 0
fi

mkdir -p "$CA_DIR"

echo "Generating CA certificate..."

openssl req -x509 -new -nodes \
    -keyout "$CA_KEY" \
    -out "$CA_CERT" \
    -days 825 \
    -subj "/CN=para-llm-directory Credential Proxy CA/O=para-llm-directory" \
    2>/dev/null

chmod 600 "$CA_KEY"
chmod 644 "$CA_CERT"

echo "Generated CA certificate:"
echo "  Key:  $CA_KEY"
echo "  Cert: $CA_CERT"
echo ""
echo "Valid for 825 days."
