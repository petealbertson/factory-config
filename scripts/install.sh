#!/usr/bin/env bash
# Install the cloud factory into a consuming repo + this VM.
# Run on the repo VM, in the repo checkout.
set -euo pipefail

REPO_DIR="$(pwd)"
FACTORY_DIR="$HOME/factory"

if [ ! -d "$FACTORY_DIR/.git" ]; then
  echo "Cloning factory-config to $FACTORY_DIR"
  git clone https://github.com/petealbertson/factory-config "$FACTORY_DIR"
else
  echo "factory-config already present at $FACTORY_DIR, pulling"
  git -C "$FACTORY_DIR" pull --ff-only
fi

# copy the workflow templates into this repo
mkdir -p "$REPO_DIR/.github/workflows"
cp "$FACTORY_DIR"/templates/github/workflows/*.yml "$REPO_DIR/.github/workflows/"
echo "Copied workflows to $REPO_DIR/.github/workflows/"

# write repo.env if absent
if [ ! -f "$FACTORY_DIR/repo.env" ]; then
  SLUG="$(git -C "$REPO_DIR" config --get remote.origin.url | sed 's#.*github.com[:/]##; s#.git$##')"
  cat > "$FACTORY_DIR/repo.env" <<EOF
REPO_DIR="$REPO_DIR"
REPO_SLUG="$SLUG"
EOF
  echo "Wrote $FACTORY_DIR/repo.env (REPO_SLUG=$SLUG)"
else
  echo "$FACTORY_DIR/repo.env already exists, leaving it"
fi

cat <<NOTE

Next steps:
  1. Set repository variable  FACTORY_VM  (Settings > Secrets and variables > Actions > Variables)
  2. Set repository secret   EXEDEV_API_TOKEN  (generate on a VM: ssh exe.dev ssh-key generate-api-key --exp=365d)
  3. Create the labels: ready, human-review  (GitHub issues/PR labels)
  4. Commit and push the workflows.
NOTE
