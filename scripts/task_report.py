#!/usr/bin/env python3
"""Build the compact report for a delegated Gemini task.

The risk detector is a heuristic, NOT a security boundary. The real boundaries
are worktree isolation, the merge/clean refusals and human confirmation.
"""
import json
import re
import sys
from pathlib import Path

MAX_SUMMARY = 1200
MAX_ERRORS = 5
ERR_KEY = chr(34) + "error" + chr(34)
BRACE = chr(123)

RISK_PATHS = [
    (r"(^|/)\.env(\.|$)", "env files changed", "high"),
    (r"(^|/)(secrets?|credentials?)(/|\.|$)", "secret files changed", "high"),
    (r"\.(pem|key|p12|pfx|keystore|jks)$", "key files changed", "high"),
    (r"(^|/)id_(rsa|dsa|ecdsa|ed25519)", "ssh private keys changed", "high"),
    (r"(^|/)(prod|production)(/|\.|-|_)", "production config changed", "high"),
    (r"(^|/)migrations?/", "migrations changed", "medium"),
    (r"(^|/)alembic/", "alembic migrations changed", "medium"),
    (r"\.sql$", "sql files changed", "medium"),
    (r"(^|/)\.github/workflows/", "CI workflows changed", "medium"),
    (r"(^|/)\.gitlab-ci\.ya?ml$", "CI config changed", "medium"),
    (r"(^|/)(Dockerfile|docker-compose\.ya?ml|\.dockerignore)$",
     "container config changed", "medium"),
    (r"(^|/)(k8s|helm|charts)/", "deployment manifests changed", "medium"),
    (r"(^|/)(package-lock\.json|yarn\.lock|poetry\.lock|pnpm-lock\.ya?ml|Cargo\.lock|composer\.lock)$",
     "lock files changed", "medium"),
    (r"(^|/)\.claude/", "Claude Code config changed", "high"),
    (r"(^|/)\.gemini/", "Gemini config changed", "high"),
    (r"(^|/)\.git/", "write inside .git attempted", "high"),
    (r"(^|/)\.ssh/", "ssh config changed", "high"),
]

RISK_DIFF = [
    (r"(?mi)^\+.*(SECRET|PASSWORD|PASSWD|API_?KEY|ACCESS_?TOKEN|PRIVATE_?KEY|CLIENT_SECRET)\s*[:=]\s*\S",
     "secret-looking values added", "high"),
    (r"(?m)^\+.*-----BEGIN [A-Z ]*PRIVATE KEY-----", "private key in diff", "high"),
    (r"(?m)^\+.*\b(sk-[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{12,}|xox[baprs]-[A-Za-z0-9-]{10,})",
     "token-looking string in diff", "high"),
    (r"(?mi)^\+.*\bDROP\s+(TABLE|COLUMN|DATABASE|SCHEMA)\b", "destructive SQL (DROP)", "high"),
    (r"(?mi)^\+.*\bTRUNCATE\s+TABLE\b", "TRUNCATE TABLE in diff", "high"),
    (r"(?mi)^\+.*\bDELETE\s+FROM\s+(?!.*\bWHERE\b)\S+", "DELETE FROM without WHERE", "high"),
    (r"(?m)^\+.*\brm\s+-[a-zA-Z]*[rR][a-zA-Z]*f", "rm -rf in diff", "high"),
    (r"(?m)^\+.*\bgit\s+push\b.*(--force|-f)\b", "force push in diff", "high"),
    (r"(?m)^\+.*\bgit\s+(reset\s+--hard|clean\s+-[a-zA-Z]*f)", "destructive git command", "high"),
    (r"(?m)^\+.*\bchmod\s+(777|-R\s+777)", "chmod 777 in diff", "high"),
    (r"(?m)^\+.*\bcurl\b[^\n|]*\|\s*(ba)?sh", "pipe-to-shell download in diff", "high"),
    (r"(?m)^new mode 120000|^\+.*os\.symlink|^\+.*\bln\s+-s\b", "symlink creation", "high"),
    (r"(?m)^GIT binary patch|^Binary files .* differ", "binary data in diff", "medium"),
    (r"(?m)^rename (from|to) ", "files renamed", "medium"),
    (r"(?m)^\-\s*(def test_|it\(|test\(|func Test)", "tests removed", "high"),
    (r"(?m)^\-\s*(assert|expect\(|EXPECT_|ASSERT_)\b", "test assertions removed", "high"),
    (r"(?m)^deleted file mode", "files deleted", "medium"),
    (r"(?m)^\+.*\.\./\.\./\.\./", "path escaping the project directory", "high"),
]

