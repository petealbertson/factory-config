# factory-config

The cloud factory: GitHub issues become PRs via Pi agents running on a warm
per-repo exe.dev VM. This repo is the shared logic — runner, skills, workflows,
model bindings. No per-repo scripts; setup is a Shelley/Pi skill.

## How dispatch works

A **self-hosted GitHub Actions runner** runs on the repo VM as a systemd
service. GitHub long-polls the runner directly — no exe.dev API in the path,
no SSH dispatch, no timeout. Workflows use `runs-on: [self-hosted, linux, X64]`
and their `run:` steps execute locally, calling `~/factory/run.sh`.

### Control-plane dispatch path (single `workflow_dispatch`)

`factory-app` is the dispatcher. It starts a run by triggering `workflow_dispatch`
on `.github/workflows/factory-dispatch.yml`. The workflow passes `FACTORY_RUN_ID`,
`FACTORY_KIND`, `FACTORY_TARGET`, `FACTORY_MODE`, `FACTORY_ROUND`, and a single-use
`FACTORY_DISPATCH_TOKEN` to `run.sh`. The runner exchanges the dispatch token for a
callback token and a role-specific GitHub App token, configures git identity/auth
for the role, and runs the requested kind.

In `pipeline` mode, completions such as `needs_review` and `needs_fix` are reported
back to the control plane, which schedules the next review or fix pass so
factory-managed PRs loop autonomously. In `point` mode the runner performs one
bounded review, fix, triage, or implementation and stops.

Review passes post formal PR reviews from the reviewer identity, while
implement/fix commits and PRs use the implementer identity.


```
issue: ready-for-implementation ──► run.sh triage
  ├─ PROCEED  ──► run.sh implement ──► PR: ready-for-review
  └─ REFINE   ──► needs-refinement  (terminal; human sharpens, re-labels)
PR: ready-for-review             ──► run.sh review
  ├─ 0 findings (or round 3)     ──► needs-human-review  (terminal)
  └─ findings + round < 3        ──► fixes-requested ──► run.sh fix ──► ready-for-review
PR closed                        ──► run.sh teardown
```

The state machine is still visible through labels, but **only the control plane
triggers the next step**. Pull up any PR and its single state label tells you
where it is. Bounded at 3 review passes (initial + 2 fix rounds); if it can't
converge, it lands on `needs-human-review` with the last findings instead of
looping. An issue that isn't defined enough to act on lands on
`needs-refinement` with the specific gaps before any implementation cycles are
spent on it.

## What's here

| Path | Purpose |
|---|---|
| `run.sh` | The runner. Dispatched kinds: `triage`, `implement`, `review`, `fix`, `teardown`. |
| `.agents/skills/` | The `triage`, `implementation`, and `review` Pi skills (used by `run.sh`). |
| `models.env` | Role → model bindings. Edit + commit + fan out to swap models. |
| `templates/github/workflows/` | One dispatch workflow, installed into consuming repos. |
| `shelley-skills/factory-install/` | Skill: bind a fresh VM to a repo, register it with the control plane. |
| `shelley-skills/factory-ops/` | Skill: add/swap inference providers, models, list VMs. |

Not in git: `repo.env` (per-VM, written by `factory-install`), `state/`
(per-PR round counter + last findings, wiped on teardown).

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

Label an issue `ready-for-implementation`. It fires end-to-end: triage checks
the issue is defined enough, then implement opens the PR and the review loop
runs. If the issue is vague, it lands on `needs-refinement` first instead.

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
plan (interactive) → issue → label 'ready-for-implementation'
  → triage → PROCEED → implement → PR: ready-for-review
  → review → fixes-requested → fix → ready-for-review  (max 3 reviews)
  → needs-human-review → you smoke-test on the VM → you merge
  → teardown (PR closed: worktree + DB + branch gone, main synced)
```

If triage emits REFINE, the issue lands on `needs-refinement` with the specific
gaps; no implementation cycles are spent until a human sharpens it and
re-labels `ready-for-implementation`.

## Inference

User's own providers only — never the exe.dev gateway for execution. Bindings
in `models.env`; credentials in `~/.pi/agent/auth.json` (baked into the
template, flow out via `cp`). Manage via the `factory-ops` skill.
