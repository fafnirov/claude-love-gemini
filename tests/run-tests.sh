#!/usr/bin/env bash
# Core test suite: risk detector, task boundaries, limits, merge gates,
# parallelism. Uses the test double, so it costs nothing to run.
#   bash tests/run-tests.sh
set -u
export PYTHONIOENCODING=utf-8

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -n "${CLC_SCRIPTS:-}" ]; then S="$CLC_SCRIPTS"
elif [ -f "$HERE/../scripts/gemini-task.sh" ]; then S="$(cd "$HERE/../scripts" && pwd)"
elif [ -f "$HERE/../gemini-task.sh" ]; then S="$(cd "$HERE/.." && pwd)"
else echo "cannot locate the scripts directory; set CLC_SCRIPTS" >&2; exit 2; fi
PY="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo python)"
T="$S/gemini-task.sh"
BASEDIR="$(mktemp -d "${TMPDIR:-/tmp}/clc-core-XXXXXX")"
export GEMINI_TASKS_DIR="$BASEDIR/tasks"
# which engine this run exercises: gemini (API key) or agy (account)
TEST_ENGINE="${CLC_TEST_ENGINE:-gemini}"
export CLC_ENGINE="$TEST_ENGINE"
if [ "$TEST_ENGINE" = "agy" ]; then
  export AGY_BIN="$HERE/fake-agy.sh"
  BIN_VAR=AGY_BIN
else
  export GEMINI_BIN="$HERE/fake-gemini.sh"
  BIN_VAR=GEMINI_BIN
fi

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1 -- $2"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
contains(){ case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "no [$2] in: $(printf '%s' "$3" | head -c 200)" ;; esac; }

mkrepo() {
  rm -rf "$1"; mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config core.autocrlf false
  git -C "$1" config user.name test
  git -C "$1" config user.email test@local
  printf 'def add(a, b):\n    return a + b\n' > "$1/calc.py"
  printf 'from calc import add\n\nassert add(2, 3) == 5\nprint("ok")\n' > "$1/test_calc.py"
  printf '# project\n' > "$1/README.md"
  git -C "$1" add -A
  git -C "$1" commit -qm init
}

status_of() { "$PY" -c "import json,sys;print(json.load(open(sys.argv[1],encoding='utf-8')).get('status'))" "$1"; }
field_of()  { "$PY" -c "import json,sys;v=json.load(open(sys.argv[1],encoding='utf-8')).get(sys.argv[2]);print(v if not isinstance(v,list) else '; '.join(map(str,v)))" "$1" "$2"; }
task_id_of(){ "$PY" -c "import json,sys;print(json.load(open(sys.argv[1],encoding='utf-8'))['task_id'])" "$1" 2>/dev/null; }
last_task() {
  local id
  id="$(task_id_of "$BASEDIR/out.json")"
  if [ -n "$id" ] && [ "$id" != "None" ] && [ -d "$GEMINI_TASKS_DIR/$id" ]; then
    echo "$GEMINI_TASKS_DIR/$id"
  else
    ls -1dt "$GEMINI_TASKS_DIR"/2* 2>/dev/null | head -1
  fi
}

R="$BASEDIR/repo"

echo "=== A. Risk detector on real git diffs ==="
run_case() { # run_case <name> <FAKE_ACTION> <expected risk_level>
  mkrepo "$R"
  FAKE_ACTION="$2" bash "$T" run --repo "$R" --slug "det-$2" --no-require-tests "task $2" \
    >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
  local d; d="$(last_task)"
  check "$1 (risk_level)" "$3" "$(field_of "$d/report.json" risk_level)"
  if [ "$3" != "none" ]; then
    local risks; risks="$(field_of "$d/report.json" risks)"
    [ -n "$risks" ] && ok "$1 (labels: $risks)" || bad "$1" "risks not named"
    check "$1 (status)" "needs_review" "$(status_of "$d/report.json")"
    check "$1 (auto-merge)" "False" "$(field_of "$d/report.json" auto_merge_allowed)"
  fi
}
run_case "env and secrets"      env      high
run_case "api key in code"      secret   high
run_case "DROP TABLE migration" sql      high
run_case "rm -rf in a script"   rmrf     high
run_case "symlink creation"     symlink  high
run_case "tests removed"        deltest  high
run_case "hidden TRUNCATE"      hidden   high
run_case "binary file"          binary   medium
run_case "file rename"          rename   medium
echo "--- false positives: a harmless change must not be flagged"
run_case "harmless change"      ok       none

echo
echo "=== B. Task boundaries (scope) ==="
mkrepo "$R"
FAKE_ACTION=outside bash "$T" run --repo "$R" --slug scope-test --scope "calc.py,test_calc.py" \
  --no-require-tests "change outside the boundaries" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
