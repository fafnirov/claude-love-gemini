#!/usr/bin/env bash
# Delegate a task to Gemini CLI with isolation, logging and a quality gate.
#
# Claude Code orchestrates, Gemini executes. The main working copy is never
# touched: every task gets its own task_id, branch and git worktree.
#
#   gemini-task.sh run    [options] "task"
#   gemini-task.sh review <task_id> [--acceptance "..."] [--focus "..."]
#   gemini-task.sh review --repo DIR --diff FILE [--acceptance "..."]
#   gemini-task.sh merge  <task_id> [--into <branch>] [--test "CMD"] [--ack]
#   gemini-task.sh clean  <task_id> [--force]
#   gemini-task.sh list | show <task_id> | stats | recover | gc | doctor
#
# run options:
#   --repo DIR          repository (default: current directory)
#   --base REF          branch point (default: HEAD)
#   --test "CMD"        verification command, executed inside the worktree
#   --no-require-tests  do not block merging when tests did not run
#   --scope "a/*,b/*"   allowed diff boundaries (comma separated)
#   --task-file FILE    task contract in JSON (see docs)
#   --slug NAME         task name used for counters (default: from the text)
#   --max-attempts N    attempt limit per slug (default 3)
#   --budget-seconds N  total time budget per slug (default 3600)
#   --max-parallel N    concurrent executors (default 2)
#   --allow-dup         allow re-running an identical task
#   --model NAME        Gemini model (else GEMINI_MODEL, else the Gemini config)
#   --no-commit         do not commit the result to the task branch
#   --timeout SEC       time limit for one Gemini run (default 1800)
set -euo pipefail

export PYTHONIOENCODING=utf-8
ROOT="${GEMINI_TASKS_DIR:-$HOME/.claude/gemini-tasks}"
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPTS/gemini-run.sh"
REPORTER="$SCRIPTS/task_report.py"
HELPER="$SCRIPTS/task_meta.py"
GEMINI_CONFIG="${GEMINI_HOME:-$HOME/.gemini}/settings.json"
# empty on purpose: without an explicit choice Gemini uses its own config
DEFAULT_MODEL="${GEMINI_DEFAULT_MODEL:-}"

SLOT=""
ACTIVE_FILE=""
CHILD_PID=""
# python3 on most systems, python on Windows/Git Bash
PY="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo python)"

die() { echo "gemini-task: $*" >&2; exit 2; }

release_resources() {
  [ -n "$CHILD_PID" ] && kill -TERM "$CHILD_PID" 2>/dev/null || true
  [ -n "$SLOT" ] && rm -rf "$SLOT" 2>/dev/null || true
  [ -n "$ACTIVE_FILE" ] && rm -f "$ACTIVE_FILE" 2>/dev/null || true
}

on_signal() { release_resources; exit 130; }

# Recursion guard: Gemini must not start another delegated task.
if [ -n "${GEMINI_TASK_ACTIVE:-}" ]; then
  die "recursive invocation is forbidden (GEMINI_TASK_ACTIVE=$GEMINI_TASK_ACTIVE)"
fi

# Reject every way of bypassing the sandbox.
check_flags() {
  for a in "$@"; do
    case "$a" in
      -y|--yolo|--approval-mode=yolo)
        die "flag $a is forbidden — it auto-approves every tool call" ;;
      --dangerously-bypass-approvals-and-sandbox|--dangerously-bypass-hook-trust)
        die "flag $a is forbidden" ;;
    esac
  done
}

jget() { "$PY" "$HELPER" get "$1" "$2"; }

# model: --model > GEMINI_MODEL > Gemini config > built-in default
resolve_model() {
  local want="${1:-}"
  [ -z "$want" ] && want="${GEMINI_MODEL:-}"
  if [ -z "$want" ] && [ -f "$GEMINI_CONFIG" ]; then
    want="$("$PY" "$HELPER" settings-model "$GEMINI_CONFIG")"
  fi
  [ -n "$want" ] || want="$DEFAULT_MODEL"
  echo "$want"   # may be empty: then Gemini picks the model itself
}

