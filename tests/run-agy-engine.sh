#!/usr/bin/env bash
# Checks specific to the Antigravity engine: the Google-only model policy, the
# model pinning, and the headless permission denial that returns success while
# changing nothing. Uses the test double, so it costs nothing to run.
set -u
export PYTHONIOENCODING=utf-8

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -n "${CLC_SCRIPTS:-}" ]; then S="$CLC_SCRIPTS"
elif [ -f "$HERE/../scripts/gemini-task.sh" ]; then S="$(cd "$HERE/../scripts" && pwd)"
elif [ -f "$HERE/../gemini-task.sh" ]; then S="$(cd "$HERE/.." && pwd)"
else echo "cannot locate the scripts directory; set CLC_SCRIPTS" >&2; exit 2; fi
PY="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo python)"

T="$S/gemini-task.sh"
RUNNER="$S/agy-run.sh"
BASEDIR="$(mktemp -d "${TMPDIR:-/tmp}/clc-agy-XXXXXX")"
export GEMINI_TASKS_DIR="$BASEDIR/tasks"
export AGY_BIN="$HERE/fake-agy.sh"
export CLC_ENGINE=agy

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1 -- $2"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
contains(){ case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "no [$2] in: $(printf '%s' "$3" | head -c 200)" ;; esac; }
status_of(){ "$PY" -c "import json,sys;print(json.load(open(sys.argv[1],encoding='utf-8')).get('status'))" "$1" 2>/dev/null; }
field_of(){ "$PY" -c "import json,sys;v=json.load(open(sys.argv[1],encoding='utf-8')).get(sys.argv[2]);print(v if not isinstance(v,(list,dict)) else v)" "$1" "$2" 2>/dev/null; }
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

echo "=== Google-only model policy ==="
mkrepo "$R"
OUT="$(AGY_MODEL=claude-sonnet-4-6 bash "$RUNNER" --read --dir "$R" "x" 2>&1)"
contains "a Claude model is refused" "is not a Google model" "$OUT"
contains "the refusal lists Google models" "gemini-3.8-flash" "$OUT"

OUT="$(AGY_MODEL=gpt-oss-120b-medium bash "$RUNNER" --read --dir "$R" "x" 2>&1)"
contains "a GPT-OSS model is refused" "is not a Google model" "$OUT"

OUT="$(AGY_MODEL=gemini-3.8-flash-low bash "$RUNNER" --read --dir "$R" --out "$BASEDIR/a.txt" "x" 2>&1)"
contains "a Google model is accepted" "model=gemini-3.8-flash-low" "$(cat "$BASEDIR/a.txt" 2>/dev/null)"

echo
echo "=== a Google model is pinned when none is given ==="
rm -f "$BASEDIR/b.txt"
bash "$RUNNER" --read --dir "$R" --out "$BASEDIR/b.txt" "x" >/dev/null 2>&1
contains "balanced effort preferred" "model=gemini-3.8-flash-medium" "$(cat "$BASEDIR/b.txt" 2>/dev/null)"

echo
echo "=== the override escape hatch still works ==="
OUT="$(AGY_ALLOW_MODEL_RE='^(gemini|claude)' AGY_MODEL=claude-sonnet-4-6 bash "$RUNNER" --read --dir "$R" --out "$BASEDIR/c.txt" "x" 2>&1)"
contains "an explicit policy override is honoured" "model=claude-sonnet-4-6" "$(cat "$BASEDIR/c.txt" 2>/dev/null)"

echo
echo "=== bypass flags stay refused ==="
OUT="$(bash "$RUNNER" --write --dir "$R" "x" --dangerously-skip-permissions 2>&1)"
contains "--dangerously-skip-permissions refused" "is forbidden" "$OUT"

echo
echo "=== headless permission denial is not reported as success ==="
mkrepo "$R"
FAKE_DENY=1 bash "$T" run --repo "$R" --slug denied --no-require-tests \
  "a task the engine cannot complete" >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
ID="$(task_id_of "$BASEDIR/out.json")"
D="$GEMINI_TASKS_DIR/$ID"
check "engine exit code is zero" "0" "$(field_of "$D/report.json" engine_exit)"
check "but the task is not success" "no_changes" "$(status_of "$D/report.json")"
check "auto-merge refused" "False" "$(field_of "$D/report.json" auto_merge_allowed)"
[ -s "$D/stderr.log" ] && ok "the denial is kept in the log" || bad "denial log" "stderr empty"

echo
echo "=== token accounting survives the wrapper ==="
mkrepo "$R"
FAKE_ACTION=ok bash "$T" run --repo "$R" --slug tokens --no-require-tests "count me" \
  >"$BASEDIR/out.json" 2>"$BASEDIR/err.txt"
ID="$(task_id_of "$BASEDIR/out.json")"
TOK="$("$PY" -c "import json,sys;print((json.load(open(sys.argv[1],encoding='utf-8')).get('token_usage') or {}).get('total_tokens'))" "$GEMINI_TASKS_DIR/$ID/report.json" 2>/dev/null)"
check "total tokens reported" "142" "$TOK"

echo
echo "=== RESULT [agy-engine]: PASS=$PASS FAIL=$FAIL ==="
rm -rf "$BASEDIR"
[ "$FAIL" -eq 0 ]