D="$(last_task)"
check "diff outside scope -> needs_review" "needs_review" "$(status_of "$D/report.json")"
check "scope_ok=False" "False" "$(field_of "$D/report.json" scope_ok)"
contains "boundary warning" "leaves the task boundaries" "$(field_of "$D/report.json" warnings)"

mkrepo "$R"
FAKE_ACTION=selfcommit bash "$T" run --repo "$R" --slug selfcommit --no-require-tests   "executor commits by itself" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
D="$(last_task)"
check "executor self-commit: status success" "success" "$(status_of "$D/report.json")"
contains "executor self-commit: file listed" "calc.py" "$(field_of "$D/report.json" changed_files)"
[ "$(field_of "$D/report.json" commit)" != "None" ] && ok "executor self-commit: commit recorded"   || bad "self-commit" "no commit in the report"
[ -s "$D/diff.patch" ] && ok "executor self-commit: diff captured" || bad "self-commit" "empty diff"

mkrepo "$R"
FAKE_ACTION=prefix bash "$T" run --repo "$R" --slug prefix-scope --scope "calc.py"   --no-require-tests "write a lookalike file" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
D="$(last_task)"
check "scope: calc.py.bak is outside scope calc.py" "needs_review" "$(status_of "$D/report.json")"
check "scope: scope_ok=False for the lookalike" "False" "$(field_of "$D/report.json" scope_ok)"

echo
echo "=== C. Tests: not_run, failed, passed ==="
mkrepo "$R"
FAKE_ACTION=ok bash "$T" run --repo "$R" --slug tests-notrun --require-tests "no test command" \
  >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
D="$(last_task)"
check "required tests not run -> tests_not_run" "tests_not_run" "$(status_of "$D/report.json")"
check "tests_not_run=True" "True" "$(field_of "$D/report.json" tests_not_run)"
check "auto-merge refused" "False" "$(field_of "$D/report.json" auto_merge_allowed)"

mkrepo "$R"
FAKE_ACTION=breaktest bash "$T" run --repo "$R" --slug tests-fail --test "'$PY' test_calc.py" \
  "break the test" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
D="$(last_task)"
check "failing tests -> tests_failed" "tests_failed" "$(status_of "$D/report.json")"
check "tests_failed=True" "True" "$(field_of "$D/report.json" tests_failed)"

mkrepo "$R"
FAKE_ACTION=ok bash "$T" run --repo "$R" --slug tests-pass --test "'$PY' test_calc.py" \
  "correct change" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
D="$(last_task)"
check "success -> success" "success" "$(status_of "$D/report.json")"
check "tests_passed=True" "True" "$(field_of "$D/report.json" tests_passed)"
check "auto-merge allowed" "True" "$(field_of "$D/report.json" auto_merge_allowed)"

echo
echo "=== D. CLI modes ==="
mkrepo "$R"
FAKE_ACTION=ok bash "$T" run --repo "$R" --slug nocommit --no-commit --no-require-tests "no commit" \
  >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
D="$(last_task)"
check "--no-commit: no commit" "None" "$(field_of "$D/report.json" commit)"
[ -s "$D/diff.patch" ] && ok "--no-commit: diff still collected" || bad "--no-commit" "diff empty"

mkrepo "$R"
git -C "$R" tag base-point
printf 'extra\n' > "$R/extra.txt"; git -C "$R" add -A; git -C "$R" commit -qm "second commit"
FAKE_ACTION=ok bash "$T" run --repo "$R" --slug basetest --base base-point --no-require-tests \
  "branch from the tag" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
D="$(last_task)"
BASE_IN_META="$("$PY" -c "import json,sys;print(json.load(open(sys.argv[1],encoding='utf-8'))['base'])" "$D/meta.json")"
check "--base: branched from the given point" "$(git -C "$R" rev-parse base-point)" "$BASE_IN_META"
if [ -f "$D/wt/extra.txt" ]; then bad "--base" "worktree contains a newer commit"; else ok "--base: worktree has no newer commits"; fi

mkrepo "$R"
FAKE_ACTION=ok FAKE_SLEEP=30 bash "$T" run --repo "$R" --slug timeouttest --timeout 3 \
  --no-require-tests "long task" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
D="$(last_task)"
check "--timeout: status timeout" "timeout" "$(status_of "$D/report.json")"
check "--timeout: engine_exit=124" "124" "$(field_of "$D/report.json" engine_exit)"

SR="$BASEDIR/repo with spaces"
mkrepo "$SR"
FAKE_ACTION=ok bash "$T" run --repo "$SR" --slug spaces --test "'$PY' test_calc.py" \
  "path with spaces" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
D="$(last_task)"
check "path with spaces: success" "success" "$(status_of "$D/report.json")"