# Availability per the Gemini model cache; the cache can be stale, so this is a
# warning only.
# the Gemini CLI ships no local model catalogue, so availability cannot be
# checked offline; the engine reports an unusable model at run time instead
model_known() { echo "unknown"; }

acquire_slot() {
  local limit="$1" i
  mkdir -p "$ROOT/locks"
  for d in "$ROOT"/locks/slot-*; do
    [ -d "$d" ] || continue
    local pid
    pid="$(cat "$d/pid" 2>/dev/null || echo "")"
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "$d"; fi
  done
  for i in $(seq 1 "$limit"); do
    if mkdir "$ROOT/locks/slot-$i" 2>/dev/null; then
      SLOT="$ROOT/locks/slot-$i"
      echo "$$" > "$SLOT/pid"
      return 0
    fi
  done
  return 1
}

cmd_doctor() {
  echo "--- gemini-task doctor"
  local bin="${GEMINI_BIN:-}"
  if [ -z "$bin" ] && command -v gemini >/dev/null 2>&1; then
    bin="$(command -v gemini)"
  fi
  if [ -z "$bin" ]; then
    for c in "$APPDATA/npm/gemini.cmd" "$HOME/.npm-global/bin/gemini"              "/usr/local/bin/gemini" "$HOME/.local/bin/gemini"; do
      [ -f "$c" ] && { bin="$c"; break; }
    done
  fi
  if [ -n "$bin" ]; then
    echo "binary:   $bin"
    local ver
    ver="$("$bin" --version 2>/dev/null | head -1)"
    echo "version:  ${ver:-unknown (the binary did not report a version)}"
  else
    echo "binary:   NOT FOUND (npm i -g @google/gemini-cli, or set GEMINI_BIN)"
  fi
  echo "auth:     $("$PY" "$HELPER" gemini-auth "${GEMINI_HOME:-$HOME/.gemini}")"
  local m
  m="$(resolve_model "")"
  if [ -n "$m" ]; then
    echo "model:    $m (in model cache: $(model_known "$m"))"
  else
    echo "model:    not pinned — Gemini uses its own configuration"
  fi
  echo "config:   $GEMINI_CONFIG"
  echo "logs:     $ROOT"
  echo "slots:    $(ls -1d "$ROOT"/locks/slot-* 2>/dev/null | wc -l) busy"
}

cmd_run() {
  local repo="$PWD" base="HEAD" test_cmd="" slug="" max_attempts=3 commit=1 timeout=1800
  local model_opt="" scope="" require_tests=-1 budget=3600 max_parallel=2 allow_dup=0 prompt=""
  local task_file="" forbidden="" acceptance=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task-file) task_file="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      --test) test_cmd="$2"; shift 2 ;;
      --no-require-tests) require_tests=0; shift ;;
      --require-tests) require_tests=1; shift ;;
      --scope) scope="$2"; shift 2 ;;
      --slug) slug="$2"; shift 2 ;;
      --max-attempts) max_attempts="$2"; shift 2 ;;
      --budget-seconds) budget="$2"; shift 2 ;;
      --max-parallel) max_parallel="$2"; shift 2 ;;
      --allow-dup) allow_dup=1; shift ;;
      --model) model_opt="$2"; shift 2 ;;
      --timeout) timeout="$2"; shift 2 ;;
      --no-commit) commit=0; shift ;;
      --) shift; break ;;
      -*) check_flags "$1"; die "unknown option $1" ;;
      *) break ;;
    esac
  done

  # Task contract (task.json)
  if [ -n "$task_file" ]; then
    [ -f "$task_file" ] || die "task file not found: $task_file"
    local c_goal c_scope c_tests c_timeout c_attempts c_slug c_repo c_forbidden c_accept c_deps
    c_goal=$("$PY" "$HELPER" contract-get "$task_file" goal)
    c_scope=$("$PY" "$HELPER" contract-get "$task_file" allowed_files)
    c_tests=$("$PY" "$HELPER" contract-get "$task_file" test_command)
    c_timeout=$("$PY" "$HELPER" contract-get "$task_file" timeout)
    c_attempts=$("$PY" "$HELPER" contract-get "$task_file" max_attempts)
    c_slug=$("$PY" "$HELPER" contract-get "$task_file" task_id)
    c_repo=$("$PY" "$HELPER" contract-get "$task_file" repo)
    c_forbidden=$("$PY" "$HELPER" contract-get "$task_file" forbidden)
    c_accept=$("$PY" "$HELPER" contract-get "$task_file" acceptance)
    c_deps=$("$PY" "$HELPER" contract-get "$task_file" depends_on)
    [ -n "$c_goal" ] || die "the contract has no goal field"
    [ -n "$c_scope" ] && scope="$c_scope"
    [ -n "$c_tests" ] && test_cmd="$c_tests"
    [ -n "$c_timeout" ] && timeout="$c_timeout"
    [ -n "$c_attempts" ] && max_attempts="$c_attempts"
    [ -n "$c_slug" ] && slug="$c_slug"
    [ -n "$c_repo" ] && repo="$c_repo"
    forbidden="$c_forbidden"
    acceptance="$c_accept"
    prompt="$c_goal"
    [ -n "$c_scope" ] && prompt="$prompt

