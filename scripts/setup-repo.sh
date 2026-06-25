#!/usr/bin/env bash
# Configure a GitHub repo to use the factory: create labels and confirm the
# runner is connected. Run once per consuming repo.
#
# Usage:
#   scripts/setup-repo.sh <owner/repo>
#
# Example:
#   scripts/setup-repo.sh petealbertson/todo-factory-demo
#
set -euo pipefail

REPO="${1:?usage: setup-repo.sh <owner/repo>}"

command -v gh >/dev/null || { echo "gh CLI required" >&2; exit 1; }

set -x

# Labels (idempotent via || true — gh errors if label exists)
gh label create ready --repo "$REPO" --color 0E8A16 \
  --description "Issue plan approved; factory will implement" 2>/dev/null || true
gh label create human-review --repo "$REPO" --color 5319E7 \
  --description "PR is ready for human smoke test on the VM" 2>/dev/null || true

set +x

echo
echo "Configured labels on $REPO."
echo
echo "Confirm the runner is connected:"
echo "  gh api repos/$REPO/actions/runners --jq '.runners[] | {name,state,labels:[.labels[].name]}'"
echo
echo "Next: push the workflows to the default branch, then tag an issue 'ready'."
