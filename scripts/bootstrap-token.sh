#!/usr/bin/env bash
# Generate (or reuse) the exe.dev API token used by GitHub Actions to trigger
# the factory. Stored once at ~/.config/factory/exedev-token (mode 0600).
# Reused across all repos. Never committed.
#
# Usage:  bash scripts/bootstrap-token.sh
#
set -euo pipefail

TOKEN_FILE="${EXEDEV_TOKEN_FILE:-$HOME/.config/factory/exedev-token}"
mkdir -p "$(dirname "$TOKEN_FILE")"

# Already have one? Keep it unless --force.
if [ -s "$TOKEN_FILE" ] && [ "${1:-}" != "--force" ]; then
  echo "Token already present at $TOKEN_FILE (re-run with --force to regenerate)."
  exit 0
fi

if ! command -v ssh >/dev/null; then echo "ssh not found" >&2; exit 1; fi

# Generate on the server, capture JSON, extract the key.
echo "Generating exe.dev API token (valid 1 year)..."
OUT=$(ssh exe.dev ssh-key generate-api-key --label=factory-ci --exp=365d --json)
TOKEN=$(printf '%s' "$OUT" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["api_key"] rescue puts JSON.parse(STDIN.read)["key"] rescue nil')

if [ -z "$TOKEN" ]; then
  echo "Could not parse token from server response:" >&2
  printf '%s\n' "$OUT" >&2
  echo "Raw output was saved; inspect and paste manually into $TOKEN_FILE" >&2
  exit 1
fi

umask 077
printf '%s' "$TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
echo "Token written to $TOKEN_FILE (mode 0600). Reusable for every repo."
