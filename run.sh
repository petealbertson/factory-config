#!/usr/bin/env bash
# Cloud factory runner. Invoked on a per-repo VM by a self-hosted GitHub
# Actions runner that runs on this same VM:
#   bash ~/factory/run.sh <kind> [args]
#
# One VM == one repo (the "repo VM"). This script is repo-agnostic; the repo it
# targets is declared in repo.env. It is Rails-aware (db:prepare, worktrees).
#
# Subcommands (each is one step in the loop; the loop is driven by GitHub label
# events, NOT by push):
#   triage <issue>      gate before implement: is the issue defined enough? PROCEED -> implement, REFINE -> needs-refinement
#   implement <issue>   implement a ready-for-implementation issue; open PR; label it ready-for-review
#   review <pr>         one review pass; 0 findings -> needs-human-review, else fixes-requested (or needs-human-review at round 3)
#   fix <pr>            one fix pass from saved findings; re-label ready-for-review
#   teardown <pr>       on PR close: remove worktree, drop DB, delete branch, sync main, wipe state
#
# State machine (one state label on the PR/issue at a time):
#   issue: ready-for-implementation -> [triage] -> implement  (PROCEED)
#                                           └──> needs-refinement  (REFINE; human sharpens, re-labels ready-for-implementation)
#   issue: ready-for-implementation -> [implement] -> PR: ready-for-review
#   PR: ready-for-review -> [review] -> fixes-requested -> [fix] -> ready-for-review  (loop, max 3 reviews)
#                                    -> [review, 0 findings OR round 3] -> needs-human-review (terminal)
#   PR closed -> [teardown]
#
# The round counter and last findings live in ~/factory/state/pr<N>.* so they
# survive across the separate workflow runs that make up the loop.
#
# PR stage == worktree + DB clone for one PR branch. Persists across implement /
# review / fix until teardown.

set -euo pipefail

FACTORY_DIR="${FACTORY_DIR:-$HOME/factory}"

# --- activate mise so ruby/bundle/rails/pi resolve in any shell (runner job, ssh, cron) ---
# The self-hosted runner job shell does NOT inherit the interactive login PATH,
# so mise's shims are absent and `bundle`/`pi` are unresolvable.
# Use `mise activate --shims` (not the default hook-based `mise activate`):
# the default installs a chpwd/prompt hook that only fires on the NEXT cd/prompt,
# which never happens inside a non-interactive `bash -e` job script. --shims
# puts real shims on PATH immediately, so tools resolve regardless of CWD.
# No-op if mise is missing or already activated.
if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate --shims bash)"
fi

# --- PostgreSQL: bare psql/createdb/dropdb default the db name to the ---
# --- connecting role (e.g. "exedev"), which has no same-named database. ---
# --- Pin a real default db so `psql -tAc ...` works without -d.        ---
export PGDATABASE="${PGDATABASE:-postgres}"

# --- shared config (model bindings; safe to commit) ---
# shellcheck source=/dev/null
source "$FACTORY_DIR/models.env"

# --- per-VM config (which repo lives here) ---
# shellcheck source=/dev/null
source "$FACTORY_DIR/repo.env"

: "${REPO_DIR:?repo.env must set REPO_DIR (path to the repo checkout on this VM)}"
: "${REPO_SLUG:?repo.env must set REPO_SLUG (owner/repo)}"

REPO_BASE="$(basename "$REPO_DIR")"
DB_PREFIX="$(echo "$REPO_BASE" | tr -c 'a-zA-Z0-9' '_' | tr 'A-Z' 'a-z')"
TEMPLATE_DB="${DB_PREFIX}_test_template"
GIT_BRANCH_MAIN="$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null || echo main)"

# loop cap: 3 review passes = initial + 2 fix rounds. Round 3 with remaining
# findings escalates to needs-human-review instead of looping further.
MAX_ROUNDS=3

log() { printf '\033[1;34m[factory]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[factory error]\033[0m %s\n' "$*" >&2; exit 1; }

sanitize() { echo "$1" | tr -c 'a-zA-Z0-9' '_' | tr 'A-Z' 'a-z'; }

