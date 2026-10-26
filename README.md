# Claude love Gemini

Claude Code orchestrates. The Gemini CLI executes the bulk work. You write one
task in plain words; Claude decides what to do itself, what to delegate, checks
the real diff and tests, and hands back a single report.

Sister project of [Claude love Codex](https://github.com/fafnirov/claude-love-codex):
same driver, same guarantees, different executor. The point of this one is
**volume** — mechanical refactors, generated tests, routine migrations — on an
engine with a generous free tier, so the expensive executor is kept for the work
that needs it.

```bash
~/.claude/scripts/gemini-task.sh run --repo . --test "pytest -q" \
  --scope "tests/*" "write unit tests for every public function in src/parser.py"
```

```json
{
  "task_id": "20261026-170431-9120-4417",
  "status": "success",
  "changed_files": ["tests/test_parser.py"],
  "tests": { "status": "passed", "exit_code": 0 },
  "risk_level": "none",
  "branch": "gemini/write-unit-tests-20261026-170431-9120-4417",
  "commit": "4f1aa2c…"
}
```

## What it gives you

- **Isolation.** Every task gets its own `task_id`, branch and git worktree. Your
  working copy is never touched.
- **A quality gate based on facts.** Status comes from the exit code, the actual
  `git diff`, the test exit code, risk detection and scope — never from the
  executor's prose.
- **Atomic merges.** The merge is built and tested in a temporary worktree; the
  `--into` ref moves only after the tests pass, with a compare-and-swap. A failing
  post-merge test cannot leave your branch changed.
- **Limits that hold.** 3 attempts per task, a time budget, 2 concurrent
  executors, run timeouts, duplicate and no-progress detection.
- **No bypass flags.** `-y`, `--yolo` and `--approval-mode=yolo` are refused
  before the engine starts. Writes are auto-approved only inside the task
  worktree; shell commands still are not.

## Requirements

- [Claude Code](https://docs.anthropic.com/claude-code)
- [Gemini CLI](https://github.com/google-gemini/gemini-cli): `npm i -g @google/gemini-cli`,
  authenticated with `GEMINI_API_KEY`

> **Signing in with a Google account may not work.** On Gemini CLI 0.65.0 the
> OAuth flow completes at Google and the CLI then refuses it: *"This client is
> no longer supported for Gemini Code Assist for individuals. To continue using
> Gemini, please migrate to the Antigravity suite of products"*. Antigravity is
> a GUI with no headless mode, so it cannot act as an executor. Use an API key
> from [AI Studio](https://aistudio.google.com/) instead — it has a free tier.

- git, Python 3 (`python3` or `python`), bash and GNU `timeout`
  (coreutils; on macOS: `brew install coreutils`)

## Install

```bash
git clone https://github.com/fafnirov/claude-love-gemini.git
cd claude-love-gemini
bash install.sh
~/.claude/scripts/gemini-task.sh doctor
```

The installer copies the scripts and a Claude Code skill into `~/.claude`, and
installs the executor rules into `~/.gemini/GEMINI.md` **only if that file does
not exist yet**. It never touches `settings.json` or your `CLAUDE.md`.

Both projects can be installed side by side: the script names do not collide.

## Use it from a conversation

With the skill installed you do not call anything by hand:

> write unit tests for every public function in src/parser.py and run them

Claude decides whether to delegate. You can steer it: *"use Gemini"*, *"do it
yourself"*, *"run two tasks in parallel"*.

## Commands

| Command | What it does |
|---|---|
| `run` | delegate a task (`--test`, `--scope`, `--task-file`, `--base`, `--timeout`, …) |
| `review` | cross-review a task's diff, or any diff via `--repo/--diff` |
| `merge` | verified atomic merge into `--into` |
| `clean` | remove a task worktree (refuses if it holds uncommitted work) |
| `list` / `show` | audit log and full report |
| `stats` | task counts, durations |
| `recover` | unfinished tasks and orphaned resources |
| `gc` | log rotation (`--days`, `--max-mb`, `--dry-run`) |
| `doctor` | binary, auth, model, paths |

## How the engine is driven

`gemini-run.sh` does not assume flags. It reads `gemini --help` once, caches the
result, and adapts:

- non-interactive prompt flag — required;
- `--approval-mode` — required. `--read` maps to `default` (nothing is approved
  automatically), `--write` maps to `auto_edit` (file edits inside the task
  worktree only). If the installed build has no approval control, the wrapper
  **refuses to run** rather than falling back to `--yolo`.

The Gemini CLI reports no token accounting, so reports carry the warning
`token usage unavailable` instead of invented numbers.

## Security — read this

The executor runs with your account's privileges. Read
[docs/SECURITY.md](docs/SECURITY.md) before using this on a machine that holds
production keys or sensitive data.

## Self-check

The suites use a test double instead of the model, so they cost nothing:

```bash
bash tests/run-tests.sh          # detector, limits, merge gates, parallelism
bash tests/run-lifecycle.sh      # interrupts, orphans, recovery, rotation
bash tests/run-merge-atomic.sh   # merge atomicity and ref updates
```

See [docs/VERIFICATION.md](docs/VERIFICATION.md) for what is verified and what
is not — including the parts that have **not** yet been run against a live
Gemini CLI.

## Russian documentation

[README.ru.md](README.ru.md)

## License

MIT
