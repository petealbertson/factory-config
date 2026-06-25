# factory-config

Shared configuration for the cloud factory: a setup where GitHub issues become PRs via agents running on a warm per-repo exe.dev VM.

## What's here

- `run.sh` — the runner. One script, four subcommands. Invoked on the repo VM by GitHub Actions via the exe.dev HTTPS API.
- `.agents/skills/` — the `implementation` and `review` Pi skills.
- `models.env` — role → model bindings. **Edit this to swap models.**
- `repo.env` (gitignored) — which repo lives on *this* VM.
- `templates/github/workflows/` — the four GitHub Actions, copied into consuming repos.
- `scripts/install.sh` — set up a repo VM: clone this repo, copy workflows, write `repo.env`.
- `shelley-skills/factory-ops/` — Shelley skill for managing providers/models/VMs.

## Architecture (summary)

- One warm VM per repo holds Ruby + deps + DB template + Pi. Also your interactive dev box.
- GitHub events trigger thin Actions that call `ssh <vm> ~/factory/run.sh <kind> <n>` via `exe.dev/exec`.
- Per-task isolation = `git worktree` + a cloned DB (`createdb -T template`). Branches, not worktrees, are durable.
- Models/keys: providers live in `~/.pi/agent/{models.json,auth.json}`; role bindings in `models.env`. exe.dev gateway is never used for execution.

## Lifecycle

```
plan (Pi, interactive) → issue on GitHub → label 'ready'
  → implement → PR opened → review-and-fix (max 2 rounds, all findings must-fix)
  → label 'human-review' → app served on a proxied port → you merge
  → teardown (PR closed)
```

## Setting up a new repo VM

On a fresh VM copied from `rails-vm-template`:

```bash
git clone https://github.com/<you>/<repo> && cd <repo>
bash <(curl -fsSL https://raw.githubusercontent.com/petealbertson/factory-config/main/scripts/install.sh)
```

Then in the GitHub repo: add variable `FACTORY_VM`, secret `EXEDEV_API_TOKEN`, and labels `ready` / `human-review`.