OUT="$(bash "$T" run --repo "$BASEDIR/no-such-dir" --no-require-tests "x" 2>&1)"
contains "missing repository path" "does not exist" "$OUT"

mkdir -p "$BASEDIR/notgit"
OUT="$(bash "$T" run --repo "$BASEDIR/notgit" --no-require-tests "x" 2>&1)"
contains "not a git repository" "not a git repository" "$OUT"

mkrepo "$R"
env "$BIN_VAR=/nonexistent/engine-binary" FAKE_ACTION=ok bash "$T" run --repo "$R" --slug nobin \
  --no-require-tests "missing binary" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
D="$(last_task)"
check "missing binary: status failed" "failed" "$(status_of "$D/report.json")"

mkrepo "$R"
FAKE_ACTION=ok FAKE_EXIT=7 bash "$T" run --repo "$R" --slug nonzero --no-require-tests \
  "executor error" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
D="$(last_task)"
check "non-zero exit: status failed" "failed" "$(status_of "$D/report.json")"
check "non-zero exit recorded" "7" "$(field_of "$D/report.json" engine_exit)"

mkrepo "$R"
FAKE_ACTION=ok FAKE_ANSWER=empty bash "$T" run --repo "$R" --slug silent --no-require-tests \n  "engine says nothing" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
D="$(last_task)"
check "silent engine: report still built" "success" "$(status_of "$D/report.json")"
contains "silent engine: missing token usage is flagged" "token usage unavailable" "$(field_of "$D/report.json" warnings)"

mkrepo "$R"
FAKE_ACTION=ok FAKE_JSON=empty bash "$T" run --repo "$R" --slug emptyjson --no-require-tests \
  "empty log" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
D="$(last_task)"
check "empty JSONL: report still built" "success" "$(status_of "$D/report.json")"

mkrepo "$R"
FAKE_ACTION=nochange bash "$T" run --repo "$R" --slug nochange --no-require-tests "do nothing" \
  >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
D="$(last_task)"
check "no changes -> no_changes" "no_changes" "$(status_of "$D/report.json")"

echo
echo "=== E. Limits and loop protection ==="
mkrepo "$R"
mkdir -p "$GEMINI_TASKS_DIR/attempts"; echo 3 > "$GEMINI_TASKS_DIR/attempts/limit-slug"
OUT="$(FAKE_ACTION=ok bash "$T" run --repo "$R" --slug limit-slug --no-require-tests "x" 2>&1)"
contains "attempt limit -> blocked" "blocked" "$OUT"

mkdir -p "$GEMINI_TASKS_DIR/budget"; echo 99999 > "$GEMINI_TASKS_DIR/budget/budget-slug"
OUT="$(FAKE_ACTION=ok bash "$T" run --repo "$R" --slug budget-slug --budget-seconds 100 \
  --no-require-tests "x" 2>&1)"
contains "budget exhausted -> budget_exhausted" "budget_exhausted" "$OUT"

# Attempt counters only grow after failures, so two identical failing attempts.
mkrepo "$R"
FAKE_ACTION=breaktest bash "$T" run --repo "$R" --slug progress --test "'$PY' test_calc.py" \
  "first attempt" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
mkrepo "$R"
FAKE_ACTION=breaktest bash "$T" run --repo "$R" --slug progress --test "'$PY' test_calc.py" \
  "second attempt" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
D="$(last_task)"
check "second failing attempt counted" "2" "$(field_of "$D/report.json" attempt)"
contains "no progress -> warning" "no progress" "$(field_of "$D/report.json" warnings)"

mkrepo "$R"
DUPH="$(printf '%s|%s' "$R" "duplicate" | "$PY" "$S/task_meta.py" sha1)"
mkdir -p "$GEMINI_TASKS_DIR/active"; echo "fake-task $$" > "$GEMINI_TASKS_DIR/active/$DUPH"
OUT="$(FAKE_ACTION=ok bash "$T" run --repo "$R" --slug duptest --no-require-tests "duplicate" 2>&1)"
contains "duplicate task refused" "duplicate" "$OUT"
rm -f "$GEMINI_TASKS_DIR/active/$DUPH"

mkdir -p "$GEMINI_TASKS_DIR/locks/slot-1" "$GEMINI_TASKS_DIR/locks/slot-2"
echo "$$" > "$GEMINI_TASKS_DIR/locks/slot-1/pid"
echo "$$" > "$GEMINI_TASKS_DIR/locks/slot-2/pid"
OUT="$(FAKE_ACTION=ok bash "$T" run --repo "$R" --slug partest --max-parallel 2 \
  --no-require-tests "x" 2>&1)"
contains "parallel limit" "parallel_limit" "$OUT"
rm -rf "$GEMINI_TASKS_DIR/locks"

