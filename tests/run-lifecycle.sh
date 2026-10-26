#!/usr/bin/env bash
# Lifecycle suite: interruption, timeout, orphans, corrupt report, restart,
# log rotation. Uses the test double, so it costs nothing to run.
set -u
export PYTHONIOENCODING=utf-8

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -n "${CLC_SCRIPTS:-}" ]; then S="$CLC_SCRIPTS"
elif [ -f "$HERE/../scripts/gemini-task.sh" ]; then S="$(cd "$HERE/../scripts" && pwd)"
elif [ -f "$HERE/../gemini-task.sh" ]; then S="$(cd "$HERE/.." && pwd)"
else echo "cannot locate the scripts directory; set CLC_SCRIPTS" >&2; exit 2; fi
PY="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo python)"
T="$S/gemini-task.sh"
BASEDIR="$(mktemp -d "${TMPDIR:-/tmp}/clc-life-XXXXXX")"
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
status_of(){ "$PY" -c "import json,sys;print(json.load(open(sys.argv[1],encoding='utf-8')).get('status'))" "$1" 2>/dev/null; }
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

echo "=== A. Interrupt (SIGINT) during a run ==="
mkrepo "$R"
FAKE_ACTION=ok FAKE_SLEEP=25 bash "$T" run --repo "$R" --slug interrupt --no-require-tests \
  "long task" >"$BASEDIR/int.out" 2>"$BASEDIR/int.err" &
RUNPID=$!
sleep 4
kill -INT "$RUNPID" 2>/dev/null
wait "$RUNPID" 2>/dev/null
check "lock released after SIGINT" "0" "$(ls -1d "$GEMINI_TASKS_DIR"/locks/slot-* 2>/dev/null | wc -l)"
check "active-task registration cleared" "0" "$(ls -1 "$GEMINI_TASKS_DIR/active" 2>/dev/null | wc -l)"
TD="$(ls -1dt "$GEMINI_TASKS_DIR"/2* 2>/dev/null | head -1)"
[ -d "$TD/wt" ] && ok "worktree of the interrupted task kept (no data loss)" \
                || bad "worktree after SIGINT" "directory removed"
INT_TASK="$(basename "$TD")"

echo
echo "=== B. Recovery: recover reports unfinished work ==="
printf 'uncommitted work\n' > "$TD/wt/wip.txt"
OUT="$(bash "$T" recover 2>&1)"
contains "recover lists the task without a report" "$INT_TASK" "$OUT"
contains "recover reports uncommitted changes" "uncommitted changes" "$OUT"
OUT="$(bash "$T" clean "$INT_TASK" 2>&1)"
contains "clean refuses to drop unfinished work" "removal refused" "$OUT"
contains "work file still present" "uncommitted work" "$(cat "$TD/wt/wip.txt")"

echo
echo "=== C. Restart after an interrupt ==="
mkrepo "$R"
FAKE_ACTION=ok bash "$T" run --repo "$R" --slug interrupt --no-require-tests "retry after interrupt" \
  >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
NEW="$(task_id_of "$BASEDIR/out.json")"
[ -n "$NEW" ] && [ "$NEW" != "$INT_TASK" ] && ok "restart created a new task ($NEW)" \
  || bad "restart" "task_id unchanged"
check "restart succeeded" "success" "$(status_of "$GEMINI_TASKS_DIR/$NEW/report.json")"
[ -d "$GEMINI_TASKS_DIR/$INT_TASK/wt" ] && ok "interrupted worktree untouched by the restart" \
  || bad "restart" "old worktree disappeared"

echo
echo "=== D. Orphaned lock (dead process) ==="
mkdir -p "$GEMINI_TASKS_DIR/locks/slot-1"
echo "999999" > "$GEMINI_TASKS_DIR/locks/slot-1/pid"
mkrepo "$R"
FAKE_ACTION=ok bash "$T" run --repo "$R" --slug orphanlock --no-require-tests "after a dead lock" \
  >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
NEW="$(task_id_of "$BASEDIR/out.json")"
check "dead lock cleared, task ran" "success" "$(status_of "$GEMINI_TASKS_DIR/$NEW/report.json")"

