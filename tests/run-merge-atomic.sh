#!/usr/bin/env bash
# Merge atomicity suite: a failing post-merge test must never leave the target
# branch changed, and only the ref named by --into may move.
set -u
export PYTHONIOENCODING=utf-8

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -n "${CLC_SCRIPTS:-}" ]; then S="$CLC_SCRIPTS"
elif [ -f "$HERE/../scripts/gemini-task.sh" ]; then S="$(cd "$HERE/../scripts" && pwd)"
elif [ -f "$HERE/../gemini-task.sh" ]; then S="$(cd "$HERE/.." && pwd)"
else echo "cannot locate the scripts directory; set CLC_SCRIPTS" >&2; exit 2; fi
PY="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo python)"
T="$S/gemini-task.sh"
BASEDIR="$(mktemp -d "${TMPDIR:-/tmp}/clc-atomic-XXXXXX")"
export GEMINI_TASKS_DIR="$BASEDIR/tasks"
# which engine this run exercises: gemini (API key) or agy (account)
TEST_ENGINE="${CLC_TEST_ENGINE:-gemini}"
export CLC_ENGINE="$TEST_ENGINE"
if [ "$TEST_ENGINE" = "agy" ]; then
  export AGY_BIN="$HERE/fake-agy.sh"
else
  export GEMINI_BIN="$HERE/fake-gemini.sh"
fi

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1 -- $2"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
contains(){ case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "no [$2] in: $(printf '%s' "$3" | head -c 200)" ;; esac; }
task_id_of(){ "$PY" -c "import json,sys;print(json.load(open(sys.argv[1],encoding='utf-8'))['task_id'])" "$1" 2>/dev/null; }

mkrepo() {
  rm -rf "$1"; mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config core.autocrlf false
  git -C "$1" config user.name test
  git -C "$1" config user.email test@local
  printf 'def add(a, b):\n    return a + b\n' > "$1/calc.py"
  printf 'from calc import add\n\nassert add(2, 3) == 5\nprint("ok")\n' > "$1/test_calc.py"
  git -C "$1" add -A; git -C "$1" commit -qm init
}

R="$BASEDIR/repo"
mkrepo "$R"

echo "=== Negative: tests fail on the candidate merge result ==="
# The task breaks add() and has no tests of its own; the regression must be
# caught by the verification run at merge time.
FAKE_ACTION=breakmain bash "$T" run --repo "$R" --slug atomic-break --no-require-tests \
  "break addition" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
ID="$(task_id_of "$BASEDIR/out.json")"
[ -n "$ID" ] && ok "task created ($ID)" || bad "setup" "task not created"

BEFORE_SHA="$(git -C "$R" rev-parse main)"
BEFORE_CALC="$(cat "$R/calc.py")"
BEFORE_WT="$(git -C "$R" worktree list | wc -l)"

set +e
OUT="$(bash "$T" merge "$ID" --into main --test "'$PY' test_calc.py" 2>&1)"
RC=$?
set -e

[ "$RC" -ne 0 ] && ok "merge returned a non-zero code ($RC)" || bad "exit code" "merge returned 0"
contains "failure is reported" "tests failed" "$OUT"
contains "branch safety is reported" "was NOT changed" "$OUT"
check "target HEAD unchanged" "$BEFORE_SHA" "$(git -C "$R" rev-parse main)"
check "target content unchanged" "$BEFORE_CALC" "$(cat "$R/calc.py")"
check "working copy clean" "" "$(git -C "$R" status --porcelain)"
git -C "$R" rev-parse --verify "gemini/atomic-break-$ID" >/dev/null 2>&1 \
  && ok "task branch kept" || bad "task branch" "branch gone"
[ -d "$GEMINI_TASKS_DIR/$ID/wt" ] && ok "task worktree kept" || bad "task worktree" "removed"
[ -s "$GEMINI_TASKS_DIR/$ID/tests-after-merge.log" ] \
  && ok "verification log kept" || bad "log" "empty or missing"