Change boundaries: you may only touch $c_scope"
    [ -n "$c_forbidden" ] && prompt="$prompt
Forbidden: $c_forbidden"
    [ -n "$c_accept" ] && prompt="$prompt
Acceptance criteria: $c_accept"
    [ -n "$c_deps" ] && prompt="$prompt
This task depends on: $c_deps (treat them as already done)"
  else
    prompt="${1:-}"
  fi
  [ -n "$prompt" ] || die "no task text given"
  check_flags "$@"

  [ -d "$repo" ] || die "directory does not exist: $repo"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "$repo is not a git repository"
  [ -f "$RUNNER" ] || die "not found: $RUNNER"
  [ "$require_tests" -eq -1 ] && { [ -n "$test_cmd" ] && require_tests=1 || require_tests=0; }

  local model
  model="$(resolve_model "$model_opt")"
  local warnings=""
  if [ -n "$model" ] && [ "$(model_known "$model")" = "no" ]; then
    warnings="model $model is not in the Gemini model cache"
  fi

  if [ -z "$slug" ]; then
    slug=$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | cut -c1-40)
    slug=${slug#-}
    slug=${slug%-}
    [ -n "$slug" ] || slug="task"
  fi
  mkdir -p "$ROOT/attempts" "$ROOT/active" "$ROOT/progress" "$ROOT/budget" "$ROOT/locks"

  # Refuse an identical task that is already running.
  local dup_hash
  dup_hash="$(printf '%s|%s' "$repo" "$prompt" | "$PY" "$HELPER" sha1)"
  if [ "$allow_dup" -ne 1 ] && [ -f "$ROOT/active/$dup_hash" ]; then
    local other
    other="$(cat "$ROOT/active/$dup_hash")"
    if kill -0 "$(cut -d' ' -f2 <<<"$other")" 2>/dev/null; then
      "$PY" "$HELPER" refuse duplicate "$slug" "an identical task is already running: $other"
      return 4
    fi
    rm -f "$ROOT/active/$dup_hash"
  fi

  # Time budget per slug.
  local spent=0
  [ -f "$ROOT/budget/$slug" ] && spent="$(cat "$ROOT/budget/$slug")"
  if [ "$spent" -ge "$budget" ]; then
    "$PY" "$HELPER" refuse budget_exhausted "$slug" \
      "time budget exhausted: ${spent}s of ${budget}s"
    return 5
  fi

  # Loop protection: attempts.
  local acount_file="$ROOT/attempts/$slug"
  local attempt=1
  [ -f "$acount_file" ] && attempt=$(( $(cat "$acount_file") + 1 ))
  if [ "$attempt" -gt "$max_attempts" ]; then
    "$PY" "$HELPER" blocked "$slug" "$attempt" "$max_attempts"
    return 3
  fi
  echo "$attempt" > "$acount_file"

  # Concurrency limit.
  trap release_resources EXIT
  trap on_signal INT TERM
  if ! acquire_slot "$max_parallel"; then
    "$PY" "$HELPER" refuse parallel_limit "$slug" \
      "concurrent executor limit reached ($max_parallel)"
    return 6
  fi

  local task_id
  task_id="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
  local d="$ROOT/$task_id"
  local wt="$d/wt"
  local branch="gemini/$slug-$task_id"
  mkdir -p "$d"
  printf '%s' "$prompt" > "$d/prompt.txt"
  ACTIVE_FILE="$ROOT/active/$dup_hash"
  echo "$task_id $$" > "$ACTIVE_FILE"

  local base_sha
  base_sha="$(git -C "$repo" rev-parse "$base")" || die "cannot resolve base: $base"
  git -C "$repo" worktree add -b "$branch" "$wt" "$base_sha" >"$d/worktree.log" 2>&1 \
    || { cat "$d/worktree.log" >&2; die "could not create the worktree"; }

  "$PY" "$HELPER" init "$d" "$task_id" "$branch" "$wt" "$repo" "$base_sha" "$model" \
    "$attempt" "$max_attempts" "$test_cmd" "$require_tests" "$scope" "$warnings"

  # Fingerprint critical files before the run (tamper detector).
  "$PY" "$HELPER" guard-snapshot "$d/guard-before.json" "$repo" "$SCRIPTS"

  local t0 t1 engine_exit=0
  t0=$(date +%s)
  set +e
  GEMINI_TASK_ACTIVE="$task_id" GEMINI_MODEL="$model" \
    timeout -k 10 "$timeout" bash "$RUNNER" --write --dir "$wt" --out "$d/last.txt" --json \
      "$prompt" > "$d/events.jsonl" 2> "$d/stderr.log"
  engine_exit=$?
  set -e
  t1=$(date +%s)
  echo "$(( spent + t1 - t0 ))" > "$ROOT/budget/$slug"

  "$PY" "$HELPER" guard-check "$d/guard-before.json" "$repo" "$SCRIPTS" "$d" \
    > "$d/guard-changed.txt" 2>/dev/null || true

  # Facts about the repository, not the executor's claims. The executor may have
  # committed on its own, so changes are measured against the base commit and
  # include both committed and staged work.
  git -C "$wt" add -A >/dev/null 2>&1 || true
  {
    git -C "$wt" diff --name-only "$base_sha" HEAD 2>/dev/null || true
    git -C "$wt" diff --cached --name-only 2>/dev/null || true
  } | sort -u | sed '/^$/d' > "$d/changed_files.txt"

  local commit_sha=""
  if [ "$commit" -eq 1 ] && [ -n "$(git -C "$wt" diff --cached --name-only 2>/dev/null)" ]; then
    git -C "$wt" -c user.name="gemini-task" -c user.email="gemini-task@local" \
      commit -q -m "gemini: $slug ($task_id)" >>"$d/worktree.log" 2>&1 || true
  fi
  local head_sha
  head_sha="$(git -C "$wt" rev-parse HEAD)"
  [ "$head_sha" != "$base_sha" ] && commit_sha="$head_sha"

  if [ -n "$commit_sha" ]; then
    git -C "$wt" diff "$base_sha".."$commit_sha" > "$d/diff.patch" 2>/dev/null \
      || : > "$d/diff.patch"
    # anything still uncommitted (e.g. --no-commit) is appended for review
    git -C "$wt" diff --cached >> "$d/diff.patch" 2>/dev/null || true
  else
    git -C "$wt" diff --cached > "$d/diff.patch" 2>/dev/null || : > "$d/diff.patch"
  fi

  # No progress between attempts?
  local no_progress=0 dhash prev=""
  dhash="$("$PY" "$HELPER" sha1-file "$d/diff.patch")"
  [ -f "$ROOT/progress/$slug" ] && prev="$(cat "$ROOT/progress/$slug")"
  if [ "$attempt" -gt 1 ] && [ "$dhash" = "$prev" ]; then no_progress=1; fi
  echo "$dhash" > "$ROOT/progress/$slug"

  local test_exit="null"
  if [ -n "$test_cmd" ]; then
    set +e
    # PYTHONDONTWRITEBYTECODE: our own verification must not leave __pycache__
    # inside the worktree, otherwise it looks dirty and clean refuses to remove it.
    ( cd "$wt" && GEMINI_TASK_ACTIVE="$task_id" PYTHONDONTWRITEBYTECODE=1 \
        timeout -k 10 "$timeout" bash -c "$test_cmd" ) \
      > "$d/tests.log" 2>&1
    test_exit=$?
    set -e
  else
    : > "$d/tests.log"
  fi

  "$PY" "$HELPER" finish "$d" "$engine_exit" "$test_exit" "$commit_sha" "$((t1-t0))" "$no_progress"

  set +e
  "$PY" "$REPORTER" "$d"
  local rc=$?
  set -e

  "$PY" "$HELPER" index "$d" "$ROOT"

  if [ "$rc" -eq 0 ]; then
    rm -f "$acount_file" "$ROOT/budget/$slug" "$ROOT/progress/$slug"
  fi
  release_resources
  return $rc
}

