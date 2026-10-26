#!/usr/bin/env bash
# Test double for the Gemini CLI: exercises the whole delegation pipeline
# without calling a model. Injected through GEMINI_BIN. Controlled by env:
#   FAKE_ACTION  ok | nochange | selfcommit | prefix | env | secret | sql | rmrf |
#                symlink | binary | rename | hidden | deltest | outside |
#                breaktest | breakmain
#   FAKE_EXIT    exit code (default 0)
#   FAKE_SLEEP   delay in seconds (for timeout tests)
#   FAKE_ANSWER  text | empty   (what the engine prints as its final answer)
set -u

# The wrapper probes capabilities with --help, so the double must answer it.
for a in "$@"; do
  if [ "$a" = "--help" ]; then
    cat <<'HELP'
Usage: gemini [options]

Options:
  -p, --prompt            Run non-interactively with the given prompt
  -m, --model             Model to use
      --approval-mode     Approval mode: default | auto_edit | yolo
  -y, --yolo              Auto-approve everything
HELP
    exit 0
  fi
done

ACTION="${FAKE_ACTION:-ok}"
EXITC="${FAKE_EXIT:-0}"
SLEEP="${FAKE_SLEEP:-0}"
ANSWER="${FAKE_ANSWER:-text}"

# The wrapper runs us with the worktree as the working directory.
[ "$SLEEP" != "0" ] && sleep "$SLEEP"

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
  prefix)
    printf 'backup\n' > calc.py.bak
    ;;
  env)
    printf 'DB_PASSWORD=supersecret123\n' > .env
    ;;
  secret)
    printf 'API_KEY = "sk-abcdefghijklmnopqrstuvwx"\n' >> config.py
    ;;
  sql)
    mkdir -p migrations
    printf 'DROP TABLE users;\n' > migrations/002_drop.sql
    ;;
  rmrf)
    printf '#!/bin/sh\nrm -rf /var/data\n' > cleanup.sh
    ;;
  symlink)
    printf 'import os\nos.symlink("/etc/passwd", "link")\n' >> tool.py
    ;;
  binary)
    printf '\x00\x01\x02\x03binary\x00' > blob.bin
    ;;
  rename)
    git mv calc.py calculator.py 2>/dev/null || mv calc.py calculator.py
    ;;
  hidden)
    printf '# comment\n' >> README.md
    printf 'def helper():\n    return 1\n' >> calc.py
    mkdir -p migrations
    printf 'TRUNCATE TABLE audit_log;\n' > migrations/003_truncate.sql
    printf '# another harmless edit\n' >> README.md
    ;;
  deltest)
    printf 'from calc import add\n\nassert add(1, 1) == 2\n' > test_calc.py
    ;;
  outside)
    printf 'tool\n' > tool.py
    ;;
  breaktest)
    printf '\ndef mul(a, b):\n    return a + b\n' >> calc.py
    printf 'from calc import add, mul\n\nassert add(2, 3) == 5\nassert mul(3, 4) == 12\nprint("ok")\n' > test_calc.py
    ;;
  breakmain)
    printf 'def add(a, b):\n    return a - b\n' > calc.py
    ;;
esac

if [ "$ANSWER" = "text" ]; then
  echo "done (double)"
fi
exit "$EXITC"