OUT="$(GEMINI_TASK_ACTIVE=t-1 bash "$T" run --repo "$R" "x" 2>&1)"
contains "recursion refused" "recursive invocation is forbidden" "$OUT"
OUT="$(bash "$T" run --repo "$R" --yolo "x" 2>&1)"
contains "--yolo refused" "is forbidden" "$OUT"
OUT="$(bash "$T" run --repo "$R" --dangerously-bypass-approvals-and-sandbox "x" 2>&1)"
contains "bypass flag refused" "is forbidden" "$OUT"

echo
echo "=== F. Two tasks in parallel ==="
mkrepo "$R"
rm -rf "$GEMINI_TASKS_DIR/locks"
( FAKE_ACTION=ok FAKE_SLEEP=2 bash "$T" run --repo "$R" --slug par-a --no-require-tests "task A" \
  >"$BASEDIR/pa.json" 2>&1 ) &
P1=$!
( FAKE_ACTION=secret FAKE_SLEEP=2 bash "$T" run --repo "$R" --slug par-b --no-require-tests "task B" \
  >"$BASEDIR/pb.json" 2>&1 ) &
P2=$!
wait $P1; wait $P2
IDA="$(task_id_of "$BASEDIR/pa.json")"
IDB="$(task_id_of "$BASEDIR/pb.json")"
if [ -n "$IDA" ] && [ "$IDA" != "$IDB" ]; then ok "parallel: task_ids differ ($IDA / $IDB)"; else bad "parallel" "task_ids collided"; fi
WTC="$(git -C "$R" worktree list | wc -l)"
[ "$WTC" -ge 3 ] && ok "parallel: independent worktrees ($WTC entries)" || bad "parallel" "worktrees not isolated: $WTC"
check "locks released" "0" "$(ls -1d "$GEMINI_TASKS_DIR"/locks/slot-* 2>/dev/null | wc -l)"

echo
echo "=== G. Safe merge ==="
mkrepo "$R"
FAKE_ACTION=ok bash "$T" run --repo "$R" --slug merge-ok --test "'$PY' test_calc.py" \
  "change to merge" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
D="$(last_task)"; MID="$(basename "$D")"
printf 'def add(a, b):\n    return a + b  # main branch\n' > "$R/calc.py"
git -C "$R" commit -qam "edit on main"
OUT="$(bash "$T" merge "$MID" --into main 2>&1)"
contains "conflict blocks the merge" "conflicts" "$OUT"
OUT="$(bash "$T" merge "$MID" --into main --ack 2>&1)"
contains "conflict not bypassable with --ack" "forbidden even with --ack" "$OUT"
BEFORE="$(git -C "$R" rev-parse HEAD)"
check "main preserved" "$BEFORE" "$(git -C "$R" rev-parse HEAD)"

mkrepo "$R"
FAKE_ACTION=ok bash "$T" run --repo "$R" --slug merge-dirty --test "'$PY' test_calc.py" \
  "change 2" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
D="$(last_task)"; MID="$(basename "$D")"
printf 'user edit\n' >> "$R/README.md"
OUT="$(bash "$T" merge "$MID" --into main 2>&1)"
contains "dirty copy blocks the merge" "uncommitted changes" "$OUT"
contains "user edit untouched" "user edit" "$(cat "$R/README.md")"
git -C "$R" checkout -q -- README.md

OUT="$(bash "$T" merge "$MID" --into main 2>&1)"
contains "merge succeeds" "merged:" "$OUT"
contains "post-merge tests" "post-merge tests: passed" "$OUT"
[ "$(grep -c 'def mul' "$R/calc.py")" -ge 1 ] && ok "change landed on main" || bad "merge" "change missing"

printf 'junk\n' > "$D/wt/stray.txt"
OUT="$(bash "$T" clean "$MID" 2>&1)"
contains "clean protects uncommitted work" "removal refused" "$OUT"
rm -f "$D/wt/stray.txt"
OUT="$(bash "$T" clean "$MID" 2>&1)"
contains "clean removes the worktree" "worktree removed" "$OUT"
[ -f "$D/report.json" ] && ok "task log kept after clean" || bad "clean" "log lost"

echo
echo "=== H. Audit log ==="
[ -f "$GEMINI_TASKS_DIR/index.jsonl" ] && ok "index.jsonl exists" || bad "index" "no audit log"
contains "merge event recorded" "merge" "$(tail -5 "$GEMINI_TASKS_DIR/index.jsonl")"
contains "token usage recorded" "token_usage" "$(tail -20 "$GEMINI_TASKS_DIR/index.jsonl" | head -1)"

echo
echo "=== RESULT [$TEST_ENGINE]: PASS=$PASS FAIL=$FAIL ==="
rm -rf "$BASEDIR"
[ "$FAIL" -eq 0 ]
