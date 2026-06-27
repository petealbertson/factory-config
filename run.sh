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
json_escape() { printf '%s' "$1" | python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read())[1:-1])'; }

# Control-plane helpers. Legacy label-driven runs have no FACTORY_RUN_ID.
factory_in_dispatch() { [ -n "${FACTORY_RUN_ID:-}" ]; }
factory_is_pipeline() { ! factory_in_dispatch || [ "${FACTORY_MODE:-pipeline}" = "pipeline" ]; }
factory_is_point() { factory_in_dispatch && [ "${FACTORY_MODE:-}" = "point" ]; }

# Stable fingerprint for comparing finding blocks across rounds.
factory_findings_fingerprint() {
  printf '%s' "$1" | python3 -c 'import hashlib,sys,re; t=re.sub(r"\s+", " ", sys.stdin.read().lower()); sys.stdout.write(hashlib.md5(t.encode()).hexdigest())'
}

# --------------------------------------------------------------------- control-plane
# Callbacks are optional; when FACTORY_APP_URL + FACTORY_RUN_ID are unset the
# runner keeps working in legacy label-driven mode. The callback token is only
# needed when posting back to the control plane.
factory_callback_base_url() {
  if [ -n "${FACTORY_APP_URL:-}" ] && [ -n "${FACTORY_RUN_ID:-}" ] && [[ "$FACTORY_RUN_ID" =~ ^[0-9]+$ ]]; then
    printf '%s/internal/runs/%s' "${FACTORY_APP_URL%/}" "$FACTORY_RUN_ID"
  fi
}
factory_auth_header() {
  if [ -n "${FACTORY_CALLBACK_TOKEN:-}" ]; then
    printf 'Authorization: Bearer %s' "$FACTORY_CALLBACK_TOKEN"
  fi
}
factory_emit_dashboard_link() {
  if [ -z "${FACTORY_APP_URL:-}" ] || [ -z "${FACTORY_RUN_ID:-}" ]; then
    return 0
  fi
  local url; url="${FACTORY_APP_URL%/}/runs/${FACTORY_RUN_ID}"
  log "dashboard: $url"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::notice title=Factory run::$url"
  fi
}
factory_post() {
  local path="$1" payload="$2"
  local base; base="$(factory_callback_base_url)"
  local auth; auth="$(factory_auth_header)"
  [ -n "$base" ] || return 0
  [ -n "$auth" ] || return 0
  local url="$base/$path"
  curl -fsS -X POST -H "$auth" -H "Content-Type: application/json" -d "$payload" "$url" >/dev/null 2>&1 || true
}
factory_heartbeat() {
  local step="${1:-}"
  local payload; payload='{}'
  [ -n "$step" ] && payload="{\"current_step\":\"$(json_escape "$step")\"}"
  factory_post "heartbeat" "$payload"
}
factory_event() {
  local event_type="$1"; shift || true
  local message="${1:-}"; shift || true
  local external_url="${1:-}"
  local url_field=""
  [ -n "$external_url" ] && url_field=",\"external_url\":\"$(json_escape "$external_url")\""
  local payload; payload="{\"event_type\":\"$(json_escape "$event_type")\",\"message\":\"$(json_escape "$message")\"$url_field}"
  factory_post "events" "$payload"
}
factory_complete() {
  local state="$1"
  shift || true
  local message="${1:-}"
  shift || true
  local metadata="${1:-}"
  local meta_field=""
  [ -n "$metadata" ] && meta_field=",\"metadata\":$metadata"
  local payload
  payload="{\"state\":\"$state\",\"message\":\"$(json_escape "$message")\"$meta_field}"
  factory_post "complete" "$payload"
}
factory_fail() { factory_complete "failed" "$1"; }