cmd_review() {
  # Cross-review: the reviewer reads the ACTUAL diff, not the executor's report.
  # Always runs read-only.
  local task_id="" accept="" focus="" ext_repo="" ext_diff=""
  case "${1:-}" in
    ""|--*) : ;;
    *) task_id="$1"; shift ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --acceptance) accept="$2"; shift 2 ;;
      --focus) focus="$2"; shift 2 ;;
      --repo) ext_repo="$2"; shift 2 ;;
      --diff) ext_diff="$2"; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done

  local d target
  if [ -n "$task_id" ]; then
    d="$ROOT/$task_id"
    [ -f "$d/diff.patch" ] || die "no diff for $task_id"
    local repo wt
    repo=$(jget "$d/meta.json" repo)
    wt=$(jget "$d/meta.json" worktree)
    target="$repo"
    [ -d "$wt" ] && target="$wt"
  else
    [ -n "$ext_repo" ] && [ -n "$ext_diff" ] || die "need --repo and --diff (or a task_id)"
    [ -f "$ext_diff" ] || die "diff file not found: $ext_diff"
    d="$ROOT/review-$(date +%Y%m%d-%H%M%S)-$RANDOM"
    mkdir -p "$d"
    cp "$ext_diff" "$d/diff.patch"
    target="$ext_repo"
  fi

  local prompt
  # This engine tends to wander off and explore the directory unless it is told
  # not to, and it drops the output contract unless it is repeated after the diff.
  prompt="You are an independent reviewer. Analyse ONLY the diff given at the end of this message.
