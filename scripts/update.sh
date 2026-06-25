#!/usr/bin/env bash
# Update factory-config on this VM. Safe to run repeatedly.
# Re-cloning is never needed — ~/factory is a normal git checkout.
set -euo pipefail
FACTORY_DIR="${FACTORY_DIR:-$HOME/factory}"
[ -d "$FACTORY_DIR/.git" ] || { echo "$FACTORY_DIR is not a git checkout; clone it first:"; echo "  git clone https://github.com/petealbertson/factory-config $FACTORY_DIR"; exit 1; }
git -C "$FACTORY_DIR" fetch origin
printf 'Updated: '; git -C "$FACTORY_DIR" log --oneline -1 @{u}
echo
echo "Current HEAD:  $(git -C "$FACTORY_DIR" rev-parse --short HEAD)"
echo "Run this on every factory VM to keep them in sync."
