#!/usr/bin/env bash
# Thin wrapper around the Gemini CLI, with the same contract the driver expects
# from any engine:
#
#   gemini-run.sh [--read|--write] [--dir DIR] [--out FILE] [--json] "task"
#
#   --read   --approval-mode plan: the CLI's own read-only mode
#   --write  --approval-mode auto_edit: edits auto-approved, shell commands not
#
# stdout carries one JSONL event with the final message, so the driver's report
# builder works the same for every engine. The final text also goes to --out.
#
# Flags are not assumed: the wrapper reads `gemini --help` once and adapts. If a
# required capability is missing it fails loudly instead of falling back to
# something less safe.
#
# Environment: GEMINI_BIN, GEMINI_MODE, GEMINI_DIR, GEMINI_MODEL
set -euo pipefail

MODE="${GEMINI_MODE:-write}"
DIR="${GEMINI_DIR:-$PWD}"
OUT=""
PASS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --read|--write) MODE="${1#--}"; shift ;;
    --dir)  DIR="$2"; shift 2 ;;
    --out)  OUT="$2"; shift 2 ;;
    --json) shift ;;                 # accepted for symmetry; see the note above
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

PY="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo python)"

# --- locate the binary ---------------------------------------------------
BIN="${GEMINI_BIN:-}"
if [ -z "$BIN" ]; then
  if command -v gemini >/dev/null 2>&1; then
    BIN="$(command -v gemini)"
  else
    for c in "$APPDATA/npm/gemini.cmd" "$HOME/.npm-global/bin/gemini" \
             "/usr/local/bin/gemini" "$HOME/.local/bin/gemini"; do
      [ -f "$c" ] && { BIN="$c"; break; }
    done
  fi
fi
if [ -z "$BIN" ]; then
  echo "gemini-run: Gemini CLI not found. Install it (npm i -g @google/gemini-cli) or set GEMINI_BIN." >&2
  exit 127
fi
if [ ! -f "$BIN" ] && ! command -v "$BIN" >/dev/null 2>&1; then
  echo "gemini-run: the given binary does not exist: $BIN" >&2
  exit 127
fi

# --- never let a bypass flag through -------------------------------------
for a in "$@"; do
  case "$a" in
    -y|--yolo|--approval-mode=yolo)
      echo "gemini-run: flag $a is forbidden — it auto-approves everything" >&2
      exit 2 ;;
  esac
done

# --- detect what this build supports (cached per binary) ------------------
CACHE="${TMPDIR:-/tmp}/gemini-run-caps-$("$PY" -c "import hashlib,sys;print(hashlib.sha1(sys.argv[1].encode()).hexdigest()[:12])" "$BIN")"
if [ ! -s "$CACHE" ]; then
  "$BIN" --help > "$CACHE" 2>&1 || true
fi
has() { grep -q -- "$1" "$CACHE" 2>/dev/null; }

if has "--prompt" || has " -p "; then PROMPT_FLAG="-p"; else
  echo "gemini-run: this build has no non-interactive prompt flag; see: $CACHE" >&2
  exit 3
fi

if has "--approval-mode"; then
  case "$MODE" in
    read)  if has "plan"; then PASS+=(--approval-mode plan); else PASS+=(--approval-mode default); fi ;;
    write) PASS+=(--approval-mode auto_edit) ;;
    *) echo "gemini-run: mode must be read or write (got: $MODE)" >&2; exit 2 ;;
  esac
  # Verified behaviour: in an untrusted folder the CLI silently downgrades the
  # approval mode to "default", which would stall an unattended run. The task
  # worktree is created by the driver from the user's own repository, so
  # trusting it for this session is what makes the requested mode stick.
  if has -- "--skip-trust"; then
    PASS+=(--skip-trust)
  else
    echo "gemini-run: this build has no --skip-trust; the approval mode may be downgraded" >&2
  fi
else
  # Without approval control a write task would stall on the first prompt and a
  # read task would have no enforcement at all. Refuse rather than guess.
  echo "gemini-run: this build has no --approval-mode; refusing to run unattended" >&2
  echo "            help output cached at: $CACHE" >&2
  exit 3
fi

[ -n "${GEMINI_MODEL:-}" ] && has "--model" && PASS+=(-m "$GEMINI_MODEL")
# structured output when the build offers it: the final text is easier to
# recover and errors stay machine-readable
JSON_OUT=0
if has -- "--output-format"; then PASS+=(-o json); JSON_OUT=1; fi

PROMPT="${1:-}"
if [ -z "$PROMPT" ] || [ "$PROMPT" = "-" ]; then
  PROMPT="$(cat)"
fi
if [ "$MODE" = "read" ]; then
  PROMPT="Read-only task. Do not modify, create or delete any file; report findings only.

$PROMPT"
fi

# --- run ------------------------------------------------------------------
RAW="$(mktemp "${TMPDIR:-/tmp}/gemini-run-XXXXXX")"
set +e
( cd "$DIR" && "$BIN" "${PASS[@]}" "$PROMPT_FLAG" "$PROMPT" ) > "$RAW" 2>"$RAW.err" < /dev/null
RC=$?
set -e

cat "$RAW.err" >&2

# one JSONL event so the driver parses every engine the same way
"$PY" - "$RAW" "${OUT:-}" <<'PYEOF'
import json, sys, pathlib

raw = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").strip()
out = sys.argv[2] if len(sys.argv) > 2 else ""
text, usage = raw, None

# -o json wraps the answer; fall back to the raw text for other builds
try:
    d = json.loads(raw)
    if isinstance(d, dict):
        text = d.get("response") or d.get("text") or d.get("output") or raw
        st = d.get("stats") or d.get("usage") or {}
        if isinstance(st, dict):
            usage = {k: v for k, v in st.items() if isinstance(v, int)}
except Exception:
    pass

if out:
    pathlib.Path(out).write_text(text, encoding="utf-8")

ev = {"type": "item.completed", "item": {"type": "agent_message", "text": text}}
if usage:
    ev["usage"] = usage
print(json.dumps(ev, ensure_ascii=False))
PYEOF

rm -f "$RAW" "$RAW.err"
exit $RC