Do not list, open or explore files in the directory. Do not describe the repository.
Reply with JSON ONLY, no prose before or after:
{\"verdict\": \"ok|changes_requested\", \"findings\": [{\"severity\": \"high|medium|low\", \"kind\": \"bug|security|requirements|tests|regression\", \"file\": \"...\", \"detail\": \"...\", \"evidence\": \"...\"}], \"missing_tests\": [\"...\"], \"summary\": \"...\"}
Back every critical finding with a concrete place in the code. Do not propose style changes."
  [ -n "$accept" ] && prompt="$prompt
Acceptance criteria: $accept"
  [ -n "$focus" ] && prompt="$prompt
Pay special attention to: $focus"
  prompt="$prompt

DIFF:
$(head -c 60000 "$d/diff.patch")

END OF DIFF. Now reply with the JSON object described above and nothing else."

  set +e
  GEMINI_TASK_ACTIVE="review-$task_id" \
    timeout -k 10 900 bash "$RUNNER" --read --dir "$target" --out "$d/review.txt" \
      --skip-git-repo-check "$prompt" > "$d/review.jsonl" 2> "$d/review-stderr.log"
  local rc=$?
  set -e
  "$PY" "$HELPER" review-parse "$d/review.txt" > "$d/review.json"
  cat "$d/review.json"
  return $rc
}