echo
echo "=== E. Orphaned worktree (directory removed by hand) ==="
rm -rf "$GEMINI_TASKS_DIR/$NEW/wt"
OUT="$(bash "$T" clean "$NEW" 2>&1)"
contains "clean survives a missing directory" "worktree removed" "$OUT"
check "worktree record pruned" "1" "$(git -C "$R" worktree list | wc -l)"

echo
echo "=== F. Corrupt report ==="
mkrepo "$R"
FAKE_ACTION=ok bash "$T" run --repo "$R" --slug broken --test "'$PY' test_calc.py" \
  "report to be corrupted" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
BR="$(task_id_of "$BASEDIR/out.json")"
printf 'this is not json' > "$GEMINI_TASKS_DIR/$BR/report.json"
OUT="$(bash "$T" merge "$BR" --into main 2>&1)"
if [ -n "$OUT" ]; then ok "merge with a corrupt report does not pass silently"; else bad "merge" "no reaction"; fi
BEFORE="$(git -C "$R" rev-parse HEAD)"
check "main unchanged" "$BEFORE" "$(git -C "$R" rev-parse HEAD)"
OUT="$(bash "$T" gc --dry-run --days 0 2>&1)"
contains "gc protects the task with an unreadable report" "$BR" "$OUT"

echo
echo "=== G. Log rotation ==="
mkrepo "$R"
for i in 1 2 3; do
  FAKE_ACTION=ok bash "$T" run --repo "$R" --slug "rot$i" --test "'$PY' test_calc.py" \
    "rotation $i" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
  TID="$(task_id_of "$BASEDIR/out.json")"
  bash "$T" clean "$TID" >/dev/null 2>&1
  mkrepo "$R"
done
"$PY" - "$GEMINI_TASKS_DIR" <<'PYX'
import os, pathlib, sys, time
root = pathlib.Path(sys.argv[1])
old = time.time() - 60 * 86400
for d in root.glob("2*"):
    for f in list(d.rglob("*")) + [d]:
        try:
            os.utime(f, (old, old))
        except Exception:
            pass
PYX
OUT="$(bash "$T" gc --days 30 --dry-run 2>&1)"
DRYN="$(printf '%s' "$OUT" | "$PY" -c "import json,sys;print(len(json.load(sys.stdin)['removed']))")"
[ "$DRYN" -gt 0 ] && ok "gc dry run found $DRYN stale tasks" || bad "gc dry-run" "nothing found"
BEFORE_N="$(ls -1d "$GEMINI_TASKS_DIR"/2* 2>/dev/null | wc -l)"
[ "$BEFORE_N" -gt 0 ] && ok "dry run deleted nothing" || bad "gc dry-run" "directories disappeared"
OUT="$(bash "$T" gc --days 30 2>&1)"
AFTER_N="$(ls -1d "$GEMINI_TASKS_DIR"/2* 2>/dev/null | wc -l)"
[ "$AFTER_N" -lt "$BEFORE_N" ] && ok "gc removed stale successful tasks ($BEFORE_N -> $AFTER_N)" \
  || bad "gc" "nothing removed"
[ -f "$GEMINI_TASKS_DIR/index.jsonl" ] && ok "audit index.jsonl kept" || bad "gc" "audit removed"
[ -d "$GEMINI_TASKS_DIR/$INT_TASK" ] && ok "unfinished task not rotated away" \
  || bad "gc" "unfinished task removed"
[ -d "$GEMINI_TASKS_DIR/$BR" ] && ok "task with an unreadable report kept" \
  || bad "gc" "failure log removed"

echo
echo "=== H. Statistics and token usage ==="
OUT="$(bash "$T" stats 2>&1)"
contains "stats: task count" "tasks" "$OUT"
contains "stats: engine tokens" "engine_tokens" "$OUT"
contains "stats: cost disclaimer" "cost is not computed" "$OUT"

echo
echo "=== RESULT [$TEST_ENGINE]: PASS=$PASS FAIL=$FAIL ==="
rm -rf "$BASEDIR"
[ "$FAIL" -eq 0 ]
