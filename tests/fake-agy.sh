#!/usr/bin/env bash
# Test double for the Antigravity CLI (agy): exercises the whole delegation
# pipeline without calling a model. Injected through AGY_BIN. Controlled by the
# same environment variables as the Gemini double:
#   FAKE_ACTION  ok | nochange | selfcommit | prefix | env | secret | sql | rmrf |
#                symlink | binary | rename | hidden | deltest | outside |
#                breaktest | breakmain
#   FAKE_EXIT    exit code (default 0)
#   FAKE_SLEEP   delay in seconds (for timeout tests)
#   FAKE_ANSWER  text | empty   (what the engine prints as its final answer)
#   FAKE_DENY    1 = report a denied shell command and change nothing, the way
#                headless accept-edits behaves when a tool needs the command
#                permission
set -u

# The wrapper probes capabilities with --help, so the double must answer it the
# way agy 1.4.7 does.
for a in "$@"; do
  if [ "$a" = "--help" ]; then
    cat <<'HELP'
Usage of agy.exe:
  --add-dir                       Add a directory to the workspace (repeatable)
  --dangerously-skip-permissions  Auto-approve all tool permission requests without prompting
  --effort                        Reasoning effort for the current CLI session (low|medium|high|xhigh|max)
  --mode                          Set the agent execution mode for this session (accept-edits, auto, plan)
  --model                         Model for the current CLI session
  --output-format                 Output format for print mode (text, json, stream-json) (default text)
  -p                              Short alias for --print
  --print                         Run a single prompt non-interactively and print the response
  --prompt                        Alias for --print
  --sandbox                       Run in a sandbox with terminal restrictions enabled

Available subcommands:
  models          List available models
HELP
    exit 0
  fi
done

# `agy models` — the wrapper reads this to pin a Google model
if [ "${1:-}" = "models" ]; then
  cat <<'MODELS'
gemini-3.8-flash-high	Gemini 3.8 Flash (High)
gemini-3.8-flash-medium	Gemini 3.8 Flash (Medium)
gemini-3.8-flash-low	Gemini 3.8 Flash (Low)
claude-sonnet-4-6	Claude Sonnet 4.6 (Thinking)
gpt-oss-120b-medium	GPT-OSS 120B (Medium)
MODELS
  exit 0
fi

ACTION="${FAKE_ACTION:-ok}"
EXITC="${FAKE_EXIT:-0}"
SLEEP="${FAKE_SLEEP:-0}"
ANSWER="${FAKE_ANSWER:-text}"
DENY="${FAKE_DENY:-0}"

MODEL="unset"
JSON_OUT=0
prev=""
for a in "$@"; do
  case "$prev" in
    --model) MODEL="$a" ;;
    --output-format) [ "$a" = "json" ] && JSON_OUT=1 ;;
  esac
  prev="$a"
done

[ "$SLEEP" != "0" ] && sleep "$SLEEP"

# The wrapper runs us with the task worktree as the working directory.
if [ "$DENY" != "1" ]; then
  case "$ACTION" in
    ok)
      printf '\ndef mul(a, b):\n    return a * b\n' >> calc.py
      printf 'from calc import add, mul\n\nassert add(2, 3) == 5\nassert mul(3, 4) == 12\nprint("ok")\n' > test_calc.py
      ;;
    nochange) : ;;
    selfcommit)
      printf '\ndef mul(a, b):\n    return a * b\n' >> calc.py
      git -c user.name=exec -c user.email=exec@local commit -qam "executor commit" 2>/dev/null
      ;;
    prefix)   printf 'backup\n' > calc.py.bak ;;
    env)      printf 'DB_PASSWORD=supersecret123\n' > .env ;;
    secret)   printf 'API_KEY = "sk-abcdefghijklmnopqrstuvwx"\n' >> config.py ;;
    sql)      mkdir -p migrations; printf 'DROP TABLE users;\n' > migrations/002_drop.sql ;;
    rmrf)     printf '#!/bin/sh\nrm -rf /var/data\n' > cleanup.sh ;;
    symlink)  printf 'import os\nos.symlink("/etc/passwd", "link")\n' >> tool.py ;;
    binary)   printf '\x00\x01\x02\x03binary\x00' > blob.bin ;;
    rename)   git mv calc.py calculator.py 2>/dev/null || mv calc.py calculator.py ;;
    hidden)
      printf '# comment\n' >> README.md
      printf 'def helper():\n    return 1\n' >> calc.py
      mkdir -p migrations
      printf 'TRUNCATE TABLE audit_log;\n' > migrations/003_truncate.sql
      printf '# another harmless edit\n' >> README.md
      ;;
    deltest)  printf 'from calc import add\n\nassert add(1, 1) == 2\n' > test_calc.py ;;
    outside)  printf 'tool\n' > tool.py ;;
    breaktest)
      printf '\ndef mul(a, b):\n    return a + b\n' >> calc.py
      printf 'from calc import add, mul\n\nassert add(2, 3) == 5\nassert mul(3, 4) == 12\nprint("ok")\n' > test_calc.py
      ;;
    breakmain) printf 'def add(a, b):\n    return a - b\n' > calc.py ;;
  esac
fi

if [ "$ANSWER" = "empty" ] && [ "$DENY" != "1" ]; then
  exit "$EXITC"
fi

if [ "$JSON_OUT" -eq 1 ]; then
  if [ "$DENY" = "1" ]; then
    # exactly what agy reports when a tool needs the command permission
    printf '{"conversation_id":"fake-1","status":"SUCCESS","response":"","duration_seconds":1.0,"num_turns":1,"usage":{"input_tokens":111,"output_tokens":22,"thinking_tokens":9,"cache_read_tokens":0,"total_tokens":142},"denied_actions":[{"action":"command","display_name":"RunCommand"}]}\n'
    echo 'jetski: no output produced - a tool required the "command" permission that headless mode cannot prompt for, so it was auto-denied.' >&2
  else
    printf '{"conversation_id":"fake-1","status":"SUCCESS","response":"done (double, model=%s)","duration_seconds":1.0,"num_turns":1,"usage":{"input_tokens":111,"output_tokens":22,"thinking_tokens":9,"cache_read_tokens":0,"total_tokens":142}}\n' "$MODEL"
  fi
else
  echo "done (double, model=$MODEL)"
fi

exit "$EXITC"
