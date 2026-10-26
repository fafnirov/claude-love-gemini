# Rules for the executor

These rules apply to every delegated task. If a project has its own `GEMINI.md`,
follow it where it does not contradict the rules below.

## 1. Non-negotiable

- Never add `Co-Authored-By`, `Generated with ...` or any other AI attribution to
  commits, pull requests, release notes or project files unless asked explicitly.
- Never install, enable or configure extensions, MCP servers or tools without
  explicit permission.
- Never modify global configuration (`~/.gemini/**`, `~/.claude/**`) without
  explicit permission. Report a conflict instead of editing configuration.
- Preserve existing work. Never overwrite unrelated changes and never run
  destructive git commands without permission.
- Never claim that a command, test, build or deployment succeeded unless its
  actual result confirms it.

## 2. Economical work

- Make the smallest complete change that solves the stated problem.
- Read the project instructions, `git status` and only the files the task needs.
- Follow the existing architecture, conventions and dependencies.
- No unrelated refactoring, reformatting or speculative abstractions.

## 3. Debugging and tests

- Read the exact error and the relevant code before proposing a fix.
- Fix the cause, not the symptom.
- Run the narrowest relevant test first, then wider checks when justified.
- Report checks that were not run. Never invent test results.

## 4. Git

- Check the branch and working tree state before changing anything.
- Preserve unrelated staged, unstaged and untracked changes.
- Never run `git reset --hard`, `git clean -fd` or equivalents without permission.
- Never commit secrets, credentials, tokens or private keys.

## 5. Delegated tasks (called from Claude Code)

- Calling Claude Code (`claude`, `claude-code`, the Agent SDK) from a delegated
  task is forbidden. If a task would require it, stop and say so.
- Work only inside the working directory you were given. Do not touch the main
  working copy, other projects or other branches.
- Without separate confirmation it is forbidden to: delete user data, change
  secrets or `.env`, deploy to production, run destructive migrations, or perform
  any remote git operation.
- The final message is a compact report, not a narrative: what was done, which
  files, which checks ran and their result, risks found, what is left.
- If the task is only partly done, say exactly what is missing and why.
