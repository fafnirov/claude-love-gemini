---
name: claude-love-gemini
description: Delegate bulk implementation work to the Gemini CLI from Claude Code, with git worktree isolation, a fact-based quality gate and atomic merges. Use for high-volume mechanical work - generating tests, large refactors, routine migrations, analysing a lot of source - where a cheap executor is preferable. Also use when the user says "use Gemini", "delegate this", or asks to run bulk tasks in parallel.
---

# Claude love Gemini

Claude Code is the orchestrator. The Gemini CLI is the executor. Every delegated
task runs in its own git worktree and branch; the main working copy is never
touched.

Entry point: `~/.claude/scripts/gemini-task.sh` (override with `CLC_SCRIPTS`).

## When to delegate here

This engine is for **volume**:

- generating or repairing tests across many files;
- large mechanical refactors;
- routine code migrations;
- analysing large amounts of source.

Do it yourself: planning, architecture, decomposition, one- or two-file edits,
diagnosing a bug, reviewing results, deciding what to accept.

If a sibling project (Claude love Codex) is also installed, prefer this engine
for bulk and the other for work that needs the stronger executor. Never run both
on overlapping files at the same time.

## Rules

- Never run two executors on overlapping files without coordination.
- Never let the executor call Claude Code back. The driver refuses to start when
  `GEMINI_TASK_ACTIVE` is set, but that is a guard, not a sandbox.
- Always pass `--test` for code changes: the quality gate rests on tests.
- Stop after 3 attempts at the same task and diagnose instead of iterating.
- Never return raw logs or whole files to the conversation; report the compact
  result and keep the logs local.
- Never add `--ack` or `--force` on your own to get past a refusal, and never
  pass `-y` / `--yolo` / `--approval-mode=yolo` — they are refused anyway.

## Usage

```bash
# delegate with verification and boundaries
~/.claude/scripts/gemini-task.sh run --repo . --test "pytest -q" \
  --scope "tests/*" "write unit tests for every public function in src/parser.py"

# task contract (goal, allowed_files, forbidden, acceptance, test_command, ...)
~/.claude/scripts/gemini-task.sh run --repo . --task-file task.json

# cross-review of a task, or of any diff
~/.claude/scripts/gemini-task.sh review <task_id> --acceptance "..."
~/.claude/scripts/gemini-task.sh review --repo . --diff my.patch

# merge, always verified; add --test when the task had none
~/.claude/scripts/gemini-task.sh merge <task_id> --into main --test "pytest -q"
~/.claude/scripts/gemini-task.sh clean <task_id>

# housekeeping
~/.claude/scripts/gemini-task.sh doctor | list | show <id> | stats | recover | gc
```

## Reading the result

One compact JSON report: `status`, `changed_files`, `tests`, `risk_level`,
`risks`, `warnings`, `branch`, `commit`.

Statuses: `success`, `needs_review`, `tests_failed`, `tests_not_run`,
`no_changes`, `no_progress`, `failed`, `timeout`, `model_unavailable`,
`blocked`, `budget_exhausted`, `duplicate`, `parallel_limit`.

The status is computed from facts — the exit code, the actual git diff, the test
exit code, risk detection and scope — never from the executor's prose. Check the
diff before telling the user the work is done.

The Gemini CLI reports no token accounting, so every report carries the warning
`token usage unavailable`. Do not invent numbers for it.

## Safety

`merge` refuses on conflicts (even with `--ack`), on a dirty working copy, on
risky changes and on failing or missing required tests. It builds the merge in a
temporary worktree, tests it there, and only then moves the `--into` ref with a
compare-and-swap. `clean` refuses to remove a worktree holding uncommitted work.

The executor can read any file the user can read. Do not delegate on machines
holding production keys.