check "temporary check worktree removed" "$BEFORE_WT" "$(git -C "$R" worktree list | wc -l)"
contains "audit records the refusal" "rejected_tests_failed" "$(tail -3 "$GEMINI_TASKS_DIR/index.jsonl")"

echo
echo "=== Control: a correct task merges and moves the branch ==="
mkrepo "$R"
FAKE_ACTION=ok bash "$T" run --repo "$R" --slug atomic-ok --test "'$PY' test_calc.py" \
  "correct change" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
ID2="$(task_id_of "$BASEDIR/out.json")"
BEFORE2="$(git -C "$R" rev-parse main)"
set +e
OUT="$(bash "$T" merge "$ID2" --into main --test "'$PY' test_calc.py" 2>&1)"
RC2=$?
set -e
check "merge succeeded" "0" "$RC2"
contains "post-merge tests passed" "post-merge tests: passed" "$OUT"
[ "$BEFORE2" != "$(git -C "$R" rev-parse main)" ] && ok "target branch updated" \
  || bad "merge" "branch unchanged"
[ "$(grep -c 'def mul' "$R/calc.py")" -ge 1 ] && ok "change landed on the target branch" \
  || bad "merge" "change missing"
check "working copy clean after the merge" "" "$(git -C "$R" status --porcelain)"
OUT="$(bash "$T" clean "$ID2" 2>&1)"
contains "task worktree removed after the merge" "worktree removed" "$OUT"

echo
echo "=== Only the --into ref moves, the checked-out branch is untouched ==="
mkrepo "$R"
MAIN_START="$(git -C "$R" rev-parse main)"
git -C "$R" checkout -q -b dev
printf 'DEV\n' > "$R/dev_marker.txt"
git -C "$R" add -A; git -C "$R" commit -qm "work on dev"
DEV_BEFORE="$(git -C "$R" rev-parse dev)"
DEV_FILES="$(git -C "$R" ls-files | tr '\n' ' ')"
FAKE_ACTION=ok bash "$T" run --repo "$R" --base main --slug into-ref --test "'$PY' test_calc.py" \
  "change for main" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
ID3="$(task_id_of "$BASEDIR/out.json")"
set +e
OUT="$(bash "$T" merge "$ID3" --into main --test "'$PY' test_calc.py" 2>&1)"
RC3=$?
set -e
check "merge into a non-checked-out branch succeeded" "0" "$RC3"
[ "$(git -C "$R" rev-parse main)" != "$MAIN_START" ] && ok "main updated" \
  || bad "--into" "main unchanged"
check "checked-out branch dev unchanged" "$DEV_BEFORE" "$(git -C "$R" rev-parse dev)"
check "HEAD still on dev" "dev" "$(git -C "$R" symbolic-ref --short HEAD)"
check "working copy untouched" "" "$(git -C "$R" status --porcelain)"
check "tracked files unchanged" "$DEV_FILES" "$(git -C "$R" ls-files | tr '\n' ' ')"
[ -f "$R/dev_marker.txt" ] && ok "dev branch file still present" || bad "working copy" "dev file gone"
[ "$(grep -c 'def mul' "$R/calc.py")" -eq 0 ] && ok "task change did NOT reach the dev working copy" \
  || bad "working copy" "dev content changed"
git -C "$R" show main:calc.py | grep -q 'def mul' && ok "task change is on main" \
  || bad "--into" "change missing on main"
contains "message names the target branch" "-> main" "$OUT"
contains "message states the working copy was untouched" "was not touched" "$OUT"
LAST="$(tail -1 "$GEMINI_TASKS_DIR/index.jsonl")"
contains "audit names the updated ref" "refs/heads/main" "$LAST"
contains "audit names the target branch" "\"into\": \"main\"" "$LAST"

echo
echo "=== CAS: --into moves during the check ==="
mkrepo "$R"
FAKE_ACTION=ok bash "$T" run --repo "$R" --base main --slug cas-test --test "'$PY' test_calc.py" \
  "change under CAS" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