# worktree dir for a branch
wt_dir() { printf '%s/../%s-%s\n' "$REPO_DIR" "$REPO_BASE" "$(sanitize "$1")"; }
# db name for a worktree dir (or for "main")
db_for() {
  local base; base="$(basename "$1")"
  printf '%s_%s\n' "$DB_PREFIX" "$(sanitize "$base")"
}

# --- PR state (round counter + last findings); survives across workflow runs ---
state_dir() { printf '%s/state\n' "$FACTORY_DIR"; }
round_file() { printf '%s/state/pr%s.round\n' "$FACTORY_DIR" "$1"; }
findings_file() { printf '%s/state/pr%s.findings\n' "$FACTORY_DIR" "$1"; }

# transition the PR's state label. Best-effort remove of the old (gh errors if the
# label isn't present), then the add (which fires the `labeled` event that drives
# the next step). Agents never call this — only the runner does.
transition_label() {
  local pr="$1" old="$2" new="$3"
  if [ -n "$old" ]; then
    gh pr edit "$pr" --repo "$REPO_SLUG" --remove-label "$old" 2>/dev/null || true
  fi
  gh pr edit "$pr" --repo "$REPO_SLUG" --add-label "$new"
}

# ensure the template DB exists (migrated). cheap to call repeatedly.
ensure_template_db() {
  log "ensuring template DB: $TEMPLATE_DB"
  if ! psql -tAc "SELECT 1 FROM pg_database WHERE datname='$TEMPLATE_DB'" | grep -q 1; then
    createdb "$TEMPLATE_DB"
    ( cd "$REPO_DIR" && RAILS_ENV=test DATABASE_NAME="$TEMPLATE_DB" bundle exec rails db:migrate )
  fi
}

# ensure a worktree exists for BRANCH (created from origin if missing), with a
# cloned DB. idempotent.
ensure_pr_stage() {
  local branch="$1"
  local dir; dir="$(wt_dir "$branch")"
  local db; db="$(db_for "$dir")"
  ensure_template_db
  if [ ! -d "$dir" ]; then
    log "creating worktree $dir on branch $branch"
    git -C "$REPO_DIR" worktree add "$dir" "$branch" 2>/dev/null \
      || git -C "$REPO_DIR" worktree add "$dir" -B "$branch" "origin/$branch"
  fi
  if ! psql -tAc "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1; then
    log "cloning DB $db from template"
    createdb "$db" -T "$TEMPLATE_DB"
  fi
  printf '%s\n' "$dir"
}

# run pi headlessly. $1=skill name, $2=model, $3=cwd, rest=prompt
run_pi() {
  local skill="$1" model="$2" cwd="$3"; shift 3
  local prompt="$*"
  local skillfile="$FACTORY_DIR/.agents/skills/$skill/SKILL.md"
  [ -f "$skillfile" ] || skillfile="$REPO_DIR/.agents/skills/$skill/SKILL.md"
  log "pi: skill=$skill model=$model cwd=$cwd"
  cd "$cwd"
  # NOTE: this pi version has no --cwd flag; we already `cd "$cwd"` above so the
  # working directory is correct. Callers embed the skill-file path in $prompt
  # ("Read .../SKILL.md and follow it"), since --skill wiring is not used here.
  pi --model "$model" -p "$prompt"
}

# The shared review-rules fragment, read by every review skill (specialists,
# coordinator, and the trivial single pass). Centralized so the emission bar,
# scope discipline, and FINDINGS output format are defined once.
review_shared_file() { printf '%s/.agents/skills/review-shared.md\n' "$FACTORY_DIR"; }

# Resolve a skill's SKILL.md path (factory dir first, then repo-local).
review_skill_file() {
  local skill="$1"
  local f="$FACTORY_DIR/.agents/skills/$skill/SKILL.md"
  [ -f "$f" ] || f="$REPO_DIR/.agents/skills/$skill/SKILL.md"
  printf '%s\n' "$f"
}

# Same resolution, named for the triage skill (kept separate from
# review_skill_file for clarity even though the logic is identical).
triage_skill_file() {
  local f="$FACTORY_DIR/.agents/skills/triage/SKILL.md"
  [ -f "$f" ] || f="$REPO_DIR/.agents/skills/triage/SKILL.md"
  printf '%s\n' "$f"
}