MODEL_ERR = re.compile(
    r"model_not_found|is not supported when using|model .{0,40}not (found|supported)", re.I)


def read_text(p, limit=None):
    p = Path(p)
    if not p.exists():
        return ""
    t = p.read_text(encoding="utf-8", errors="replace").strip()
    return t[:limit] if limit else t


def parse_events(p):
    """Last agent message, errors and token usage.

    Broken lines are skipped: the log can be truncated by a timeout or an
    interrupt, and that must not break the report.
    """
    last_msg, errors, usage, bad = "", [], {}, 0
    p = Path(p)
    if not p.exists():
        return last_msg, errors, usage, bad

    def walk(node):
        nonlocal last_msg, usage
        if isinstance(node, dict):
            for key in ("usage", "token_usage", "total_token_usage"):
                v = node.get(key)
                if isinstance(v, dict) and any("token" in k.lower() for k in v):
                    usage = {k: v[k] for k in v if isinstance(v[k], int)}
            txt = node.get("text") or node.get("message") or node.get("last_agent_message")
            role = str(node.get("role") or node.get("type") or "")
            if isinstance(txt, str) and txt.strip() and "user" not in role:
                last_msg = txt.strip()
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        if not line.startswith(BRACE):
            bad += 1
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            bad += 1
            continue
        walk(ev)
        blob = json.dumps(ev, ensure_ascii=False)
        if ERR_KEY in blob and len(errors) < MAX_ERRORS:
            msg = ev.get("error") if isinstance(ev.get("error"), str) else None
            if isinstance(ev.get("error"), dict):
                msg = ev["error"].get("message") or json.dumps(ev["error"], ensure_ascii=False)
            errors.append((msg or blob)[:300])
    return last_msg, errors, usage, bad


def detect_risks(changed, diff):
    """Any single match flags the whole task, so a dangerous edit cannot hide
    among harmless ones."""
    found = {}
    for f in changed:
        for pat, label, level in RISK_PATHS:
            if re.search(pat, f, re.I):
                found[label] = level
    for pat, label, level in RISK_DIFF:
        if re.search(pat, diff):
            found[label] = level
    if not found:
        return [], "none"
    return sorted(found), ("high" if "high" in found.values() else "medium")


def check_scope(changed, scope):
    """Does the diff stay inside the task boundaries (glob patterns)?

    A bare name matches that exact path only: "calc.py" must not accept
    "calc.py.bak". Directory prefixes need an explicit "dir/" or a glob.
    """
    if not scope:
        return True, []
    import fnmatch

    def allowed(f):
        for g in scope:
            if fnmatch.fnmatch(f, g):
                return True
            if g.endswith("/") and f.startswith(g):
                return True
            if g.endswith("/*") and f.startswith(g[:-1]):
                return True
        return False

    outside = [f for f in changed if not allowed(f)]
    return (not outside), outside