cmd_merge() {
  local task_id="${1:-}"
  [ -n "$task_id" ] || die "task_id required"
  shift
  local into="" ack=0 test_override=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --into) into="$2"; shift 2 ;;
      --ack) ack=1; shift ;;
      --test) test_override="$2"; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  local d="$ROOT/$task_id"
  [ -f "$d/report.json" ] || die "no report for $task_id"

  local status risks risk_level tests_status branch repo commit test_cmd require_tests
  status=$(jget "$d/report.json" status)
  risks=$(jget "$d/report.json" risks)
  risk_level=$(jget "$d/report.json" risk_level)
  tests_status=$(jget "$d/report.json" tests_status)
  branch=$(jget "$d/report.json" branch)
  commit=$(jget "$d/report.json" commit)
  repo=$(jget "$d/meta.json" repo)
  test_cmd=$(jget "$d/meta.json" test_command)
  require_tests=$(jget "$d/meta.json" require_tests)

  [ -n "$commit" ] && [ "$commit" != "None" ] || die "the task has no commit — nothing to merge"
  [ -n "$into" ] || into="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"

  # Merge exactly the commit that was reported, reviewed and risk-checked.
  # Anything added to the branch afterwards has not been through the gate.
  local branch_tip
  branch_tip="$(git -C "$repo" rev-parse "$branch" 2>/dev/null || echo "")"
  if [ "$branch_tip" != "$commit" ]; then
    die "branch $branch moved past the verified commit ($commit != $branch_tip) — re-run the task"
  fi

  # 1. Conflicts are checked FIRST and are never bypassable with --ack.
  local mb
  mb="$(git -C "$repo" merge-base "$into" "$branch" 2>/dev/null)" \
    || die "cannot compute merge-base for $into and $branch"
  if git -C "$repo" merge-tree "$mb" "$into" "$branch" 2>/dev/null | grep -q "^+<<<<<<<"; then
    die "merge conflicts — forbidden even with --ack, resolve them manually"
  fi

  # 2. Never overwrite uncommitted user work. This only matters when the target
  # branch is the one checked out here; otherwise only a ref moves.
  local cur_branch
  cur_branch="$(git -C "$repo" symbolic-ref --short -q HEAD || echo "")"
  if [ "$into" = "$cur_branch" ] && [ -n "$(git -C "$repo" status --porcelain)" ]; then
    die "the working copy has uncommitted changes — merge refused"
  fi
  if [ "$into" != "$cur_branch" ] \
     && git -C "$repo" worktree list --porcelain | grep -qx "branch refs/heads/$into"; then
    die "branch $into is checked out in another worktree — refusing to update it"
  fi

  # 3. Task state.
  if [ "$status" != "success" ] && [ "$ack" -ne 1 ]; then
    die "task status is \"$status\" — automatic merge refused (use --ack after a manual review)"
  fi
  if [ "$risk_level" != "none" ] && [ "$ack" -ne 1 ]; then
    die "risk level $risk_level ($risks) — manual confirmation --ack required"
  fi
  if [ "$require_tests" = "True" ] && [ "$tests_status" != "passed" ] && [ "$ack" -ne 1 ]; then
    die "tests are \"$tests_status\" while required — merge refused"
  fi

  # 4. Atomic merge: build and verify the result in a temporary worktree first.
  # The target branch changes ONLY after the tests pass.
  local before stage merged_sha
  before="$(git -C "$repo" rev-parse "$into")"
  stage="$d/merge-stage-$(date +%H%M%S)-$RANDOM"
  git -C "$repo" worktree add --detach "$stage" "$into" >>"$d/merge.log" 2>&1 \
    || die "could not prepare the temporary worktree for the merge check"

  if ! git -C "$stage" merge --no-ff --no-edit "$branch" >>"$d/merge.log" 2>&1; then
    git -C "$stage" merge --abort 2>/dev/null || true
    git -C "$repo" worktree remove --force "$stage" 2>/dev/null || true
    die "merge failed during the staged check, target branch untouched ($before). Log: $d/merge.log"
  fi
  merged_sha="$(git -C "$stage" rev-parse HEAD)"
  echo "candidate merge result built: $merged_sha (staged check)"

  [ -n "$test_override" ] && test_cmd="$test_override"
  if [ -z "$test_cmd" ] || [ "$test_cmd" = "None" ]; then
    echo "WARNING: no verification command — regressions after the merge are not checked." >&2
    echo "Pass merge --test \"<command>\" when the change touches code." >&2
    echo "post-merge tests: not run (no verification command)"
  else
    set +e
    ( cd "$stage" && PYTHONDONTWRITEBYTECODE=1 bash -c "$test_cmd" ) \
      > "$d/tests-after-merge.log" 2>&1
    local after_exit=$?
    set -e
    if [ "$after_exit" -ne 0 ]; then
      git -C "$repo" worktree remove --force "$stage" 2>/dev/null || true
      git -C "$repo" worktree prune
      echo "WARNING: tests failed on the candidate merge result (exit $after_exit)." >&2
      echo "Target branch $into was NOT changed (HEAD $before). Task branch and worktree kept." >&2
      echo "Log: $d/tests-after-merge.log" >&2
      "$PY" "$HELPER" merge-log "$d" "$ROOT" "$into" "rejected_tests_failed"
      return 1
    fi
    echo "post-merge tests: passed"
  fi

  # 5. Update exactly the ref given by --into, and only if it has not moved
  # since the candidate was built (compare-and-swap).
  # The checked-out branch may have changed while the tests ran; a fast-forward
  # would then land on the wrong branch.
  local now_branch
  now_branch="$(git -C "$repo" symbolic-ref --short -q HEAD || echo "")"
  if [ "$now_branch" != "$cur_branch" ]; then
    git -C "$repo" worktree remove --force "$stage" 2>/dev/null || true
    git -C "$repo" worktree prune
    echo "WARNING: the checked-out branch changed during the check ($cur_branch -> ${now_branch:-detached})." >&2
    echo "No branch was changed. Task branch and worktree kept." >&2
    "$PY" "$HELPER" merge-log "$d" "$ROOT" "$into" "rejected_head_moved" "$before" "$before"
    return 1
  fi

  local now_sha
  now_sha="$(git -C "$repo" rev-parse "$into")"
  if [ "$now_sha" != "$before" ]; then
    git -C "$repo" worktree remove --force "$stage" 2>/dev/null || true
    git -C "$repo" worktree prune
    echo "WARNING: $into moved during the check ($before -> $now_sha)." >&2
    echo "No branch was changed. Task branch and worktree kept." >&2
    echo "Run the merge again to verify against the new state of $into." >&2
    "$PY" "$HELPER" merge-log "$d" "$ROOT" "$into" "rejected_target_moved" "$before" "$now_sha"
    return 1
  fi

  if [ "$into" = "$cur_branch" ]; then
    # Target is checked out here: fast-forward moves branch and files together.
    if ! git -C "$repo" merge --ff-only "$merged_sha" >>"$d/merge.log" 2>&1; then
      git -C "$repo" worktree remove --force "$stage" 2>/dev/null || true
      die "could not fast-forward $into to the verified result, branch untouched ($before)"
    fi
  else
    # Target is not checked out: move only the ref. The user's working copy,
    # HEAD and index are left alone. The third argument is the compare-and-swap.
    if ! git -C "$repo" update-ref -m "gemini-task: merge $branch into $into" \
           "refs/heads/$into" "$merged_sha" "$before" >>"$d/merge.log" 2>&1; then
      git -C "$repo" worktree remove --force "$stage" 2>/dev/null || true
      die "could not update ref $into (state changed), branch untouched ($before)"
    fi
  fi

  git -C "$repo" worktree remove --force "$stage" 2>/dev/null || true
  git -C "$repo" worktree prune
  echo "merged: $branch -> $into ($before -> $merged_sha)"
  if [ "$into" != "$cur_branch" ]; then
    echo "working copy on ${cur_branch:-(detached HEAD)} was not touched"
  fi
  "$PY" "$HELPER" merge-log "$d" "$ROOT" "$into" "merged" "$before" "$merged_sha"
}