# Exchange the single-use dispatch token for the run's callback token.
# No-op when no dispatch context is present. Callbacks remain disabled if the
# exchange fails (e.g., the control plane is unreachable), so the runner keeps
# working in legacy local mode.
factory_authorize_runner() {
  local base; base="$(factory_callback_base_url)"
  [ -n "$base" ] || return 0
  [ -n "${FACTORY_DISPATCH_TOKEN:-}" ] || return 0

  local url="$base/authorize_runner"
  local kind="${FACTORY_KIND:-}"
  local payload; payload="{\"dispatch_token\":\"$(json_escape "$FACTORY_DISPATCH_TOKEN")\",\"kind\":\"$(json_escape "$kind")\"}"
  local resp
  if ! resp="$(curl -fsS -X POST -H "Content-Type: application/json" -d "$payload" "$url" 2>/dev/null)"; then
    log "warning: could not exchange dispatch token; callbacks disabled"
    return 0
  fi

  local callback_token app_token reviewer_token
  callback_token="$(printf '%s' "$resp" | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin).get("callback_token",""))')"
  app_token="$(printf '%s' "$resp" | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin).get("app_token",""))')"
  reviewer_token="$(printf '%s' "$resp" | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin).get("reviewer_token",""))')"

  if [ -n "$callback_token" ]; then
    echo "::add-mask::$callback_token"
    export FACTORY_CALLBACK_TOKEN="$callback_token"
  else
    log "warning: control plane did not return a callback token"
  fi
  if [ -n "$app_token" ]; then
    echo "::add-mask::$app_token"
    export FACTORY_APP_TOKEN="$app_token"
  fi
  if [ -n "$reviewer_token" ]; then
    echo "::add-mask::$reviewer_token"
    export FACTORY_REVIEWER_TOKEN="$reviewer_token"
  fi
}

# Configure git user identity for brokered commits under the dispatch path.
factory_configure_git_identity() {
  if [ -n "${FACTORY_GIT_AUTHOR_NAME:-}" ]; then
    git -C "$REPO_DIR" config --local user.name "$FACTORY_GIT_AUTHOR_NAME"
  fi
  if [ -n "${FACTORY_GIT_AUTHOR_EMAIL:-}" ]; then
    git -C "$REPO_DIR" config --local user.email "$FACTORY_GIT_AUTHOR_EMAIL"
  fi
}

# Selects the appropriate brokered GitHub App token for the current kind and
# rewrites the origin remote to use it. Falls back to the VM's ambient gh
# auth when the control plane did not broker tokens.
factory_configure_github_token() {
  local kind="${1:-}"
  local token=""

  case "$kind" in
    review)
      # Use the reviewer token only; falling back to the implementer token
      # would let a review pass silently hold contents:write.
      token="${FACTORY_REVIEWER_TOKEN:-}" ;;
    *)
      token="${FACTORY_APP_TOKEN:-}" ;;
  esac

  [ -n "$token" ] || return 0

  export GH_TOKEN="$token"
  # Rewrite the main repo origin so git push/pull use the brokered token.
  git -C "$REPO_DIR" remote set-url origin "https://x-access-token:${token}@github.com/${REPO_SLUG}.git" 2>/dev/null || true
}

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
  # Tolerate a missing target label (e.g. factory-blocked on legacy repos) so
  # the runner does not strand a PR with no state label.
  gh pr edit "$pr" --repo "$REPO_SLUG" --add-label "$new" 2>/dev/null || true
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
  factory_emit_dashboard_link
  factory_heartbeat "triage"
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
      factory_event "triage_refined" "refinements requested"
      gh issue comment "$issue" --repo "$REPO_SLUG" --body "🟠 **Needs refinement before implementation.** The triage agent found gaps that would force an implementer to guess:

$decision

