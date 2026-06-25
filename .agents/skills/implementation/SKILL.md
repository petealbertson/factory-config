---
name: implementation
---

# Implementation

Implement a GitHub issue, OR address review findings on an existing branch. Your behavior differs slightly by mode, detected from the prompt.

You always run inside a git worktree whose working directory is the current process's `$PWD`. The DB is already cloned and named; `config/database.yml` resolves the right one automatically. Do not edit DB config.

## Inputs

- `REPO_SLUG` (owner/repo) and the issue number are in your prompt.
- `gh` is authenticated (via the exe.dev GitHub integration). Use it for all GitHub I/O.
- If the prompt contains a "Findings:" block, this is a **fix pass** — see the last section.

## Workflow

### 1. Read the issue
`gh issue view <n> -R <slug>`. Read the body and comments. Do not implement from the title alone.

### 2. Inspect the codebase
Search the current checkout. Identify the affected files, existing patterns, and the validation command (README, `package.json`/`Gemfile`, CI config).

### 3. Implement
Smallest cohesive change. Follow existing style. Update tests when part of the change. No unrelated refactors.

### 4. Validate
Run the repo's test command. At minimum: the targeted test, then the full suite if fast. Do not skip. If a pre-existing test fails unrelated to your change, note it but proceed.

### 5. Commit & push
`git add -A && git commit` with a clear message. Push the branch you are on.

### 6. PR (initial implement only — NOT on a fix pass)
`gh pr create` against the default branch. PR body must include:
- Link to the issue
- Summary of the change
- Validation commands run + results
- `Closes #<n>` if the implementation fully resolves the issue

Then comment on the issue with the PR URL. Do **not** describe the work as complete before the PR exists.

### 7. Fix pass (when the prompt contains a "Findings:" block)
This is a fix pass on an existing branch, driven by reviewer findings.

**Validate each finding before fixing.** A finding is a request, not an
order — read it, confirm it applies, then either:
- **Fix it** — make the smallest change that resolves it, in the established
  style. Update tests if the behavior changed.
- **Push back** — if a finding is wrong, already-addressed, or would harm the
  code, **do not silently ignore it.** Post a comment on the PR explaining why
  you disagree (one or two sentences, referencing the finding id, e.g. "F2:
  …"), and leave that code unchanged.

Either way: commit and push to the current branch. Do **not** open a new PR.
Do not comment on the issue. Run the tests again. The reviewer will re-review
on the next pass; pushing back on a finding is how you converge honestly
rather than gaming the count.

## Guardrails

- Never expose secrets, tokens, or raw env in commits, PRs, or comments.
- Never close, assign, or relabel the issue unless asked.
- Never make unrelated changes.
- Never claim validation passed if it did not run or failed.
- Initial pass: do not post "done" without a PR URL.
- Fix pass: do not open a new PR; push to the existing branch only.
- Fix pass: never silently drop a finding. Fix it, or post a comment on the PR
  explaining why you disagree. Silent drops are how loops stall.