cmd_clean() {
  local task_id="${1:-}"
  [ -n "$task_id" ] || die "task_id required"
  shift
  local force=0
  [ "${1:-}" = "--force" ] && force=1
  local d="$ROOT/$task_id"
  local wt="$d/wt"
  local repo
  repo=$(jget "$d/meta.json" repo)
  if [ -d "$wt" ] && [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ] && [ "$force" -ne 1 ]; then
    die "the worktree has uncommitted changes — removal refused (use --force)"
  fi
  local rm_ok=0
  if [ "$force" -eq 1 ]; then
    git -C "$repo" worktree remove --force "$wt" >>"$d/worktree.log" 2>&1 && rm_ok=1
  else
    git -C "$repo" worktree remove "$wt" >>"$d/worktree.log" 2>&1 && rm_ok=1
  fi
  git -C "$repo" worktree prune
  if [ "$rm_ok" -eq 1 ] || [ ! -d "$wt" ]; then
    echo "worktree removed, task log kept: $d"
  else
    echo "could not remove the worktree (see $d/worktree.log); task log kept: $d" >&2
    return 1
  fi
}

cmd_gc() {
  local days=30 max_mb=500 dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --days) days="$2"; shift 2 ;;
      --max-mb) max_mb="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) die "unknown option $1" ;;
    esac
  done
  "$PY" "$HELPER" gc "$ROOT" "$days" "$max_mb" "$dry"
}

