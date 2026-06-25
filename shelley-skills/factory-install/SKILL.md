---
name: factory-install
description: |
  Bind a freshly copied factory VM to one GitHub repo so GitHub events run on
  this VM. Registers the self-hosted GitHub Actions runner (using the
  repo-scoped token minted by the VM's own `gh`), writes repo.env, ensures the
  repo has the four factory workflows + labels, and enables the runner service.
  Idempotent — safe to re-run after a template refresh. Use when the user says
  "set up / install / configure the factory on <repo>" or "wire <repo> to the
  factory" on a VM copied from rails-vm-template. No manual tokens or secrets.
---

# Factory Install — bind this VM to one GitHub repo

Goal: after this runs, an issue labeled `ready` on `<owner>/<repo>` fires the
factory end-to-end on *this* VM. Nothing leaves the VM; the runner long-polls
GitHub directly.

The template (`rails-vm-template`) ships pre-baked: `~/factory` (this repo's
clone), `~/actions-runner/` (runner binary, **no registration**), and a
*disabled* `gh-actions-runner.service`. Your only job is to register to a
specific repo and switch it on. The registration token is minted by the `gh`
already on the VM — **never ask the user for a token or a GitHub secret.**

## Prerequisites

- Repo already cloned and deps installed. Run `rails-exe-setup` first for a
  Rails app. This skill does NOT clone the app repo — `repo.env` points at an
  existing checkout.
- `~/factory` present (clones itself if missing).
- `~/actions-runner/run.sh` present (the binary). Bail with a clear message if
  not — that's a template-bake problem, not something to fix here.

## Inputs

Ask for one thing only: the repo slug (`owner/repo`). Default owner to the
logged-in `gh` user if only a name is given:
```bash
gh api user --jq .login
```

## Step 1 — locate the repo checkout

`repo.env` needs `REPO_DIR`. Resolve it by inspection, don't ask:
```bash
REPO_SLUG="petealbertson/<repo>"
REPO_DIR="$(find ~ -maxdepth 4 -type d -name '<repo>' \
  -path '*/projects/*' 2>/dev/null | head -1)"
```
If not found, STOP and tell the user to run `rails-exe-setup` (or `gh repo
clone`) first. Do not clone it yourself — that skill owns checkout.

Verify it matches the slug:
```bash
git -C "$REPO_DIR" remote get-url origin | grep -q "$REPO_SLUG" \
  || { echo "checkout at $REPO_DIR is not $REPO_SLUG"; exit 1; }
```

## Step 2 — factory-config up to date

```bash
git -C ~/factory pull --ff-only
```

## Step 3 — write repo.env (idempotent)

Overwrite — it's per-VM, not in git, and should always reflect this VM's repo:
```bash
cat > ~/factory/repo.env <<EOF
REPO_DIR="$REPO_DIR"
REPO_SLUG="$REPO_SLUG"
EOF
```

## Step 4 — register the runner

The VM's `gh` has `repo` scope → it mints its own registration token
(verified). **This is the core of "just works on cp":** no exe.dev API token,
no stored GitHub secret, no laptop hand-off.

```bash
TOKEN="$(gh api -X POST repos/$REPO_SLUG/actions/runners/registration-token --jq .token)"
```

If the runner already has a `.runner` file (re-running on an existing VM),
remove the stale registration first so it cleanly re-targets this repo:
```bash
cd ~/actions-runner
[ -f .runner ] && ./config.sh remove --token \
  "$(gh api -X POST repos/$REPO_SLUG/actions/runners/remove-token --jq .token)"
```

Register unattended:
```bash
cd ~/actions-runner
./config.sh --unattended --url "https://github.com/$REPO_SLUG" \
  --token "$TOKEN" --labels "factory,$REPO_SLUG" --replace
```
(`--replace` evicts a dead runner of the same name after a VM refresh; harmless
on first run. `$REPO_SLUG` label lets workflows pin `runs-on` to this repo's
runner if you ever run multi-repo on one VM.)

## Step 5 — enable the service

The unit is pre-baked (disabled) on the template. Just enable:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now gh-actions-runner.service
sleep 2
systemctl is-active gh-actions-runner.service   # → active
```

## Step 6 — ensure workflows in the repo

Copy the four factory workflows; commit only if changed. **Add files
explicitly** (VM policy forbids `git add -A`/`git add .`):
```bash
mkdir -p "$REPO_DIR/.github/workflows"
cp ~/factory/templates/github/workflows/*.yml "$REPO_DIR/.github/workflows/"
cd "$REPO_DIR"
if ! git diff --quiet -- .github/workflows 2>/dev/null \
   || [ -n "$(git ls-files --others --exclude-standard -- .github/workflows)" ]; then
  git add .github/workflows/implement-ready-issues.yml \
          .github/workflows/review-and-fix.yml \
          .github/workflows/human-review.yml \
          .github/workflows/teardown.yml
  git commit -m "factory: workflows"
  git push
fi
```

## Step 7 — labels

Idempotent (`|| true` — `gh` errors if a label exists):
```bash
gh label create ready --repo "$REPO_SLUG" --color 0E8A16 \
  --description "Plan approved; factory will implement" 2>/dev/null || true
gh label create human-review --repo "$REPO_SLUG" --color 5319E7 \
  --description "PR ready for human smoke test on the VM" 2>/dev/null || true
```

## Step 8 — verify the loop

The definitive check: GitHub sees this runner online.
```bash
gh api repos/$REPO_SLUG/actions/runners \
  --jq ".runners[] | select(.labels[].name==\"factory\") | {name,state, busy}"
# expect: {"name":"...","state":"online","busy":false}
```
If state is `offline`, check `journalctl -u gh-actions-runner -n 50`.

## Report to the user

One line + the trigger recipe. No narrative:

- ✅ `<owner>/<repo>` is wired. Runner online.
- To fire: create an issue, plan it with an agent, then `gh issue edit <n>
  --repo <owner>/<repo> --add-label ready`.
- Smoke test a merged PR: label it `human-review` → app on
  `https://$(hostname).exe.xyz:<port>`.

## Re-run / refresh

This whole skill is idempotent. After `cp rails-vm-template <vm>` to refresh
providers/tools: run `rails-exe-setup` (re-checkout/re-deps if needed), then
this skill again. Step 4's `--replace` reclaims the runner slot; nothing else
needs manual attention. That's the monthly flow.

## What this skill never does

- Clone the app repo (that's `rails-exe-setup`).
- Touch `~/.pi/agent/auth.json` or provider keys (that's `factory-ops`).
- Edit `models.env` (that's `factory-ops`).
- Ask for a GitHub token, secret, or API key. The `gh` on the VM is the only
  credential; it mints the short-lived runner token itself.
- Run any factory task (implement/review). This skill only wires the trigger;
  `run.sh` does the work, invoked by GitHub via the runner.