ID4="$(task_id_of "$BASEDIR/out.json")"
# The verification command runs on the candidate result; here it also advances
# main, simulating concurrent work.
set +e
OUT="$(bash "$T" merge "$ID4" --into main \
  --test "git -C '$R' commit --allow-empty -qm 'concurrent commit on main' && python test_calc.py" 2>&1)"
RC4=$?
set -e
MAIN_AFTER_CAS="$(git -C "$R" rev-parse main)"
[ "$RC4" -ne 0 ] && ok "CAS update rejected with a non-zero code ($RC4)" || bad "CAS" "merge returned 0"
contains "target move is reported" "moved during the check" "$OUT"
check "no merge landed on main" "0" "$(git -C "$R" log main --oneline | grep -c 'Merge branch' || true)"
check "main stayed on the concurrent commit" "$MAIN_AFTER_CAS" "$(git -C "$R" rev-parse main)"
git -C "$R" rev-parse --verify "gemini/cas-test-$ID4" >/dev/null 2>&1 \
  && ok "task branch kept after the CAS refusal" || bad "CAS" "task branch gone"
[ -d "$GEMINI_TASKS_DIR/$ID4/wt" ] && ok "task worktree kept after the CAS refusal" \
  || bad "CAS" "worktree removed"
contains "audit records the target-moved refusal" "rejected_target_moved" "$(tail -2 "$GEMINI_TASKS_DIR/index.jsonl")"
check "temporary check worktree removed" "2" "$(git -C "$R" worktree list | wc -l)"

echo
echo "=== The task branch moved past the verified commit ==="
mkrepo "$R"
FAKE_ACTION=ok bash "$T" run --repo "$R" --slug moved-branch --test "'$PY' test_calc.py"   "change to be amended later" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
ID5="$(task_id_of "$BASEDIR/out.json")"
WT5="$GEMINI_TASKS_DIR/$ID5/wt"
printf 'sneaky
' > "$WT5/sneaky.txt"
git -C "$WT5" add -A
git -C "$WT5" -c user.name=x -c user.email=x@l commit -qm "commit added after the report"
MAIN5="$(git -C "$R" rev-parse main)"
set +e
OUT="$(bash "$T" merge "$ID5" --into main --test "'$PY' test_calc.py" 2>&1)"
RC5=$?
set -e
[ "$RC5" -ne 0 ] && ok "merge refuses a branch that moved past the gate ($RC5)"   || bad "post-gate commit" "merge accepted unverified work"
contains "refusal names the moved branch" "moved past the verified commit" "$OUT"
check "target branch untouched" "$MAIN5" "$(git -C "$R" rev-parse main)"

echo
echo "=== The checked-out branch changes during the check ==="
mkrepo "$R"
FAKE_ACTION=ok bash "$T" run --repo "$R" --base main --slug head-switch --test "'$PY' test_calc.py"   "change while HEAD moves" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
ID6="$(task_id_of "$BASEDIR/out.json")"
MAIN6="$(git -C "$R" rev-parse main)"
set +e
OUT="$(bash "$T" merge "$ID6" --into main   --test "git -C '$R' checkout -q -b side && '$PY' test_calc.py" 2>&1)"
RC6=$?
set -e
[ "$RC6" -ne 0 ] && ok "merge refuses when HEAD switched mid-check ($RC6)"   || bad "HEAD switch" "merge proceeded"
contains "refusal names the branch switch" "checked-out branch changed" "$OUT"
check "main untouched after the HEAD switch" "$MAIN6" "$(git -C "$R" rev-parse main)"
check "side branch untouched" "$MAIN6" "$(git -C "$R" rev-parse side)"
contains "audit records the HEAD refusal" "rejected_head_moved" "$(tail -2 "$GEMINI_TASKS_DIR/index.jsonl")"

echo
echo "=== RESULT [$TEST_ENGINE]: PASS=$PASS FAIL=$FAIL ==="
rm -rf "$BASEDIR"
[ "$FAIL" -eq 0 ]