def main():
    d = Path(sys.argv[1])
    meta = json.loads(read_text(d / "meta.json") or "{}")
    last_msg, errors, usage, bad = parse_events(d / "events.jsonl")
    stderr_tail = read_text(d / "stderr.log")[-2000:]
    summary = read_text(d / "last.txt") or last_msg or "(no final message from Gemini)"
    changed = [x for x in read_text(d / "changed_files.txt").splitlines() if x.strip()]
    diff = read_text(d / "diff.patch")
    tests_log = read_text(d / "tests.log")
    risks, risk_level = detect_risks(changed, diff)
    warnings = list(meta.get("warnings") or [])

    # Files outside the task changed during the run — always high risk.
    guard_changed = meta.get("guard_changed") or []
    if guard_changed:
        risks = sorted(set(risks) | {"protected files outside the task changed"})
        risk_level = "high"
        warnings.append("files outside the working directory touched: "
                        + ", ".join(guard_changed[:5]))

    engine_exit = meta.get("engine_exit", -1)
    test_cmd = meta.get("test_command") or None
    test_exit = meta.get("test_exit")
    require_tests = bool(meta.get("require_tests"))

    if test_cmd and test_exit is not None:
        test_status = "passed" if test_exit == 0 else "failed"
    else:
        test_status = "not_run"

    scope_ok, outside = check_scope(changed, meta.get("scope") or [])
    if not scope_ok:
        warnings.append("diff leaves the task boundaries: " + ", ".join(outside[:10]))
    if bad:
        warnings.append("%d unreadable lines in the event log (possible truncation)" % bad)
    if not usage:
        warnings.append("token usage unavailable")

    model_bad = bool(MODEL_ERR.search(stderr_tail)) or any(MODEL_ERR.search(e) for e in errors)

    # Quality gate: the status comes from verifiable facts only.
    if meta.get("forced_status"):
        status = meta["forced_status"]
    elif model_bad:
        status = "model_unavailable"
    elif engine_exit == 124:
        status = "timeout"
    elif engine_exit != 0:
        status = "failed"
    elif test_status == "failed":
        status = "tests_failed"
    elif require_tests and test_status == "not_run":
        status = "tests_not_run"
    elif not changed:
        status = "no_changes"
    elif not scope_ok or risk_level != "none":
        status = "needs_review"
    elif meta.get("no_progress"):
        status = "no_progress"
    else:
        status = "success"

    if test_status == "failed" and not errors:
        errors = [x[:300] for x in tests_log.splitlines() if x.strip()][-MAX_ERRORS:]
    if status in ("failed", "timeout", "model_unavailable") and not errors and stderr_tail:
        errors = [x[:300] for x in stderr_tail.splitlines() if x.strip()][-MAX_ERRORS:]

    tests_block = {
        "command": test_cmd, "exit_code": test_exit, "status": test_status,
        "passed": True if test_status == "passed" else (False if test_status == "failed" else None),
        "required": require_tests,
    }
    auto_merge = (status == "success" and risk_level == "none" and scope_ok
                  and not (require_tests and test_status != "passed"))

    report = {
        "task_id": meta.get("task_id"), "status": status, "summary": summary[:MAX_SUMMARY],
        "changed_files": changed, "tests": tests_block,
        "tests_passed": test_status == "passed", "tests_failed": test_status == "failed",
        "tests_not_run": test_status == "not_run",
        "risk_level": risk_level, "risks": risks, "warnings": warnings, "errors": errors,
        "branch": meta.get("branch"), "commit": meta.get("commit"),
        "attempt": meta.get("attempt"), "max_attempts": meta.get("max_attempts"),
        "duration": meta.get("duration_s"), "duration_s": meta.get("duration_s"),
        "model": meta.get("model"), "token_usage": usage, "usage": usage,
        "engine_exit": engine_exit, "scope_ok": scope_ok,
        "worktree": meta.get("worktree"), "task_dir": str(d),
        "auto_merge_allowed": auto_merge,
        "detector_note": "risks are a heuristic, not a security boundary",
        "logs": {"events": "events.jsonl", "diff": "diff.patch", "tests": "tests.log",
                 "stderr": "stderr.log"},
    }
    (d / "report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    compact = {k: v for k, v in report.items()
               if k not in ("logs", "usage", "duration_s", "tests", "detector_note")}
    compact["tests"] = {"status": test_status, "command": test_cmd, "exit_code": test_exit}
    print(json.dumps(compact, ensure_ascii=False, indent=2))
    return 0 if status == "success" else 1


if __name__ == "__main__":
    sys.exit(main())
