# factory-config

The cloud factory: GitHub issues become PRs via Pi agents running on a warm
per-repo exe.dev VM. This repo is the shared logic — runner, skills, workflows,
model bindings. No per-repo scripts; setup is a Shelley/Pi skill.

## How dispatch works

A **self-hosted GitHub Actions runner** runs on the repo VM as a systemd
service. GitHub long-polls the runner directly — no exe.dev API in the path,
no SSH dispatch, no timeout. Workflows use `runs-on: [self-hosted, linux, X64]`
and their `run:` steps execute locally, calling `~/factory/run.sh`.

```
issue labeled 'ready'        ─► run.sh implement <n>   ─► PR
PR opened/synchronize        ─► run.sh review-and-fix <n>
PR labeled 'human-review'    ─► run.sh human-review <n> ─► app on proxied port
PR closed                    ─► run.sh teardown <n>
```

## What's here

| Path | Purpose |
|---|---|
| `run.sh` | The runner. Subcommands: `implement`, `review-and-fix`, `human-review`, `stop-server`, `teardown`. |
| `.agents/skills/` | The `implementation` and `review` Pi skills (used by `run.sh`). |
| `models.env` | Role → model bindings. Edit + commit + fan out to swap models. |
| `templates/github/workflows/` | The four Actions, copied into consuming repos. |
| `shelley-skills/factory-install/` | Skill: bind a fresh VM to a repo (register runner, write repo.env, ensure workflows/labels). |
| `shelley-skills/factory-ops/` | Skill: add/swap inference providers, models, list VMs. |

Not in git: `repo.env` (per-VM, written by `factory-install`), `servers/`.

## Sources of truth

| Thing | Source of truth | Propagates by |
|---|---|---|
| Environment: Ruby, Postgres, Pi, **provider keys** | `rails-vm-template` VM | `ssh exe.dev cp rails-vm-template <vm>` |
| Factory logic: run.sh, skills, workflows, models.env | this repo | `git clone`/`pull` in `~/factory` |
| Shared skills: factory-install, factory-ops, rails-exe-setup | `petealbertson/pi-agent-config` | `git pull` in `~/projects/pi-agent-config` |
| Per-repo binding: which repo lives here | `~/factory/repo.env` | written by `factory-install` |

## The template ships ready, not registered

`rails-vm-template` is pre-baked with `~/factory` (this clone),
`~/actions-runner/` (runner binary, **no registration**), and a **disabled**
`gh-actions-runner.service`. Nothing repo-specific lives on the template, so
`cp` inherits a clean base. Registration is the one repo-specific step, done by
`factory-install` after `cp`. The registration token is minted by the `gh`
already on the VM — **no manual tokens, no GitHub secrets, no exe.dev API
key.**

## Spin up a new repo VM

```bash
# on your laptop: clone the template
ssh exe.dev cp rails-vm-template new-app-vm
# then on new-app-vm, in Shelley (or Pi):
```
> use `rails-exe-setup` for `petealbertson/new-app`
> then use `factory-install` for `petealbertson/new-app`

Label an issue `ready`. It fires end-to-end.

## Refresh a repo VM (the monthly flow)

Providers/tools changed on the template? Just recopy and re-bind:
```bash
ssh exe.dev cp rails-vm-template new-app-vm   # destroys and recreates
# on the new VM: rails-exe-setup, then factory-install (idempotent)
```
`factory-install` is idempotent — it re-registers with `--replace` and
re-writes `repo.env`. No manual fix-up. Branches/DBs are per-PR and live in
the app checkout, unaffected.

## Lifecycle

```
plan (interactive) → issue → label 'ready'
  → implement → PR → review-and-fix (max 2 rounds, zero findings = done)
  → label 'human-review' → app served on a proxied port → you merge
  → teardown (PR closed)
```

## Inference

User's own providers only — never the exe.dev gateway for execution. Bindings
in `models.env`; credentials in `~/.pi/agent/auth.json` (baked into the
template, flow out via `cp`). Manage via the `factory-ops` skill.
