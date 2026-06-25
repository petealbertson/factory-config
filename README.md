# factory-config

Shared configuration for the cloud factory: GitHub issues become PRs via agents (Pi) running on a warm per-repo exe.dev VM.

## How dispatch works

A **self-hosted GitHub Actions runner** runs on the factory VM as a systemd service. The four workflows use `runs-on: [self-hosted, linux, X64]` and their `run:` steps execute locally on the VM, calling `~/factory/run.sh` directly. No exe.dev API, no SSH dispatch, no timeout.

```
issue labeled 'ready' ─► [self-hosted runner on VM] ─► run.sh implement <n> ─► PR
PR opened/sync      ─► [self-hosted runner on VM] ─► run.sh review-and-fix <n>
PR labeled 'human-review' ─► run.sh human-review <n> ─► app server on proxied port
PR closed            ─► run.sh teardown <n>
```

## What's here

| Path | Purpose |
|---|---|
| `run.sh` | The runner. Subcommands: `implement`, `review-and-fix`, `human-review`, `stop-server`, `teardown`. |
| `.agents/skills/` | The `implementation` and `review` Pi skills. |
| `models.env` | Role → model bindings. **Edit to swap models.** |
| `repo.env` (gitignored) | Which repo lives on *this* VM. Written by `install.sh`. |
| `templates/github/workflows/` | The four GitHub Actions, copied into consuming repos. |
| `scripts/install.sh` | One-time per repo VM: clone factory, copy workflows, write `repo.env`, install + register the runner, enable systemd service. |
| `scripts/setup-repo.sh` | One-time per repo: create GitHub labels, confirm runner is connected. |
| `shelley-skills/factory-ops/` | Shelley skill for managing providers/models/VMs. |

## Architecture (summary)

- **One warm VM per repo** holds Ruby + deps + DB template + Pi + the self-hosted runner. Also your interactive dev box.
- GitHub events trigger Actions that run locally on the VM via the runner; they call `run.sh <kind> <n>`.
- Per-task isolation = `git worktree` + a cloned DB (`createdb -T template`). Branches are durable.
- `gh` authenticates inside jobs using the VM's existing `gh` login (`petealbertson`).
- Models/keys: providers live in `~/.pi/agent/{models.json,auth.json}`; role bindings in `models.env`. exe.dev gateway is never used for execution.

## Lifecycle

```
plan (Pi, interactive) → issue on GitHub → label 'ready'
  → implement → PR opened → review-and-fix (max 2 rounds, all findings must-fix)
  → label 'human-review' → app served on a proxied port → you merge
  → teardown (PR closed)
```

## Setting up a new repo VM

On a fresh VM copied from `rails-vm-template` (which already has the runner installed if you propagated it):

```bash
# 1. Get a short-lived registration token (valid ~1h):
gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token --jq .token

# 2. In the repo checkout:
git clone https://github.com/<you>/<repo> && cd <repo>
bash ~/factory/scripts/install.sh <owner>/<repo> <token-from-step-1>

# 3. Commit + push the workflows:
git add .github/workflows && git commit -m 'factory workflows' && git push

# 4. Create labels on the repo:
bash ~/factory/scripts/setup-repo.sh <owner>/<repo>
```

If the template VM already has `~/actions-runner` and the systemd service, `install.sh` reuses them and only re-registers to the new repo.
