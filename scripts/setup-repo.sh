#!/usr/bin/env bash
# Configure a GitHub repo to use the factory: variable, secret, labels.
# Run once per consuming repo. Uses the token from bootstrap-token.sh.
#
# Usage:
#   scripts/setup-repo.sh <owner/repo> <factory-vm-name>
#
# Example:
#   scripts/setup-repo.sh petealbertson/todo-factory-demo todo-list-factory
#
set -euo pipefail

REPO="${1:?usage: setup-repo.sh <owner/repo> <factory-vm>}"
VM="${2:?usage: setup-repo.sh <owner/repo> <factory-vm>}"
TOKEN_FILE="${EXEDEV_TOKEN_FILE:-$HOME/.config/factory/exedev-token}"

command -v gh >/dev/null || { echo "gh CLI required" >&2; exit 1; }

if [ ! -s "$TOKEN_FILE" ]; then
  cat >&2 <<EOF
No token at $TOKEN_FILE.
Generate one on your laptop (where your exe.dev SSH key is):
  ssh exe.dev ssh-key generate-api-key --label=factory-ci --exp=365d
Then create the file on this VM and paste the exe1.... key into it:
  mkdir -p $(dirname "$TOKEN_FILE") && chmod 700 $(dirname "$TOKEN_FILE")
  # paste the key into: $TOKEN_FILE
  chmod 600 "$TOKEN_FILE"
EOF
  exit 1
fi

set -x

# 1. Variable: which VM this repo targets
gh variable set FACTORY_VM --repo "$REPO" --body "$VM"

# 2. Secret: the exe.dev API token (Actions authenticate with this)
gh secret set EXEDEV_API_TOKEN --repo "$REPO" < "$TOKEN_FILE"

# 3. Labels (idempotent via || true — gh errors if label exists)
gh label create ready --repo "$REPO" --color 0E8A16 \
  --description "Issue plan approved; factory will implement" 2>/dev/null || true
gh label create human-review --repo "$REPO" --color 5319E7 \
  --description "PR is ready for human smoke test on the VM" 2>/dev/null || true

set +x
echo
echo "Configured $REPO → VM $VM."
echo
echo "Next: push the workflows to the default branch, then tag an issue 'ready'."