Please address the blockers above, then remove the \`needs-refinement\` label and re-add \`ready-for-implementation\`."
      # transition_label works on PR labels; for an issue use gh issue edit.
      gh issue edit "$issue" --repo "$REPO_SLUG" --remove-label "ready-for-implementation" 2>/dev/null || true
      gh issue edit "$issue" --repo "$REPO_SLUG" --add-label "needs-refinement"
      factory_complete "needs_refinement" "needs refinement"
      return 0
      ;;
    *)
      log "triage: issue #$issue PROCEED — chaining to implement"
      factory_event "triage_started" "proceeding to implement"
      kind_implement "$issue"
      ;;
  esac
}

# ---------------------------------------------------------------- kind: implement

kind_implement() {
  local issue="$1"
  factory_heartbeat "implement"
  factory_event "implementation_started" "issue #$issue"
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
  local pr_url; pr_url="$(gh pr view "$pr" --repo "$REPO_SLUG" --json url -q .url 2>/dev/null || echo "")"
  factory_event "implementation_pr_created" "PR #$pr" "${pr_url}"
  mkdir -p "$(state_dir)"
  echo 0 > "$(round_file "$pr")"   # review will increment to 1 on first pass
  log "PR #$pr opened; transitioning issue -> review"
  gh issue edit "$issue" --repo "$REPO_SLUG" --remove-label "ready-for-implementation" 2>/dev/null || true
  gh pr edit "$pr" --repo "$REPO_SLUG" --add-label "ready-for-review"

  if factory_in_dispatch && factory_is_pipeline; then
    gh pr edit "$pr" --repo "$REPO_SLUG" --add-label "factory-managed" 2>/dev/null || true
    factory_complete "needs_review" "PR #$pr opened; scheduling review"
  elif factory_in_dispatch && factory_is_point; then
    factory_complete "succeeded" "PR #$pr opened (point mode)"
  fi
}

# ----------------------------------------------------------------- kind: review
# One review pass, multi-perspective. Trivial PR (≤10 lines, no security-
# sensitive paths) -> single reviewer pass. Otherwise: fan out the four
# specialists in parallel, then a coordinator pass dedupes/filters/renumbers
# their outputs into one canonical FINDINGS block.
#
# Pipeline: 0 findings OR repeated/max rounds -> terminal, else schedule fix.
# Point mode: one review only, no loop. The output contract (FINDINGS: block,
# ^F[0-9] counted) is unchanged from the single-reviewer design.
kind_review() {
  local pr="$1"
  factory_heartbeat "review"
  factory_event "review_started" "PR #$pr"
  local branch; branch="$(gh pr view "$pr" --repo "$REPO_SLUG" --json headRefName -q .headRefName)"
  local dir; dir="$(ensure_pr_stage "$branch")"
  mkdir -p "$(state_dir)"

  # Ensure pipeline/take_over PRs carry the factory-managed label.
  if factory_is_pipeline; then
    gh pr edit "$pr" --repo "$REPO_SLUG" --add-label "factory-managed" 2>/dev/null || true
  fi

  # Determine round + mode. Legacy runs count from the local state file;
  # dispatched runs receive the current round from the control plane.
  local rfile; rfile="$(round_file "$pr")"
  local round max_rounds
  if factory_in_dispatch; then
    round="${FACTORY_ROUND:-1}"
    max_rounds="${FACTORY_MAX_ROUNDS:-3}"
  else
    round=$(( ( $(cat "$rfile" 2>/dev/null || echo 0) ) + 1 ))
    echo "$round" > "$rfile"
    max_rounds="$MAX_ROUNDS"
  fi

  log "review round $round/$max_rounds on PR #$pr ($branch)"

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
      "You are reviewing PR #$pr in $REPO_SLUG (branch $branch). Follow the instructions inlined above. Output ONLY the findings block. This is review round $round of at most $max_rounds.")"
    perspectives="single pass"
  else
    findings="$(run_multi_perspective "$workdir" "$diff_file" "$pr" "$branch" "$round" "$dir")"
    perspectives="security · quality · performance · docs → coordinator"
  fi

  local count; count="$(printf '%s' "$findings" | grep -c '^F[0-9]' || true)"
  log "round $round: $count finding(s)"
  factory_event "review_findings_posted" "round $round: $count finding(s)"

  local fingerprint; fingerprint="$(factory_findings_fingerprint "$findings")"
  local review_body_file="$workdir/review_body"

  # Point mode = one review only, no loop.
  if factory_is_point; then
    if [ "$count" -eq 0 ]; then
      printf '%s\n' "✅ **Approved** — review found no blocking issues (round $round, $perspectives)." > "$review_body_file"
      gh pr review "$pr" --repo "$REPO_SLUG" --approve --body-file "$review_body_file"
      factory_complete "succeeded" "point review: no findings"
    else
      printf '%s\n' "🔍 Review findings ($count, $perspectives). Requesting changes.\n\n$findings" > "$review_body_file"
      gh pr review "$pr" --repo "$REPO_SLUG" --request-changes --body-file "$review_body_file"
      factory_complete "succeeded" "point review: $count finding(s)"
    fi
    rm -rf "$workdir" 2>/dev/null || true
    return 0
  fi

  # Pipeline / legacy mode.
  if [ "$count" -eq 0 ]; then
    printf '%s\n' "✅ **Approved** — review found no blocking issues (round $round of $max_rounds, $perspectives). Ready for human review." > "$review_body_file"
    gh pr review "$pr" --repo "$REPO_SLUG" --approve --body-file "$review_body_file"
    transition_label "$pr" "ready-for-review" "needs-human-review"
    factory_complete "needs_human_review" "review passed; needs human review"
    rm -rf "$workdir" 2>/dev/null || true
    return 0
  fi

  # Save findings for the fix pass and look for repeated finding deadlock.
  local ffile; ffile="$(findings_file "$pr")"
  local prev_fingerprint=""
  [ -f "$ffile" ] && prev_fingerprint="$(factory_findings_fingerprint "$(cat "$ffile")")"
  printf '%s\n' "$findings" > "$ffile"

  if [ -n "$prev_fingerprint" ] && [ "$fingerprint" = "$prev_fingerprint" ]; then
    printf '%s\n' "⚠️ **Repeated findings** after a fix pass (round $round of $max_rounds, $perspectives). The same issues survived unchanged; escalating to human input. Latest findings:\n\n$findings" > "$review_body_file"
    gh pr review "$pr" --repo "$REPO_SLUG" --request-changes --body-file "$review_body_file"
    transition_label "$pr" "ready-for-review" "factory-blocked"
    factory_complete "factory_blocked" "repeated findings after fix"
    rm -rf "$workdir" 2>/dev/null || true
    return 0
  fi

  if [ "$round" -ge "$max_rounds" ]; then
    printf '%s\n' "⚠️ **Did not converge** after $max_rounds review rounds ($count finding(s) still open, $perspectives). Needs human input. Latest findings:\n\n$findings" > "$review_body_file"
    gh pr review "$pr" --repo "$REPO_SLUG" --request-changes --body-file "$review_body_file"
    transition_label "$pr" "ready-for-review" "needs-human-review"
    factory_complete "needs_human_review" "needs human review after max rounds"
    rm -rf "$workdir" 2>/dev/null || true
    return 0
  fi

  printf '%s\n' "🔍 Review round $round: $count finding(s) ($perspectives). Requesting fixes.\n\n$findings" > "$review_body_file"
  gh pr review "$pr" --repo "$REPO_SLUG" --request-changes --body-file "$review_body_file"
  transition_label "$pr" "ready-for-review" "fixes-requested"
  factory_complete "needs_fix" "review found $count issue(s)" "{\"findings_fingerprint\":\"$fingerprint\",\"round\":$round}"
  rm -rf "$workdir" 2>/dev/null || true
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
# One fix pass driven by the findings saved by the last review. In pipeline
# mode the control plane schedules the next review; in point mode this is one
# bounded fix and stop.
kind_fix() {
  local pr="$1"
  factory_heartbeat "fix"
  factory_event "fix_started" "PR #$pr"
  local branch; branch="$(gh pr view "$pr" --repo "$REPO_SLUG" --json headRefName -q .headRefName)"
  local dir; dir="$(ensure_pr_stage "$branch")"
  local ffile; ffile="$(findings_file "$pr")"
  local findings; findings="$(cat "$ffile" 2>/dev/null)"
  [ -n "$findings" ] || die "no saved findings for PR #$pr ($ffile); cannot fix"

  log "fix pass on PR #$pr ($branch)"
  run_pi implementation "$FIX_MODEL" "$dir" \
    "Address the following review findings on PR #$pr (branch $branch). Read $FACTORY_DIR/.agents/skills/implementation/SKILL.md and follow it exactly — this is a FIX PASS: do NOT open a new PR, commit and push to $branch. Validate each finding: fix it, or if you genuinely disagree post a comment on the PR explaining why and leave it unchanged. Findings:

$findings" >/dev/null

  factory_event "fix_pushed" "PR #$pr"

  if factory_is_point; then
    factory_complete "succeeded" "point fix complete"
    return 0
  fi

  transition_label "$pr" "fixes-requested" "ready-for-review"
  factory_complete "needs_review" "fix pushed; scheduling re-review"
}

# --------------------------------------------------------------- kind: teardown
# PR closed (merged or not). Tear down the worktree + DB + branch, sync main,
# wipe this PR's state.
kind_teardown() {
  local pr="$1"
  factory_heartbeat "teardown"
  factory_event "teardown_started" "PR #$pr"
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
  factory_event "teardown_completed" "PR #$pr"
  factory_complete "succeeded" "teardown complete"
}

# ------------------------------------------------------------------------ main

# Run when the control plane dispatches the job. Exchanges the dispatch token,
# then dispatches to the requested kind. Falls back to the legacy label-driven
# command path when no FACTORY_RUN_ID is present.
factory_dispatch_main() {
  factory_authorize_runner
  factory_configure_git_identity
  factory_configure_github_token "${FACTORY_KIND:-}"
  factory_emit_dashboard_link
  factory_heartbeat "starting"

  case "${FACTORY_KIND:-}" in
    triage|triage-ready-issues)
      kind_triage "${FACTORY_TARGET:-}"
      ;;
    implement|implementation)
      kind_implement "${FACTORY_TARGET:-}"
      ;;
    review)
      kind_review "${FACTORY_TARGET:-}"
      ;;
    fix)
      kind_fix "${FACTORY_TARGET:-}"
      ;;
    teardown)
      kind_teardown "${FACTORY_TARGET:-}"
      ;;
    status|stop)
      log "control-plane dispatch for kind '$FACTORY_KIND' not yet implemented; finishing"
      factory_complete "factory_stopped" "kind $FACTORY_KIND: not dispatched"
      ;;
    '')
      die "FACTORY_KIND is required when dispatch context is set" ;;
    *)
      die "unknown FACTORY_KIND: $FACTORY_KIND" ;;
  esac
}

# Legacy label-driven entrypoint, kept until repositories are migrated to the
# single dispatch workflow.
factory_legacy_main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    triage)      kind_triage "$@" ;;
    implement)   kind_implement "$@" ;;
    review)      kind_review "$@" ;;
    fix)         kind_fix "$@" ;;
    teardown)    kind_teardown "$@" ;;
    *) die "unknown subcommand: $cmd (expected: triage|implement|review|fix|teardown)" ;;
  esac
}

if [ -n "${FACTORY_RUN_ID:-}" ] || [ -n "${FACTORY_KIND:-}" ]; then
  factory_dispatch_main
else
  # first positional argument is the legacy subcommand
  factory_legacy_main "$@"
fi
