#!/usr/bin/env bash
# Cloud factory runner. Invoked on a per-repo VM by a self-hosted GitHub
# Actions runner that runs on this same VM:
#   bash ~/factory/run.sh <kind> [args]
#
# One VM == one repo (the "repo VM"). This script is repo-agnostic; the repo it
# targets is declared in repo.env. It is Rails-aware (db:prepare, bin/rails s).
#
# Subcommands:
#   implement <issue>          create PR stage, run implementation skill, push, open PR
#   review-and-fix <pr>         run review -> fix loop (max 2 rounds) on the PR's branch
#   human-review <pr>           start the app server on a proxied port for smoke testing
#   stop-server <pr>            stop the smoke-test server, keep the PR stage
#   teardown <pr>               stop server, remove worktree, drop DB (on PR close)
#
# PR stage == worktree + DB clone for one PR branch. Persists across implement /
# review / human-review until teardown.

set -euo pipefail

FACTORY_DIR="${FACTORY_DIR:-$HOME/factory}"

# --- activate mise so ruby/bundle/rails resolve in any shell (runner job, ssh, cron) ---
# The self-hosted runner job shell does NOT inherit the interactive login PATH,
# so mise's shims are absent and `bundle` is unresolvable. mise activate is a
# no-op if mise is missing or already on PATH.
if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate bash)"
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
port_for_pr() { printf '%d\n' $((8000 + ($1 % 2000))); }

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
  pi --model "$model" --cwd "$cwd" -p "$prompt"
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
}

# ------------------------------------------------------------ kind: review-and-fix

kind_review_and_fix() {
  local pr="$1"
  local branch; branch="$(gh pr view "$pr" --repo "$REPO_SLUG" --json headRefName -q .headRefName)"
  local dir; dir="$(ensure_pr_stage "$branch")"
  local prev_findings=""
  local round findings count

  for round in 1 2; do
    log "review round $round on PR #$pr ($branch)"
    findings="$(run_pi review "$REVIEW_MODEL" "$dir" \
      "Review PR #$pr in $REPO_SLUG (branch $branch). Read $FACTORY_DIR/.agents/skills/review/SKILL.md and follow it exactly. Output ONLY the findings block as specified by the skill. Prior review context (if any): ${prev_findings:-none}.")"
    count="$(printf '%s' "$findings" | grep -c '^F[0-9]' || true)"
    log "round $round: $count finding(s)"
    if [ "$count" -eq 0 ]; then
      gh pr comment "$pr" --repo "$REPO_SLUG" --body "✅ Review converged after $round round(s), 0 findings remaining. Ready for human review (label: \`human-review\`)."
      return 0
    fi
    # diminishing-findings guard: if round 2 has >= round 1's count, escalate
    if [ "$round" -eq 2 ]; then
      gh pr comment "$pr" --repo "$REPO_SLUG" --body "⚠️ Did not converge after 2 rounds ($count finding(s) still open). Needs human input. Latest findings:

\
\
\
\
$(printf '%s' "$findings")"
      return 1
    fi
    prev_findings="$findings"
    log "fix round $round on PR #$pr"
    run_pi implementation "$FIX_MODEL" "$dir" \
      "Address the following review findings on PR #$pr (branch $branch). Read $FACTORY_DIR/.agents/skills/implementation/SKILL.md; this is a fix pass, so do NOT open a new PR — commit and push to $branch. Findings:

$(printf '%s' "$findings")" >/dev/null
  done
}

# ------------------------------------------------------------- kind: human-review

kind_human_review() {
  local pr="$1"
  local branch; branch="$(gh pr view "$pr" --repo "$REPO_SLUG" --json headRefName -q .headRefName)"
  local dir; dir="$(ensure_pr_stage "$branch")"
  local port; port="$(port_for_pr "$pr")"
  local servers="$FACTORY_DIR/servers"; mkdir -p "$servers"
  local pidfile="$servers/pr$pr.pid"

  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    log "server already running on port $port (pid $(cat "$pidfile"))"
  else
    log "preparing DB and starting server on port $port"
    ( cd "$dir" \
      && RAILS_ENV=development DATABASE_NAME="$(db_for "$dir")" bundle exec rails db:migrate \
      && RAILS_ENV=development DATABASE_NAME="$(db_for "$dir")" bundle exec rails db:seed )
    nohup bash -c "cd '$dir' && RAILS_ENV=development DATABASE_NAME='$(db_for "$dir")' bin/rails server -p $port -b 0.0.0.0" \
      >"$servers/pr$pr.log" 2>&1 &
    echo $! > "$pidfile"
    # healthcheck
    for _ in $(seq 1 30); do
      curl -sf "http://127.0.0.1:$port" >/dev/null 2>&1 && break
      sleep 2
    done
  fi
  gh pr comment "$pr" --repo "$REPO_SLUG" --body "👀 Human review ready: app running on branch $branch at https://$(hostname).exe.xyz:$port

Stop it with: label \`stop-server\` or merge/close the PR."
}

# ----------------------------------------------------------- kind: stop-server

kind_stop_server() {
  local pr="$1"
  local pidfile="$FACTORY_DIR/servers/pr$pr.pid"
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    kill "$(cat "$pidfile")" && log "stopped server for PR #$pr"
  fi
  rm -f "$pidfile"
}

# -------------------------------------------------------------- kind: teardown

kind_teardown() {
  local pr="$1"
  kind_stop_server "$pr" 2>/dev/null || true
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
  rm -f "$FACTORY_DIR/servers/pr$pr.pid" "$FACTORY_DIR/servers/pr$pr.log"
}

# ------------------------------------------------------------------------ main

cmd="${1:-}"; shift || true
case "$cmd" in
  implement)        kind_implement "$@" ;;
  review-and-fix)   kind_review_and_fix "$@" ;;
  human-review)     kind_human_review "$@" ;;
  stop-server)      kind_stop_server "$@" ;;
  teardown)         kind_teardown "$@" ;;
  *) die "unknown subcommand: $cmd" ;;
esac
