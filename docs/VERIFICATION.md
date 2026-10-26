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

## NOT verified against a live Gemini CLI

**This is the honest state of the project.** The driver is inherited from
[Claude love Codex](https://github.com/fafnirov/claude-love-codex), where it was
verified end to end against a real executor: parallel delegation, conflict
refusal, cross-review in both directions, atomic merges, 168 automated checks.
What is new here — the engine wrapper — has **not** yet run against a real
`gemini` binary.

Specifically unverified:

- the exact non-interactive flags of the installed build (the wrapper probes
  `--help` instead of assuming, but the probe itself has only been exercised
  against the test double);
- whether `--approval-mode auto_edit` really confines edits the way the name
  suggests;
- what the CLI writes to stdout versus stderr in practice, and whether the final
  answer survives it cleanly;
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
