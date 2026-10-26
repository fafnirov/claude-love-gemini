#!/usr/bin/env bash
# Thin wrapper around the Antigravity CLI (agy), with the same contract the
# driver expects from any engine:
#
#   agy-run.sh [--read|--write] [--dir DIR] [--out FILE] [--json] "task"
#
#   --read   --mode plan: the CLI's own read-only mode
#   --write  --mode accept-edits: file edits approved, other tools still prompt
#
# This engine authenticates with the signed-in Google account, so no API key is
# involved. --dangerously-skip-permissions and --mode auto are refused.
#
# stdout carries one JSONL event with the final message, so the driver's report
# builder works the same for every engine. The final text also goes to --out.
#
# Flags are not assumed: the wrapper reads `gemini --help` once and adapts. If a
# required capability is missing it fails loudly instead of falling back to
# something less safe.
#
# Environment: AGY_BIN, AGY_MODE, AGY_DIR, AGY_MODEL, AGY_EFFORT
set -euo pipefail

MODE="${AGY_MODE:-write}"
DIR="${AGY_DIR:-$PWD}"
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
BIN="${AGY_BIN:-}"
if [ -z "$BIN" ]; then
  if command -v agy >/dev/null 2>&1; then
    BIN="$(command -v agy)"
  else
    LA="${LOCALAPPDATA:-${USERPROFILE:-$HOME}/AppData/Local}"
    command -v cygpath >/dev/null 2>&1 && LA="$(cygpath -u "$LA")"
    for c in "$LA/agy/bin/agy.exe" "$HOME/.local/bin/agy" "/usr/local/bin/agy"; do
      [ -f "$c" ] && { BIN="$c"; break; }
    done
  fi
fi
if [ -z "$BIN" ]; then
  echo "agy-run: Antigravity CLI not found. Install it, or set AGY_BIN." >&2
  exit 127
fi
if [ ! -f "$BIN" ] && ! command -v "$BIN" >/dev/null 2>&1; then
  echo "agy-run: the given binary does not exist: $BIN" >&2
  exit 127
fi

# --- never let a bypass flag through -------------------------------------
for a in "$@"; do
  case "$a" in
    --dangerously-skip-permissions|--mode=auto)
      echo "agy-run: flag $a is forbidden — it auto-approves every tool call" >&2
      exit 2 ;;
  esac
done

# --- detect what this build supports (cached per binary) ------------------
CACHE="${TMPDIR:-/tmp}/gemini-run-caps-$("$PY" -c "import hashlib,sys;print(hashlib.sha1(sys.argv[1].encode()).hexdigest()[:12])" "$BIN")"
if [ ! -s "$CACHE" ]; then
  "$BIN" --help > "$CACHE" 2>&1 || true
fi
has() { grep -q -- "$1" "$CACHE" 2>/dev/null; }

if has -- "--print" || has -- "--prompt"; then PROMPT_FLAG="-p"; else
  echo "agy-run: this build has no non-interactive prompt flag; see: $CACHE" >&2
  exit 3
fi

if has -- "--mode"; then
  case "$MODE" in
    read)  PASS+=(--mode plan) ;;
    write) PASS+=(--mode accept-edits) ;;
    *) echo "agy-run: mode must be read or write (got: $MODE)" >&2; exit 2 ;;
  esac
else
  # Without approval control a write task would stall on the first prompt and a
  # read task would have no enforcement at all. Refuse rather than guess.
  echo "agy-run: this build has no --mode; refusing to run unattended" >&2
  echo "            help output cached at: $CACHE" >&2
  exit 3
fi

# --- Google models only -------------------------------------------------
# The Antigravity CLI also offers Claude and GPT-OSS models. This project is
# the Google side of the pair, so anything else is refused rather than silently
# used. The Codex project is where another vendor's model belongs.
AGY_ALLOW_MODEL_RE="${AGY_ALLOW_MODEL_RE:-^(gemini|gemma)}"
if [ -n "${AGY_MODEL:-}" ]; then
  if ! printf '%s' "$AGY_MODEL" | grep -Eq "$AGY_ALLOW_MODEL_RE"; then
    echo "agy-run: model '$AGY_MODEL' is not a Google model — this project runs Gemini only." >&2
    echo "         Available Google models: $("$BIN" models 2>/dev/null | grep -Eo '^(gemini|gemma)[^[:space:]]*' | tr '
' ' ')" >&2
    exit 2
  fi
  has -- "--model" && PASS+=(--model "$AGY_MODEL")
elif has -- "--model"; then
  # pin a Google model explicitly: the CLI default could change to another vendor
  MCACHE="${TMPDIR:-/tmp}/agy-google-model"
  if [ ! -s "$MCACHE" ]; then
    # prefer a balanced effort level for bulk work, then whatever Google model exists
    "$BIN" models 2>/dev/null | grep -Eo '^(gemini|gemma)[^[:space:]]*' > "$MCACHE.all" || true
    { grep -m1 -- "-medium$" "$MCACHE.all"       || grep -m1 -- "-low$" "$MCACHE.all"       || head -1 "$MCACHE.all"; } > "$MCACHE" 2>/dev/null || true
    rm -f "$MCACHE.all"
  fi
  PINNED="$(cat "$MCACHE" 2>/dev/null)"
  [ -n "$PINNED" ] && PASS+=(--model "$PINNED")
fi
[ -n "${AGY_EFFORT:-}" ] && has -- "--effort" && PASS+=(--effort "$AGY_EFFORT")
# structured output when the build offers it: the final text is easier to
# recover and errors stay machine-readable
JSON_OUT=0
if has -- "--output-format"; then PASS+=(--output-format json); JSON_OUT=1; fi

PROMPT="${1:-}"
if [ -z "$PROMPT" ] || [ "$PROMPT" = "-" ]; then
  PROMPT="$(cat)"
fi
if [ "$MODE" = "read" ]; then
  PROMPT="Read-only task. Do not modify, create or delete any file; report findings only.

$PROMPT"
else
  # Verified: in headless mode accept-edits approves edit tools only. A shell
  # command is auto-denied ("a tool required the command permission that
  # headless mode cannot prompt for"), and the turn ends having changed
  # nothing. So the task must be done with edit tools.
  PROMPT="Apply the changes by editing files directly with your file-editing tools.
Do not run shell commands, tests or git: command execution is denied in this
session and the turn will end without changes. Verification happens outside.

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
        # verified shape: usage.{input_tokens,output_tokens,thinking_tokens,
        # cache_read_tokens,total_tokens}; Gemini CLI nests it under stats.models
        st = d.get("usage") or d.get("stats") or {}
        if isinstance(st, dict):
            acc = {}
            models = st.get("models")
            if isinstance(models, dict):
                for m in models.values():
                    tok = (m or {}).get("tokens") or {}
                    for src, dst in (("input", "input_tokens"),
                                     ("prompt", "input_tokens"),
                                     ("candidates", "output_tokens"),
                                     ("total", "total_tokens"),
                                     ("cached", "cached_input_tokens"),
                                     ("thoughts", "reasoning_tokens")):
                        v = tok.get(src)
                        if isinstance(v, int) and v:
                            acc[dst] = acc.get(dst, 0) + v
            if not acc:
                acc = {k: v for k, v in st.items() if isinstance(v, int)}
            usage = acc or None
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
