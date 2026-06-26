# Shared review rules — read by every review skill

This fragment is NOT a skill on its own. `run.sh` inlines it as a
command-line `@file` ahead of each review skill, so the emission bar, the
scope rule, and the FINDINGS output format are defined once and shared by the
trivial-pass reviewer, every specialist reviewer, and the coordinator.

## Approval

There is no "approved with comments" state. **Approval is emitting zero
findings** — emitting zero (after coordination) flips the PR to
`needs-human-review`. So the emission bar below cuts both ways: emit a
finding only if it is worth a fix round; withhold if it is not. The loop is
capped at 3 review passes, so nitpicking burns the budget that should go to
real issues.

## Emission bar

Before emitting a finding, apply this test:

- **Emit** if the code should change: correctness bugs, security issues, data
  loss, broken or missing tests for the changed behavior, departure from the
  repo's established patterns that introduces real risk, missing error
  handling for realistic cases.
- **Do not emit** for stylistic preference, equally-valid alternatives,
  hypothetical concerns with no concrete trigger, or anything you would not
  want fixed.

If in doubt whether something is worth fixing, **do not emit it.** The cost
of emitting is that it will be fixed in a separate agent pass.

## Scope discipline

Review only the diff provided inline in your prompt (under `<diff>` or
inlined via `@file`) plus its immediate context. Do not:

- Use `read` / `grep` / `glob` / `bash` to explore the repository. There may
  be no checkout available to you, and exploring wastes time and tokens.
- Propose architectural rewrites.
- Flag pre-existing issues unrelated to this change.

Findings must be addressable in a fix pass on the same branch. If you cannot
locate a line within the inline diff, omit the finding rather than going
looking for it.

## Output format

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

Do not include a summary paragraph, congratulations, or anything outside the
block. The runner parses `^F[0-9]` lines to count findings.

Every finding must specify **what to change**, not just what is wrong, and
pin a real file path and line from the diff. Do not return findings without a
real file path and line number — if you cannot locate the exact line, omit
the finding.

## 37signals style lens

**Apply this lens when reviewing Ruby on Rails projects** (look for
`app/models`, `config/routes.rb`, `Gemfile` with `rails`, etc.). For
non-Rails codebases, skip this section entirely.

Use this as a **style lens**, not a rigid rulebook. Project conventions and
`AGENTS.md` always win.

### Core ideas

- Prefer vanilla Rails over custom layers and framework-shaped abstractions.
- Optimize for clarity, directness, and shipping useful increments.
- Keep controllers thin; put real domain behavior in models or small POROs
  that earn their existence.
- Avoid speculative service objects, wrappers, and indirection.
- Favor domain names over technical names.
- Prefer framework features and database guarantees when they simplify code.

### Don't over-apply

- Don't mimic 37signals if it conflicts with local conventions or clarity.
- Don't reject a small PORO or service-like object if it is obviously the
  clearest choice.
- Don't turn this into a style-only nitpick checklist.
