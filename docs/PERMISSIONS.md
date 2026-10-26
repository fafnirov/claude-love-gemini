# Claude Code permissions

Least privilege: routine calls run without asking, anything that changes a branch
or removes a worktree asks every time.

| Command | Mode | Why |
|---|---|---|
| `run` | allow | writes only inside the task worktree |
| `list`, `show`, `stats`, `doctor`, `recover` | allow | read-only |
| `merge` | ask | changes a branch |
| `clean` | ask | removes a worktree |
| `gc` | ask | rotates logs |

Never add a blanket `Bash(*)`.

`gemini-run.sh` is deliberately **not** on the allow list. It is the low-level
wrapper: `--write --dir <any path>` runs the engine outside the task worktree and
skips every gate in `gemini-task.sh`.

Add this to the `permissions` object in `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(~/.claude/scripts/gemini-task.sh run:*)",
      "Bash(~/.claude/scripts/gemini-task.sh list:*)",
      "Bash(~/.claude/scripts/gemini-task.sh show:*)",
      "Bash(~/.claude/scripts/gemini-task.sh stats:*)",
      "Bash(~/.claude/scripts/gemini-task.sh recover:*)",
      "Bash(~/.claude/scripts/gemini-task.sh doctor:*)"
    ],
    "ask": [
      "Bash(~/.claude/scripts/gemini-task.sh merge:*)",
      "Bash(~/.claude/scripts/gemini-task.sh clean:*)",
      "Bash(~/.claude/scripts/gemini-task.sh gc:*)"
    ]
  }
}
```

Permission patterns match the command string as written, so if Claude calls the
script by absolute path, add that spelling too — for example
`"Bash(/home/you/.claude/scripts/gemini-task.sh run:*)"` or, on Windows with Git
Bash, `"Bash(/c/Users/you/.claude/scripts/gemini-task.sh run:*)"`.

Running Claude love Codex as well? The two sets do not collide — add both.

You can also edit permissions with `/permissions` in an interactive `claude`
terminal. The installer does not touch `settings.json` on purpose — Claude Code
protects it from self-modification, and that protection is worth keeping.
