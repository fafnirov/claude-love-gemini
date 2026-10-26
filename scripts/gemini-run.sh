#!/usr/bin/env bash
# Thin wrapper around the Gemini CLI, with the same contract the driver expects
# from any engine:
#
#   gemini-run.sh [--read|--write] [--dir DIR] [--out FILE] [--json] "task"
#
#   --read   analysis only, the model must not edit files
#   --write  edits inside DIR are auto-approved; shell commands still are not
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
    read)  PASS+=(--approval-mode default) ;;
    write) PASS+=(--approval-mode auto_edit) ;;
    *) echo "gemini-run: mode must be read or write (got: $MODE)" >&2; exit 2 ;;
  esac
else
  # Without approval control a write task would stall on the first prompt and a
  # read task would have no enforcement at all. Refuse rather than guess.
  echo "gemini-run: this build has no --approval-mode; refusing to run unattended" >&2
  echo "            help output cached at: $CACHE" >&2
  exit 3
fi

[ -n "${GEMINI_MODEL:-}" ] && has "--model" && PASS+=(-m "$GEMINI_MODEL")

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

[ -n "$OUT" ] && cp "$RAW" "$OUT"
cat "$RAW.err" >&2

# one JSONL event so the driver parses every engine the same way
"$PY" - "$RAW" <<'PYEOF'
import json, sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").strip()
print(json.dumps({"type": "item.completed",
                  "item": {"type": "agent_message", "text": text}},
                 ensure_ascii=False))
PYEOF

rm -f "$RAW" "$RAW.err"
exit $RC
