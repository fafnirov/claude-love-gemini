# Verification

## Antigravity CLI engine — a full cycle, live

The `agy` engine (Antigravity CLI 1.4.7, **signed-in Google account, no API
key**) completed the whole cycle against a real repository:

| Step | Result |
|---|---|
| delegated write task | `status: success`, 35 s |
| files changed | `calc.py`, `test_calc.py` — exactly the declared scope |
| tests in the worktree | passed |
| token accounting | 57 939 in / 2 385 out / 60 324 total, reported per task |
| main working copy during the task | untouched, HEAD unmoved |
| merge | staged check, post-merge tests passed, ref fast-forwarded |
| cleanup | worktree removed, logs kept |

**Caught on the first attempt:** with `--mode accept-edits` the engine tried a
shell command, which headless mode auto-denies — *"a tool required the command
permission that headless mode cannot prompt for"* — and the turn ended with
`engine_exit: 0` and **no changes at all**. The gate caught it as `no_changes`
rather than reporting success. The wrapper now tells the engine to apply changes
with its file-editing tools and leave verification to the driver. The
`--dangerously-skip-permissions` escape hatch the CLI suggests stays refused.

Verified flags of `agy` 1.4.7: `-p/--print/--prompt`, `--mode
plan|accept-edits|auto`, `--output-format text|json|stream-json`, `--model`,
`--effort`, `--sandbox`, `--add-dir`, `--json-schema`. Models offered include
Gemini 3.8 Flash at three effort levels, Claude Sonnet 4.6, Claude Opus 4.6 and
GPT-OSS 120B.


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

## Live runs against a real Gemini CLI

Authenticated with an AI Studio API key (the Google-account route is closed, see
above). What actually happened, with exit codes:

**Works**

- Non-interactive `-p` with `-o json`: the answer arrives in `response`, and
  `stats.models.<model>.tokens` carries real token counts. The wrapper now reads
  that nested shape, so reports no longer say `token usage unavailable`.
- Tool use in `plan` mode: a request that required listing the directory
  returned the correct file list, exit 0.
- **The failure path of the whole driver.** A real delegated task was executed:
  the engine failed with `503`, and the gate did exactly what it should —
  `engine_exit: 1`, status `failed`, no commit, `auto_merge_allowed: false`,
  the error text captured in the report. The worktree, branch and logs were kept.

**Blocked by quota and model availability**

- A *successful* write task was never achieved. The default model
  (`gemini-3.1-pro-preview-customtools`) returned `503 Service Unavailable` on
  every tool-using write request, retrying for up to ten minutes.
- `gemini-2.5-flash` answers `404`: *"no longer available to new users"*,
  suggesting `gemini-3.8-flash`.
- `gemini-3.8-flash` then answered `429`: *"You have exhausted your daily quota
  on this model"* — after only a handful of requests.
- Therefore unverified: whether `auto_edit` confines edits in practice, and the
  container sandbox (`-s`) as a way to restrict reads.

**Behavioural finding: the review contract is not honoured**

Asked to return JSON only and to analyse nothing but the supplied diff, this
build explored the working directory instead and replied with prose about the
files it found — twice, including after the instruction was repeated before and
after the diff. The wrapper degrades safely (`verdict: unparsed`, raw text
preserved), but structured cross-review cannot be relied on from this engine
today. Use it for execution; review with another engine.

**Model names, checked rather than guessed**

| Model | Result |
|---|---|
| `gemini-3.1-pro-preview-customtools` | the CLI default here; answers in plan mode, `503` under tool-using write load |
| `gemini-3-flash-preview` | seen in session stats |
| `gemini-3.8-flash` | exists; answered `429` daily quota |
| `gemini-2.5-flash` | `404` — "no longer available to new users" |
| `gemini-1.5-flash` | `404` — "not found for API version v1beta" |

Pinning an older "stable" name is therefore the wrong move: 1.5 and 2.5 are gone
on this account. Nothing is pinned by default; use `--model` or `GEMINI_MODEL`
when a specific one is wanted, and expect the names to keep moving.

**What this means for the intended role**

The free AI Studio tier does not support the "cheap bulk executor" idea as
stated: bulk work is exactly what exhausts a daily quota, and the models that
are not quota-limited are the ones returning 503 under tool-using load. Either
pay for capacity, or treat this engine as an occasional helper rather than the
workhorse.

## Still not verified

The driver is inherited from
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

The driver and the wrapper are proven to handle a live engine, including its
failures. What is not proven is a completed write task end to end — that waits
on quota.

## Inherited guarantees

These were verified in the sister project with the same driver code, and the
suites above re-check them here:

- a failing post-merge test cannot change the target branch;
- only the ref named by `--into` moves, under a compare-and-swap;
- a dirty working copy, a conflict, or missing required tests block the merge;
- `clean` refuses to remove a worktree holding uncommitted work;
- the risk detector flags secrets, destructive SQL, `rm -rf`, symlinks, deleted
  tests, binaries and renames on real diffs.