cmd_stats() { "$PY" "$HELPER" stats "$ROOT"; }

cmd_recover() {
  # Unfinished tasks and orphaned resources. Never deletes anything by itself.
  "$PY" "$HELPER" orphans "$ROOT"
  echo "--- worktrees with uncommitted changes:"
  local found=0
  for d in "$ROOT"/2*; do
    [ -d "$d/wt" ] || continue
    local repo
    repo=$(jget "$d/meta.json" repo 2>/dev/null || echo "")
    [ -n "$repo" ] || continue
    if [ -n "$(git -C "$d/wt" status --porcelain 2>/dev/null)" ]; then
      echo "  $(basename "$d"): uncommitted changes (repository $repo)"
      found=1
    fi
  done
  [ "$found" -eq 0 ] && echo "  none"
  echo "--- orphaned worktree records: check with git -C <repo> worktree prune"
}

cmd_list() {
  if [ -f "$ROOT/index.jsonl" ]; then
    tail -20 "$ROOT/index.jsonl"
  else
    echo "no tasks yet"
  fi
}

cmd_show() { cat "$ROOT/${1:-}/report.json"; }

case "${1:-}" in
  run)     shift; cmd_run "$@" ;;
  review)  shift; cmd_review "$@" ;;
  merge)   shift; cmd_merge "$@" ;;
  clean)   shift; cmd_clean "$@" ;;
  gc)      shift; cmd_gc "$@" ;;
  stats)   shift; cmd_stats "$@" ;;
  recover) shift; cmd_recover "$@" ;;
  list)    shift; cmd_list "$@" ;;
  show)    shift; cmd_show "$@" ;;
  doctor)  shift; cmd_doctor "$@" ;;
  *) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
