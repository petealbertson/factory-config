#!/usr/bin/env bash
# Install the cloud factory into a consuming repo + register a self-hosted
# GitHub Actions runner on this VM (one runner per repo).
#
# Run on the repo VM, inside the repo checkout:
#   cd ~/some-repo
#   bash ~/factory/scripts/install.sh <owner/repo> <runner-registration-token>
#
# The registration token is short-lived (~1h). Get it from:
#   gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token -q .token
# or the GitHub UI: Settings → Actions → Runners → New self-hosted runner.
set -euo pipefail

REPO_DIR="$(pwd)"
FACTORY_DIR="$HOME/factory"
RUNNER_DIR="$HOME/actions-runner"
ARCH="$(uname -m)"   # x86_64

REPO="${1:?usage: install.sh <owner/repo> <runner-registration-token>}"
REG_TOKEN="${2:?usage: install.sh <owner/repo> <runner-registration-token>}"

# --- 1. factory-config (runner + skills + models.env) ------------------------
if [ ! -d "$FACTORY_DIR/.git" ]; then
  echo "Cloning factory-config to $FACTORY_DIR"
  git clone https://github.com/petealbertson/factory-config "$FACTORY_DIR"
else
  echo "factory-config already present at $FACTORY_DIR, pulling"
  git -C "$FACTORY_DIR" pull --ff-only
fi

# --- 2. workflows into the repo ----------------------------------------------
mkdir -p "$REPO_DIR/.github/workflows"
cp "$FACTORY_DIR"/templates/github/workflows/*.yml "$REPO_DIR/.github/workflows/"
echo "Copied workflows to $REPO_DIR/.github/workflows/"

# --- 3. repo.env (which repo lives here) -------------------------------------
if [ ! -f "$FACTORY_DIR/repo.env" ]; then
  cat > "$FACTORY_DIR/repo.env" <<EOF
REPO_DIR="$REPO_DIR"
REPO_SLUG="$REPO"
EOF
  echo "Wrote $FACTORY_DIR/repo.env (REPO_SLUG=$REPO)"
else
  echo "$FACTORY_DIR/repo.env already exists, leaving it"
fi

# --- 4. self-hosted runner ---------------------------------------------------
mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"

if [ ! -x "./run.sh" ]; then
  echo "Downloading latest GitHub Actions runner ($ARCH)"
  VER="$(gh api repos/actions/runner/releases/latest --jq .tag_name | sed 's/^v//')"
  curl -fsSL -o runner.tar.gz "https://github.com/actions/runner/releases/download/v${VER}/actions-runner-linux-${ARCH/x86_64/x64}-${VER}.tar.gz"
  tar xzf runner.tar.gz && rm -f runner.tar.gz
else
  echo "runner already installed at $RUNNER_DIR"
fi

if [ -f ".runner" ]; then
  echo "Runner already registered (skipping config.sh)"
else
  echo "Registering runner to $REPO"
  ./config.sh --unattended --url "https://github.com/$REPO" --token "$REG_TOKEN" \
    --labels "factory"
fi

# --- 5. systemd service ------------------------------------------------------
cat > gh-actions-runner.service <<'EOF'
[Unit]
Description=GitHub Actions Runner
After=network.target

[Service]
Type=simple
User=exedev
WorkingDirectory=__RUNNER_DIR__
ExecStart=__RUNNER_DIR__/run.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
sed -i "s#__RUNNER_DIR__#$RUNNER_DIR#g" gh-actions-runner.service
sudo cp "$RUNNER_DIR/gh-actions-runner.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gh-actions-runner.service

echo
sleep 2
systemctl --no-pager --full status gh-actions-runner.service | head -12 || true

echo
echo "Installed. Remaining steps:"
echo "  1. git add .github/workflows && git commit -m 'factory workflows' && git push"
echo "  2. create labels:  bash ~/factory/scripts/setup-repo.sh $REPO"
