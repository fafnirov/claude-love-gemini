# Verification

What was actually run, and what was not.

## Automated suites — passing

The suites replace the Gemini binary with a test double, so they cost nothing
and are deterministic. They exercise the driver, not the model.

| Suite | Checks | Result |
|---|---|---|
| `tests/run-tests.sh` | risk detector on real git diffs, scope, executor self-commits, test states, CLI modes, limits, parallelism, merge gates, audit | 96 / 96 |
| `tests/run-lifecycle.sh` | SIGINT, timeout, orphaned lock, orphaned worktree, corrupt report, restart, log rotation, stats | 25 / 25 |
| `tests/run-merge-atomic.sh` | failing post-merge tests, ref targeting, compare-and-swap, branch moved past the gate, HEAD switched mid-check, control cases | 47 / 47 |

```bash
env -u PYTHONDONTWRITEBYTECODE bash tests/run-tests.sh
env -u PYTHONDONTWRITEBYTECODE bash tests/run-lifecycle.sh
env -u PYTHONDONTWRITEBYTECODE bash tests/run-merge-atomic.sh
```

The double answers `--help` with the flags the wrapper probes for, so the
capability detection in `gemini-run.sh` is exercised too.

## Verified against the real binary (contracts)

Gemini CLI **0.65.0** installed and its `--help` captured verbatim. The wrapper
no longer rests on assumptions:

| Contract | Fact |
|---|---|
| non-interactive | `-p, --prompt` |
| approval control | `--approval-mode` with choices `default`, `auto_edit`, `yolo`, `plan` |
| read-only mode | `plan` — the wrapper's `--read` maps to it |
| write mode | `auto_edit` — edit tools auto-approved, shell commands not |
| structured output | `-o, --output-format` with `text`, `json`, `stream-json` |
| container sandbox | `-s, --sandbox` |
| model | `-m, --model` |
| forbidden | `-y, --yolo` and `--approval-mode=yolo`, refused by driver and wrapper |

**Caught by this check:** in a folder the CLI does not trust it silently
downgrades the requested approval mode — *"Approval mode overridden to
\"default\" because the current folder is not trusted"*. An unattended
`auto_edit` run would have stalled waiting for approval. The wrapper now passes
`--skip-trust` for the task worktree, which the driver creates from the user's
own repository, and warns if the build does not support it.

Also observed: with `-o json` the CLI writes its payload to **stderr** on
failure and leaves stdout empty; the exit code was `41` for a missing auth
method. The wrapper copies stdout to the answer file and passes stderr through,
so such a failure surfaces as a non-zero status with the error text in the
report rather than as a silent success.

The test double now mirrors this exact help text, so capability detection is
exercised against realistic input.

## NOT verified against a live Gemini CLI

**This is the honest state of the project.** The driver is inherited from
[Claude love Codex](https://github.com/fafnirov/claude-love-codex), where it was
verified end to end against a real executor: parallel delegation, conflict
refusal, cross-review in both directions, atomic merges, 168 automated checks.
What is new here — the engine wrapper — has **not** yet run against a real
`gemini` binary.

**Observed while trying to authenticate:** the "Sign in with Google" path of
Gemini CLI 0.65.0 is closed for individual accounts. Google's own OAuth page
reports success, then the CLI reports *"This client is no longer supported for
Gemini Code Assist for individuals. To continue using Gemini, please migrate to
the Antigravity suite of products"*. Antigravity ships no headless entry point
(its only binary launches the Electron app), so it cannot serve as an executor.
An API key from AI Studio is the remaining route.

No task has yet been executed by the real engine: the CLI is installed but not
authenticated (`GEMINI_API_KEY` is unset and no account is signed in), so every
run ends at the auth check.

Specifically unverified:

- whether `--approval-mode auto_edit` really confines edits the way the name
  suggests;
- the shape of a successful `-o json` payload (the parser accepts `response`,
  `text` or `output` and falls back to raw text);
- whether `--skip-trust` makes the requested approval mode stick in practice;
- the Gemini sandbox options (`--sandbox`, container backends) as a way to
  restrict reads — a question left open in the Codex project, see its
  [sandbox study](https://github.com/fafnirov/claude-love-codex/blob/main/docs/reports/2026-10-26-sandbox-profiles.md);
- token accounting: the wrapper reports none, so every report carries
  `token usage unavailable`.

Until a live run is recorded here, treat this repository as **functional but
unproven against the real engine**.

## Inherited guarantees

These were verified in the sister project with the same driver code, and the
suites above re-check them here:

- a failing post-merge test cannot change the target branch;
- only the ref named by `--into` moves, under a compare-and-swap;
- a dirty working copy, a conflict, or missing required tests block the merge;
- `clean` refuses to remove a worktree holding uncommitted work;
- the risk detector flags secrets, destructive SQL, `rm -rf`, symlinks, deleted
  tests, binaries and renames on real diffs.
