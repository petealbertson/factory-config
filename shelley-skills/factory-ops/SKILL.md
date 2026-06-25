---
name: factory-ops
description: Manage the cloud factory config (providers, models, per-repo VMs). Use when the user wants to add/change an inference provider, swap which model a factory role uses, refresh a VM from the template, or list/status factory VMs.
---

# Factory Ops

Manage the configuration of the cloud factory. The factory runs on per-repo exe.dev VMs (tagged `factory`); its shared config lives in `~/factory` (a clone of `petealbertson/factory-config`) on every such VM. This skill edits that shared config and orchestrates VMs. It does **not** run factory tasks.

## Layout (memorize this)

- `~/factory/run.sh` — the runner. Subcommands: implement, review, fix, teardown.
- `~/factory/models.env` — role→model bindings (`IMPLEMENT_MODEL`, `REVIEW_MODEL`, `FIX_MODEL`). **The file you edit to swap models.**
- `~/.pi/agent/models.json` — provider/model registry. Edit when adding a provider.
- `~/.pi/agent/auth.json` — provider credentials. **Never edit by hand, never read aloud, never echo.**
- `~/factory/repo.env` — which repo this VM runs. Per-VM, not in git. Written by `factory-install`.
- `~/factory/.agents/skills/{implementation,review}/SKILL.md` — the factory skills (used by `run.sh`).
- `~/actions-runner/` + `gh-actions-runner.service` — the self-hosted runner. Pre-baked on the template (disabled); enabled/registered by `factory-install`.

## Sibling skills

- `factory-install` — bind a fresh VM to a repo (register runner, write repo.env, workflows, labels). Per-repo bootstrap. This skill does NOT overlap.
- `rails-exe-setup` — clone + deps + PG + dev server. Dev-environment bootstrap. Run before `factory-install` for a Rails repo.

## Inference plane rule

Factory execution uses ONLY the user's own providers (via `models.env`/`auth.json`). The exe.dev LLM gateway is a backup for *management* only and must never be written into `models.env`.

## Operations

### Swap a model (the common monthly case)

User says e.g. "swap review to glm-4.5-air" or "use deepseek for implementation".

1. Confirm the model is known: `pi --list-models | grep <provider>`.
2. Edit the relevant line in `~/factory/models.env`. Do not touch anything else.
3. `git -C ~/factory commit -am "models: <change>" && git -C ~/factory push`
4. Fan out: list VMs tagged `factory` (`ssh exe.dev ls --json | jq '.vms[] | select(.tags[]? == "factory") | .vm_name'`), and on each run `ssh <vm> "git -C ~/factory pull --ff-only"`.
5. Report which VMs updated. No keys involved.

### Add a provider

User says "add Codex" / "add a provider, I have an API key".

1. Add the provider's models to `~/.pi/agent/models.json` if not built-in. Confirm with `pi --list-models`.
2. Commit and push `models.json`... **wait**: `models.json` is per-VM, not in `~/factory`. For shared config it must go in `~/factory/models.json` and be symlinked or copied to `~/.pi/agent/`. Decide with the user; default: edit `~/factory/models.json` and symlink.
3. **Credentials**: the user must run `pi` → `/login` → select provider → paste key **at a terminal**, never in this chat. Tell them the exact command. Do not offer to run it for them. Do not ask to see the key.
4. To propagate to existing repo VMs without re-login: plan a refresh-from-template (below). Otherwise the user logs in on each VM.

### Refresh a repo VM from template (the monthly flow)

For bringing fresh keys/config/tooling to a repo VM without per-VM `/login`.

1. Confirm the repo VM is idle: `ssh <vm> "ls ~/factory/servers/*.pid 2>/dev/null"` and check for open PRs (`gh pr list --repo <slug> --state open`). If anything is active, STOP and tell the user.
2. `ssh exe.dev cp rails-vm-template <new-vm>` (destroys and recreates the VM).
3. On the new VM, tell Shelley (or Pi): run `rails-exe-setup` then `factory-install` for `<slug>`. Both are idempotent; `factory-install` re-registers the runner with `--replace` and rewrites `repo.env`.
4. Confirm with `gh api repos/<slug>/actions/runners --jq '.runners[] | {name,state}'` — runner `online`.
5. Retire the old VM after the user confirms.

Provider keys live in the template's `auth.json` and ride along on `cp` — no per-VM `/login`.

### List / status

`ssh exe.dev ls --json | jq '.vms[] | select(.tags[]? == "factory") | {name: .vm_name, status}'` — list factory VMs.
`ssh <vm> "gh pr list --repo <slug>"` — open PRs on a repo VM.

## Rules

- Never print, echo, cat, or commit `auth.json` or any API key.
- Never paste a key into this chat. If the user offers one, stop them and give the `/login` command.
- `models.env` is safe to edit and commit (model names only).
- When unsure which file a config lives in, check the Layout list above before editing.
- Fan-out commands run over the exe.dev API (`ssh exe.dev exec` or direct `ssh <vm>`). Report results concretely.
