#!/bin/bash

set -euo pipefail

KEYCHAIN_SERVICE="pdf_renamer_openai_api_key"
KEYCHAIN_ACCOUNT="${USER:-$(/usr/bin/id -un)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEY_FILE="${SCRIPT_DIR}/.openai_api_key.local"

if [[ ! -f "$KEY_FILE" ]]; then
    cat >&2 <<'EOF'
Missing .openai_api_key.local

Create this file next to set_openai_key.sh with exactly one line:
your-full-openai-key

The file is ignored by git.
EOF
    exit 1
fi

OPENAI_API_KEY=$(/bin/cat "$KEY_FILE")

if [[ -z "$OPENAI_API_KEY" ]]; then
    echo "Key file is empty: $KEY_FILE" >&2
    exit 1
fi

# Normalize common paste artifacts without changing the actual key content.
OPENAI_API_KEY="${OPENAI_API_KEY%$'\r'}"
OPENAI_API_KEY="${OPENAI_API_KEY%$'\n'}"

KEY_LENGTH=${#OPENAI_API_KEY}
KEY_HASH=$(printf '%s' "$OPENAI_API_KEY" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
KEY_PREVIEW="${OPENAI_API_KEY:0:12}...${OPENAI_API_KEY: -8}"

echo "Source key preview: $KEY_PREVIEW"
echo "Source key length : $KEY_LENGTH"
echo "Source key sha256 : $KEY_HASH"

/usr/bin/security add-generic-password \
    -a "$KEYCHAIN_ACCOUNT" \
    -s "$KEYCHAIN_SERVICE" \
    -U \
    -w "$OPENAI_API_KEY" \
    >/dev/null

STORED_KEY=$(/usr/bin/security find-generic-password \
    -a "$KEYCHAIN_ACCOUNT" \
    -s "$KEYCHAIN_SERVICE" \
    -w 2>/dev/null)

if [[ -z "$STORED_KEY" ]]; then
    echo "Failed to read the stored key back from Keychain" >&2
    exit 1
fi

STORED_LENGTH=${#STORED_KEY}
STORED_HASH=$(printf '%s' "$STORED_KEY" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
STORED_PREVIEW="${STORED_KEY:0:12}...${STORED_KEY: -8}"

echo "Stored key preview: $STORED_PREVIEW"
echo "Stored key length : $STORED_LENGTH"
echo "Stored key sha256 : $STORED_HASH"

if [[ "$OPENAI_API_KEY" != "$STORED_KEY" ]]; then
    echo "Mismatch: stored key is not identical to the source key" >&2
    exit 1
fi

echo "Keychain verification passed for service '$KEYCHAIN_SERVICE' and account '$KEYCHAIN_ACCOUNT'."