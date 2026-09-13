#!/usr/bin/env bash
# Import the local Sparkle Ed25519 private key into the login Keychain so
# `sign_update` can sign release archives. Run once per machine that ships builds.
#
# Prerequisites:
#   1. .secrets/sparkle_ed25519_private.key (gitignored; created during Sparkle setup)
#   2. Sparkle's generate_keys tool (from a Sparkle release tarball's bin/)
#
# Usage:
#   ./scripts/import-sparkle-key.sh /path/to/Sparkle/bin/generate_keys
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY_FILE="$ROOT/.secrets/sparkle_ed25519_private.key"
GENERATE_KEYS="${1:-}"

if [[ -z "$GENERATE_KEYS" || ! -x "$GENERATE_KEYS" ]]; then
  echo "Usage: $0 /path/to/generate_keys" >&2
  echo "Download Sparkle from https://github.com/sparkle-project/Sparkle/releases and pass bin/generate_keys." >&2
  exit 1
fi

if [[ ! -f "$KEY_FILE" ]]; then
  echo "Missing $KEY_FILE" >&2
  echo "Regenerate with CryptoKit or Sparkle generate_keys, then keep the private key out of git." >&2
  exit 1
fi

"$GENERATE_KEYS" --account windowlens -f "$KEY_FILE"
echo "Imported Sparkle private key (account: windowlens)."
echo "Public key must match Info.plist SUPublicEDKey:"
"$GENERATE_KEYS" --account windowlens -p
