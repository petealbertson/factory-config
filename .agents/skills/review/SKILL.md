---
name: review
---

# Review

Review a pull request and emit findings. **Every finding you emit is must-fix.** The loop stops only when you emit zero findings. There is no "approved with comments" category — if a comment is worth making, it is a finding and it will be fixed.

You run inside the PR's worktree. The branch and PR number are in your prompt.

## Approval

There is no "approved with comments" state. **Approval is emitting zero
findings** — that single signal flips the PR to `needs-human-review`. So the
emission bar below cuts both ways: emit a finding only if it's worth a fix
round; withhold if it's not. The loop is capped at 3 review passes, so
nitpicking burns the budget that should go to real issues.

## Emission bar

Before emitting a finding, apply this test:

- **Emit** if the code should change: correctness bugs, security, data loss, broken or missing tests for the changed behavior, departure from the repo's established patterns that introduces real risk, missing error handling for realistic cases.
- **Do not emit** for stylistic preference, equally-valid alternatives, hypothetical concerns with no concrete trigger, or anything you would not want fixed.

If in doubt whether something is worth fixing, do not emit it. The cost of emitting is that it will be fixed.

## Workflow

### 1. Gather context
`gh pr view <n> -R <slug> --json title,body,files` and `gh pr diff <n> -R <slug>`. Read the linked issue (the PR body should reference it). Understand what the change intends.

### 2. Review
Read every changed file. Run the tests if cheap. For each genuine issue, formulate a finding that specifies **what to change**, not just what is wrong.

### 3. Output
Respond with ONLY the findings block, in this exact format, nothing else:

```
FINDINGS:

F1
location: path/to/file.rb:42
problem: <one sentence>
fix: <one sentence, the requested change>

F2
location: spec/requests/todos_spec.rb
problem: <one sentence>
fix: <one sentence>
```

If there are no findings, output exactly:

```
FINDINGS:

(none)
```

Do not include a summary paragraph, congratulations, or anything outside the block. The runner parses `^F[0-9]` lines to count findings.

## Scope

Review only the diff plus its immediate context. Do not propose architectural rewrites. Do not flag pre-existing issues unrelated to this change. Findings must be addressable in a fix pass on the same branch.