# Run one review agent headlessly, tool-free, with all inputs inlined via
# pi's @file expansion. `@file` only expands for command-line args (NOT for
# files the agent reads via its read tool), so callers MUST pass everything
# here. --no-tools because the complete context is inlined; roaming the repo
# just wastes tokens (same lesson as the OpenCode version).
#
# Args: $1=skill, $2=model, $3=cwd, then varargs of @file paths + trailing prompt.
run_review_agent() {
  local skill="$1" model="$2" cwd="$3"; shift 3
  log "pi-review: skill=$skill model=$model cwd=$cwd"
  cd "$cwd"
  pi --no-tools --model "$model" "$@"
}

# ---------------------------------------------------------------- kind: triage
# Gate before implementation. Tool-free single pass over the issue body (+
# comments): does the implementer have enough to act without guessing?
#   DECISION: PROCEED  -> chain into kind_implement on the same invocation
#   DECISION: REFINE   -> post the blockers as an issue comment and transition
#                         the issue ready-for-implementation -> needs-refinement.
# Runs under set -euo pipefail; kind_implement is invoked in-process (no subshell)
# so a REFINE-free issue reaches implementation in one workflow run.
kind_triage() {
  local issue="$1"
  log "triage: issue #$issue in $REPO_SLUG"

  # Fetch the issue body and its comments into a workdir file. The triage agent
  # is --no-tools, so everything it sees must be inlined via @file. One JSON call
  # gives title + body + all comments cleanly (no double-fetch, no UI chrome).
  local workdir; workdir="$(mktemp -d)"
  local issue_file="$workdir/issue.md"
  gh issue view "$issue" --repo "$REPO_SLUG" --json title,body,comments \
    -q '"# " + .title + "\n\n" + .body + 
         (if (.comments|length) > 0 
          then "\n\n---\n## Comments\n" +
            ([.comments[] | "**" + (.author.login // "unknown") + ":**\n" + .body] | join("\n\n"))
          else "" end)' \
    > "$issue_file" 2>/dev/null \
    || die "could not fetch issue #$issue from $REPO_SLUG"
  [ -s "$issue_file" ] || die "issue #$issue fetched empty; aborting triage"

  local decision
  decision="$(run_review_agent triage "$TRIAGE_MODEL" "$REPO_DIR" \
    "@$(triage_skill_file)" "@$issue_file" \
    "You are triaging issue #$issue in $REPO_SLUG to decide whether it is ready for an implementer agent. The issue (title, body, comments) is inlined above, followed by your instructions. Decide PROCEED or REFINE and output ONLY the decision block.")"
  rm -rf "$workdir" 2>/dev/null || true

  # The agent's contract: a line starting 'DECISION: PROCEED' or 'DECISION: REFINE'.
  # Tolerate leading whitespace (the model sometimes wraps in a ``` fence) and
  # case. Default to PROCEED on any parse failure: a malformed agent response
  # must not block an otherwise-ready issue (false PROCEED is caught downstream
  # by review; false REFINE wastes a human round-trip nothing recovers).
  #
  # NOTE: do NOT use `exit` + `END` here — awk runs END even after exit, so a
  # matched REFINE would also print the END default, yielding 'refine\nproceed',
  # which the case statement then fails to match and misparses as PROCEED.
  # Instead collect into a variable and print once at the end.
  case "$(printf '%s' "$decision" | awk '
    toupper($0) ~ /^[[:space:]]*DECISION:[[:space:]]*REFINE/  {d="refine"}
    toupper($0) ~ /^[[:space:]]*DECISION:[[:space:]]*PROCEED/ {d="proceed"}
    END {print (d=="") ? "proceed" : d}
  ')" in
    refine)
      log "triage: issue #$issue REFINE — posting blockers, transitioning to needs-refinement"
      gh issue comment "$issue" --repo "$REPO_SLUG" --body "🟠 **Needs refinement before implementation.** The triage agent found gaps that would force an implementer to guess:

$decision

Please address the blockers above, then remove the \`needs-refinement\` label and re-add \`ready-for-implementation\`."
      # transition_label works on PR labels; for an issue use gh issue edit.
      gh issue edit "$issue" --repo "$REPO_SLUG" --remove-label "ready-for-implementation" 2>/dev/null || true
      gh issue edit "$issue" --repo "$REPO_SLUG" --add-label "needs-refinement"
      return 0
      ;;
    *)
      log "triage: issue #$issue PROCEED — chaining to implement"
      kind_implement "$issue"
      ;;
  esac
}

# ---------------------------------------------------------------- kind: implement

kind_implement() {
  local issue="$1"
  local branch="fix/$issue"
  local dir; dir="$(wt_dir "$branch")"

  git -C "$REPO_DIR" fetch origin --prune
  # fresh branch off main
  if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$REPO_DIR" branch -D "$branch"
  fi
  git -C "$REPO_DIR" worktree remove --force "$dir" 2>/dev/null || true
  git -C "$REPO_DIR" worktree add -B "$branch" "$dir" "$GIT_BRANCH_MAIN"
  ensure_pr_stage "$branch" >/dev/null

  run_pi implementation "$IMPLEMENT_MODEL" "$dir" \
    "Implement GitHub issue #$issue in $REPO_SLUG. Read $FACTORY_DIR/.agents/skills/implementation/SKILL.md and follow it exactly. The worktree you are in is on branch $branch; work here. Create a PR with 'Closes #$issue'."

  # the agent opened the PR; find it and transition into the review loop.
  local pr; pr="$(gh pr list --repo "$REPO_SLUG" --head "$branch" --state open --json number -q '.[0].number' 2>/dev/null || echo "")"
  [ -n "$pr" ] || die "implement finished but no open PR found on branch $branch; leaving issue labeled"
  mkdir -p "$(state_dir)"
  echo 0 > "$(round_file "$pr")"   # review will increment to 1 on first pass
  log "PR #$pr opened; transitioning issue -> review"
  gh issue edit "$issue" --repo "$REPO_SLUG" --remove-label "ready-for-implementation" 2>/dev/null || true
  gh pr edit "$pr" --repo "$REPO_SLUG" --add-label "ready-for-review"
}

# ----------------------------------------------------------------- kind: review
# One review pass, multi-perspective. Trivial PR (≤10 lines, no security-
# sensitive paths) -> single reviewer pass. Otherwise: fan out the four
# specialists in parallel, then a coordinator pass dedupes/filters/renumbers
# their outputs into one canonical FINDINGS block.
#
# 0 findings OR round==MAX -> needs-human-review; else save findings and label
# fixes-requested. The output contract (FINDINGS: block, ^F[0-9] counted) is
# unchanged from the single-reviewer design; only how findings are produced.
kind_review() {
  local pr="$1"
  local branch; branch="$(gh pr view "$pr" --repo "$REPO_SLUG" --json headRefName -q .headRefName)"
  local dir; dir="$(ensure_pr_stage "$branch")"
  mkdir -p "$(state_dir)"
  local rfile; rfile="$(round_file "$pr")"
  local round; round=$(( ( $(cat "$rfile" 2>/dev/null || echo 0) ) + 1 ))
  echo "$round" > "$rfile"

  log "review round $round/$MAX_ROUNDS on PR #$pr ($branch)"

  # --- fetch diff ONCE; build a per-run workdir for inlined inputs/outputs ---
  local workdir; workdir="$(mktemp -d)"
  local diff_file="$workdir/diff"
  gh pr diff "$pr" --repo "$REPO_SLUG" > "$diff_file" 2>/dev/null || cp /dev/null "$diff_file"
  local tier; tier="$(classify_tier "$diff_file")"
  log "risk tier: $tier"

  local findings perspectives
  if [ "$tier" = "trivial" ]; then
    findings="$(run_review_agent review "$REVIEW_MODEL" "$dir" \
      "@$(review_shared_file)" "@$(review_skill_file review)" "@$diff_file" \
      "You are reviewing PR #$pr in $REPO_SLUG (branch $branch). Follow the instructions inlined above. Output ONLY the findings block. This is review round $round of at most $MAX_ROUNDS.")"
    perspectives="single pass"
  else
    findings="$(run_multi_perspective "$workdir" "$diff_file" "$pr" "$branch" "$round" "$dir")"
    perspectives="security · quality · performance · docs → coordinator"
  fi

  # best-effort cleanup of the per-run workdir
  rm -rf "$workdir" 2>/dev/null || true

  local count; count="$(printf '%s' "$findings" | grep -c '^F[0-9]' || true)"
  log "round $round: $count finding(s)"

  if [ "$count" -eq 0 ]; then
    gh pr comment "$pr" --repo "$REPO_SLUG" --body "✅ **Approved** — review found no blocking issues (round $round of $MAX_ROUNDS, $perspectives). Ready for human review."
    transition_label "$pr" "ready-for-review" "needs-human-review"
    return 0
  fi

  # findings remain — save them for the fix pass
  printf '%s\n' "$findings" > "$(findings_file "$pr")"

  if [ "$round" -ge "$MAX_ROUNDS" ]; then
    gh pr comment "$pr" --repo "$REPO_SLUG" --body "⚠️ **Did not converge** after $MAX_ROUNDS review rounds ($count finding(s) still open, $perspectives). Needs human input. Latest findings:

$findings"
    transition_label "$pr" "ready-for-review" "needs-human-review"
    return 0
  fi

  gh pr comment "$pr" --repo "$REPO_SLUG" --body "🔍 Review round $round: $count finding(s) ($perspectives). Requesting fixes.

$findings"
  transition_label "$pr" "ready-for-review" "fixes-requested"
}

# Classify a PR's risk tier from its diff: trivial | full. Two tiers only.
#   trivial = ≤10 changed lines AND ≤5 files AND no security-sensitive paths
#   full    = everything else (the fan-out + coordinator path)
# Security-sensitive paths always force full review regardless of size.
TRIVIAL_MAX_LINES=10
TRIVIAL_MAX_FILES=5
SECURITY_PATHS_RE='(auth/|crypto/|certificate|secret|credential|password|jwt|token|session|rbac|permission)'
classify_tier() {
  local diff_file="$1"
  # count changed files (diff --git headers). `grep -c` prints 0 on no-match,
  # so `|| true` (NOT `|| echo 0`) avoids appending a second 0 that breaks `[ -le ]`.
  local files; files="$(grep -c '^diff --git' "$diff_file" 2>/dev/null || true)"
  # count added+removed lines (start with + or -, but not +++/--- headers)
  local lines; lines="$(grep -E '^[+-]' "$diff_file" 2>/dev/null | grep -cvE '^(\+\+\+|---)' || true)"
  if grep -Eiq "$SECURITY_PATHS_RE" "$diff_file"; then echo full; return; fi
  if [ "$lines" -le "$TRIVIAL_MAX_LINES" ] && [ "$files" -le "$TRIVIAL_MAX_FILES" ]; then
    echo trivial
  else
    echo full
  fi
}

# Fan out the four specialists in parallel, then run the coordinator over
# their outputs. All inputs inlined via @file; every agent runs --no-tools.
# A specialist that errors/times out contributes an empty file and is simply
# absent from the coordinator's inputs — the review proceeds on the rest.
# Args: $1=workdir $2=diff_file $3=pr $4=branch $5=round $6=cwd
run_multi_perspective() {
  local workdir="$1" diff_file="$2" pr="$3" branch="$4" round="$5" cwd="$6"
  local shared; shared="$(review_shared_file)"
  local spec_prompt="You are a specialist reviewer on PR #$pr in $REPO_SLUG (branch $branch), review round $round of at most $MAX_ROUNDS. Follow the instructions inlined above. Output ONLY your findings block."
  local sec="$workdir/out.security" qual="$workdir/out.quality" perf="$workdir/out.performance" docs="$workdir/out.docs"

  log "fanning out specialists: security quality performance docs"
  # Each in a subshell so a failure (set -e) cannot abort the parent. Outputs to
  # files; an empty file = that specialist contributed nothing.
  ( run_review_agent review-security  "$REVIEW_SECURITY_MODEL"    "$cwd" \
      "@$shared" "@$(review_skill_file review-security)"  "@$diff_file" "$spec_prompt" > "$sec"  2>/dev/null ) &
  ( run_review_agent review-quality   "$REVIEW_QUALITY_MODEL"     "$cwd" \
      "@$shared" "@$(review_skill_file review-quality)"   "@$diff_file" "$spec_prompt" > "$qual" 2>/dev/null ) &
  ( run_review_agent review-performance "$REVIEW_PERFORMANCE_MODEL" "$cwd" \
      "@$shared" "@$(review_skill_file review-performance)" "@$diff_file" "$spec_prompt" > "$perf" 2>/dev/null ) &
  ( run_review_agent review-docs      "$REVIEW_DOCS_MODEL"        "$cwd" \
      "@$shared" "@$(review_skill_file review-docs)"      "@$diff_file" "$spec_prompt" > "$docs" 2>/dev/null ) &
  wait

  local ran=""
  [ -s "$sec"  ] && ran+="security "
  [ -s "$qual" ] && ran+="quality "
  [ -s "$perf" ] && ran+="performance "
  [ -s "$docs" ] && ran+="docs"
  log "specialists produced output: ${ran:-none}"

  # Coordinator: shared rules + its skill + the diff + each specialist output.
  # Note: no quotes around ${x:+@$x} — pi needs the @file as a bare arg; quoting
  # embeds the quote chars and breaks @file parsing (EISDIR / treat-as-prompt).
  run_review_agent review-coordinator "$REVIEW_MODEL" "$cwd" \
    "@$shared" "@$(review_skill_file review-coordinator)" "@$diff_file" \
    ${sec:+@$sec} ${qual:+@$qual} ${perf:+@$perf} ${docs:+@$docs} \
    "You are the review coordinator for PR #$pr in $REPO_SLUG (branch $branch), round $round of at most $MAX_ROUNDS. The inlined sections above are: shared rules, your coordinator instructions, the diff, then each specialist's findings. Deduplicate, filter, renumber, and emit exactly one canonical findings block."
}

# -------------------------------------------------------------------- kind: fix
# One fix pass driven by the findings saved by the last review. Re-labels
# ready-for-review, which fires the next review.
kind_fix() {
  local pr="$1"
  local branch; branch="$(gh pr view "$pr" --repo "$REPO_SLUG" --json headRefName -q .headRefName)"
  local dir; dir="$(ensure_pr_stage "$branch")"
  local ffile; ffile="$(findings_file "$pr")"
  local findings; findings="$(cat "$ffile" 2>/dev/null)"
  [ -n "$findings" ] || die "no saved findings for PR #$pr ($ffile); cannot fix"

  log "fix pass on PR #$pr ($branch)"
  run_pi implementation "$FIX_MODEL" "$dir" \
    "Address the following review findings on PR #$pr (branch $branch). Read $FACTORY_DIR/.agents/skills/implementation/SKILL.md and follow it exactly — this is a FIX PASS: do NOT open a new PR, commit and push to $branch. Validate each finding: fix it, or if you genuinely disagree post a comment on the PR explaining why and leave it unchanged. Findings:

$findings" >/dev/null

  transition_label "$pr" "fixes-requested" "ready-for-review"
}

# --------------------------------------------------------------- kind: teardown
# PR closed (merged or not). Tear down the worktree + DB + branch, sync main,
# wipe this PR's state.
kind_teardown() {
  local pr="$1"
  local branch; branch="$(gh pr view "$pr" --repo "$REPO_SLUG" --json headRefName -q .headRefName 2>/dev/null || echo "")"
  if [ -n "$branch" ]; then
    local dir; dir="$(wt_dir "$branch")"
    if [ -d "$dir" ]; then
      git -C "$REPO_DIR" worktree remove --force "$dir" && log "removed worktree $dir"
    fi
    local db; db="$(db_for "$dir")"
    dropdb --if-exists "$db" 2>/dev/null && log "dropped db $db"
    git -C "$REPO_DIR" branch -D "$branch" 2>/dev/null || true
  fi
  rm -f "$(round_file "$pr")" "$(findings_file "$pr")" 2>/dev/null || true

  # sync the main checkout so the next implement branches from up-to-date main
  log "syncing $REPO_DIR -> $GIT_BRANCH_MAIN"
  git -C "$REPO_DIR" checkout "$GIT_BRANCH_MAIN" 2>/dev/null || true
  git -C "$REPO_DIR" pull --ff-only 2>/dev/null && log "pulled latest $GIT_BRANCH_MAIN" || true
}

# ------------------------------------------------------------------------ main

cmd="${1:-}"; shift || true
case "$cmd" in
  triage)      kind_triage "$@" ;;
  implement)   kind_implement "$@" ;;
  review)      kind_review "$@" ;;
  fix)         kind_fix "$@" ;;
  teardown)    kind_teardown "$@" ;;
  *) die "unknown subcommand: $cmd (expected: triage|implement|review|fix|teardown)" ;;
esac
