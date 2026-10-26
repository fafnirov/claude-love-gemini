# Threat model

## What is protected

- **Integrity of the target branch.** The merge is built and tested in a
  temporary worktree; the `--into` ref moves only after tests pass, via a
  compare-and-swap against the SHA recorded before the check.
- **The user's uncommitted work.** `merge` refuses to run against a dirty working
  copy when the target branch is checked out; `clean` refuses to remove a
  worktree that holds uncommitted changes.
- **Repository changes.** Every task works on its own branch in its own worktree.
- **The checked-out branch.** When `--into` names another branch, only that ref
  moves; HEAD, the index and the working files are untouched.
- **Approval bypass.** `-y`, `--yolo` and `--approval-mode=yolo` are refused by
  both the driver and the engine wrapper. If a build offers no approval control
  at all, the wrapper refuses to run instead of degrading to full auto-approval.
- **Recursion (partly).** The driver refuses to start when `GEMINI_TASK_ACTIVE`
  is set, and the executor rules forbid calling Claude Code back. This is a
  guard, not a sandbox: a process that unsets the variable can bypass it.

## What is NOT protected

- **Reading files.** A delegated task runs with your account's privileges. Unless
  you run the Gemini CLI inside its own container sandbox, it can read whatever
  you can read — `.env` files, keys, credentials. Nothing in this project
  prevents or detects that.
- **Writes outside the worktree.** `--approval-mode auto_edit` is an approval
  policy, not a filesystem boundary. Whether it confines edits in practice has
  **not been verified here** (see [VERIFICATION.md](VERIFICATION.md)).
- **Network access** by the executor.
- **File contents reaching the model** as part of a request.
- **Concurrent bookkeeping.** Duplicate detection, attempt counters and the time
  budget are plain files without locking. Two processes starting at the very same
  moment can both pass a check. The slot locks (`mkdir`) are atomic; these
  counters are not.

## Residual risk

A delegated task is third-party code running as you, with read access to your
disk. Do not use delegation on machines holding production keys or data that
must not reach the executor or the model.

## Worth trying: the Gemini sandbox

The Gemini CLI can run tools inside a container (`--sandbox`, docker or podman).
In the sister project a comparable question was studied in depth for Codex on
Windows and the answer was negative — reads could not be restricted at all
([the study](https://github.com/fafnirov/claude-love-codex/blob/main/docs/reports/2026-10-26-sandbox-profiles.md)).
A container-based sandbox is a different mechanism and may do better.

This has **not** been measured here. Before relying on it, run the same kind of
probe: synthetic secrets inside the worktree, next to it and in a user
directory, and check the actual exit codes rather than the model's description
of what it could see.

## Tamper detector (not secret protection)

Around every run the driver fingerprints a small set of files:
`~/.gemini/GEMINI.md`, `~/.gemini/settings.json`, `~/.claude/settings.json`,
`~/.claude/CLAUDE.md`, the integration scripts and the repository's
`.git/config`. If any changed during the task, the report gets
`risk_level: high`, status `needs_review`, and automatic merge is refused.

It is a **post-hoc detector**: it notices a change after it happened and knows
nothing about reads.

## Reporting a problem

Open an issue describing the behaviour and how to reproduce it. Do not include
real secrets, tokens or logs containing them.
