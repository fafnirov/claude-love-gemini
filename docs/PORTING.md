# Keeping the two projects in sync

This repository shares its driver with
[Claude love Codex](https://github.com/fafnirov/claude-love-codex). Two copies of
the same logic is a real maintenance cost: a fix in one does not reach the other
by itself. This page keeps that cost manageable.

## What is shared and what is not

| File here | Counterpart there | Relation |
|---|---|---|
| `scripts/gemini-task.sh` | `scripts/codex-task.sh` | same driver, renamed identifiers |
| `scripts/task_report.py` | `scripts/codex_report.py` | same logic |
| `scripts/task_meta.py` | `scripts/codex_meta.py` | same logic + Gemini-specific helpers |
| `tests/*.sh` | `tests/*.sh` | same suites, renamed identifiers |
| `scripts/agy-run.sh` | — | **engine-specific, no counterpart** |
| `scripts/gemini-run.sh` | `scripts/codex-run.sh` | **engine-specific, do not port** |
| `templates/GEMINI.md` | `templates/AGENTS.md` | engine-specific wording |

## Porting a fix

The rename is mechanical. From the other repository:

```bash
# Codex -> Gemini
sed -e 's/CODEX_TASKS_DIR/GEMINI_TASKS_DIR/g' \
    -e 's/CODEX_TASK_ACTIVE/GEMINI_TASK_ACTIVE/g' \
    -e 's/CODEX_GUARD_PATHS/GEMINI_GUARD_PATHS/g' \
    -e 's/CODEX_DEFAULT_MODEL/GEMINI_DEFAULT_MODEL/g' \
    -e 's/CODEX_BIN/GEMINI_BIN/g' -e 's/CODEX_MODEL/GEMINI_MODEL/g' \
    -e 's/CODEX_HOME/GEMINI_HOME/g' -e 's/CODEX_CONFIG/GEMINI_CONFIG/g' \
    -e 's/codex_report\.py/task_report.py/g' -e 's/codex_meta\.py/task_meta.py/g' \
    -e 's/codex-task\.sh/gemini-task.sh/g' -e 's/codex-run\.sh/gemini-run.sh/g' \
    -e 's/fake-codex\.sh/fake-gemini.sh/g' -e 's/codex-task/gemini-task/g' \
    -e 's|codex/|gemini/|g' -e 's/codex: /gemini: /g' \
    -e 's/codex_exit/engine_exit/g' -e 's/Codex/Gemini/g' -e 's/codex/gemini/g' \
    ../claude-love-codex/scripts/codex-task.sh > scripts/gemini-task.sh
```

Then re-apply the Gemini-specific parts, which the rename does not produce:

1. `GEMINI_CONFIG` points at `settings.json`, not a TOML file.
2. Model resolution uses the `settings-model` helper (JSON), not `config-model`.
3. `model_known()` always returns `unknown` — there is no local model catalogue.
4. The banned flags are `-y`, `--yolo`, `--approval-mode=yolo`.
5. `doctor` locates the binary via `npm` paths and reports auth with
   `gemini-auth`.

After any port: run all three suites. They are the contract.

## Divergence policy

Differences that are **expected**: the engine wrapper, the executor rules
template, the auth and model lookups, token accounting.

Differences that are **bugs**: anything in the quality gate, the merge logic, the
risk detector or the limits. If the two repositories disagree there, one of them
is wrong.
