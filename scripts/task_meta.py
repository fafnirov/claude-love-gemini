#!/usr/bin/env python3
"""Helper operations for gemini-task.sh: task metadata, audit log, small lookups.

Subcommands:
  init <dir> <task_id> <branch> <wt> <repo> <base> <model> <attempt> <max>
       <test_cmd> <require_tests> <scope> <warnings>
  finish <dir> <engine_exit> <test_exit|null> <commit|""> <duration_s> <no_progress>
  index <dir> <root>                       — append a row to the audit log
  merge-log <dir> <root> <into> <outcome> [before] [after]
  get <json_file> <field>                  — read one field for the shell
  blocked <slug> <attempt> <max>           — refusal: attempt limit
  refuse <status> <slug> <reason>          — other refusals (duplicate, budget, parallel)
  sha1                                     — sha1 of stdin
  sha1-file <file>                         — sha1 of a file
  config-model <config.toml>               — the model value from the Gemini config
  model-known <models_cache.json> <model>  — yes | no | unknown
  auth-mode <auth.json>                    — auth method only, never values
  guard-snapshot <file> <repo> [scripts]   — fingerprint of protected files
  guard-check <file> <repo> [scripts] [task_dir]
  contract-get <task.json> <field>
  review-parse <review.txt>
  orphans <root>                           — stale locks and tasks without a report
  stats <root>
  gc <root> <days> <max_mb> <dry>          — log rotation
"""
import datetime
import hashlib
import json
import os
import pathlib
import re
import sys


def load(p):
    return json.loads(pathlib.Path(p).read_text(encoding="utf-8"))


def save(p, data):
    pathlib.Path(p).write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def guard_paths(repo, scripts):
    home = pathlib.Path.home()
    gemini_home = pathlib.Path(os.environ.get("GEMINI_HOME") or (home / ".gemini"))
    # in a linked worktree .git is a file, so ask git for the common dir
    git_config = pathlib.Path(repo) / ".git" / "config"
    try:
        import subprocess
        common = subprocess.run(["git", "-C", str(repo), "rev-parse", "--git-common-dir"],
                                capture_output=True, text=True, timeout=10).stdout.strip()
        if common:
            cp = pathlib.Path(common)
            if not cp.is_absolute():
                cp = pathlib.Path(repo) / cp
            git_config = cp / "config"
    except Exception:
        pass
    paths = [gemini_home / "GEMINI.md",
             gemini_home / "settings.json",
             home / ".claude/settings.json",
             home / ".claude/CLAUDE.md",
             git_config]
    if scripts:
        s = pathlib.Path(scripts)
        paths += [s / "gemini-task.sh", s / "gemini-run.sh", s / "task_report.py",
                  s / "task_meta.py"]
    for extra in (os.environ.get("GEMINI_GUARD_PATHS") or "").split(os.pathsep):
        if extra.strip():
            paths.append(pathlib.Path(extra.strip()))
    # Gemini rewrites config.toml and auth.json while it runs, which would produce
    # constant false positives. The source of those writes is not confirmed by any
    # log, so no authorship is claimed — they are simply out of scope here.
    return paths


def main():
    cmd = sys.argv[1]
    a = sys.argv[2:]

    if cmd == "init":
        d, task_id, branch, wt, repo, base, model, att, maxatt = a[:9]
        test_cmd = a[9] if len(a) > 9 else ""
        require = a[10] if len(a) > 10 else "0"
        scope = a[11] if len(a) > 11 else ""
        warn = a[12] if len(a) > 12 else ""
        save(d + "/meta.json", {
            "task_id": task_id, "branch": branch, "worktree": wt, "repo": repo,
            "base": base, "model": model, "attempt": int(att), "max_attempts": int(maxatt),
            "test_command": test_cmd or None,
            "require_tests": require in ("1", "true", "True"),
            "scope": [s.strip() for s in scope.split(",") if s.strip()],
            "warnings": [warn] if warn else [],
        })

    elif cmd == "finish":
        d, ce, te, commit, dur = a[:5]
        no_progress = a[5] if len(a) > 5 else "0"
        p = d + "/meta.json"
        m = load(p)
        m.update({
            "engine_exit": int(ce),
            "test_exit": None if te in ("null", "") else int(te),
            "commit": commit or None,
            "duration_s": int(dur),
            "no_progress": no_progress == "1",
        })
        if no_progress == "1":
            m.setdefault("warnings", []).append(
                "diff identical to the previous attempt — no progress")
        save(p, m)

    elif cmd == "index":
        d, root = a[:2]
        r = load(d + "/report.json")
        row = {k: r.get(k) for k in ("task_id", "status", "branch", "commit", "attempt",
                                     "duration_s", "model", "token_usage", "risk_level",
                                     "risks", "engine_exit", "warnings")}
        row["tests_status"] = (r.get("tests") or {}).get("status")
        row["changed"] = len(r.get("changed_files") or [])
        row["at"] = datetime.datetime.now().isoformat(timespec="seconds")
        with (pathlib.Path(root) / "index.jsonl").open("a", encoding="utf-8") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")

    elif cmd == "merge-log":
        d, root, into, outcome = a[:4]
        before = a[4] if len(a) > 4 else None
        after = a[5] if len(a) > 5 else None
        r = load(d + "/report.json")
        row = {"task_id": r.get("task_id"), "event": "merge", "outcome": outcome,
               "into": into,
               "updated_ref": ("refs/heads/" + into) if outcome == "merged" else None,
               "into_before": before, "into_after": after,
               "branch": r.get("branch"), "commit": r.get("commit"),
               "at": datetime.datetime.now().isoformat(timespec="seconds")}
        with (pathlib.Path(root) / "index.jsonl").open("a", encoding="utf-8") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")

    elif cmd == "get":
        src, field = a[:2]
        data = load(src)
        if field == "tests_status":
            print((data.get("tests") or {}).get("status") or "")
        else:
            v = data.get(field)
            if isinstance(v, list):
                print("; ".join(str(x) for x in v))
            elif v is None:
                print("")
            else:
                print(v)

    elif cmd == "blocked":
        slug, att, maxatt = a[:3]
        print(json.dumps({
            "status": "blocked", "slug": slug, "attempt": int(att),
            "max_attempts": int(maxatt),
            "reason": "attempt limit reached — diagnose instead of iterating again",
        }, ensure_ascii=False, indent=2))

    elif cmd == "refuse":
        status, slug, reason = a[0], a[1], a[2]
        print(json.dumps({"status": status, "slug": slug, "reason": reason},
                         ensure_ascii=False, indent=2))

    elif cmd == "sha1":
        print(hashlib.sha1(sys.stdin.buffer.read()).hexdigest()[:16])

    elif cmd == "sha1-file":
        p = pathlib.Path(a[0])
        print(hashlib.sha1(p.read_bytes() if p.exists() else b"").hexdigest()[:16])

    elif cmd == "settings-model":
        # the Gemini CLI keeps its settings in JSON, not TOML
        p = pathlib.Path(a[0])
        if not p.exists():
            print("")
            return 0
        try:
            d = json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            print("")
            return 0
        v = d.get("model")
        if isinstance(v, dict):
            v = v.get("name") or v.get("default")
        print(v or "")

    elif cmd == "gemini-auth":
        # report the method only, never a value
        home = pathlib.Path(a[0])
        env_key = any(os.environ.get(k) for k in
                      ("GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS"))
        oauth = (home / "oauth_creds.json").exists() or (home / "google_accounts.json").exists()
        if env_key:
            print("api key from the environment")
        elif oauth:
            print("signed in with a Google account")
        else:
            print("MISSING (run: gemini, then sign in; or set GEMINI_API_KEY)")

    elif cmd == "config-model":
        p = pathlib.Path(a[0])
        if not p.exists():
            print("")
            return 0
        for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
            m = re.match(r'\s*model\s*=\s*["\'](.+?)["\']\s*$', line)
            if m:
                print(m.group(1))
                return 0
        print("")

    elif cmd == "model-known":
        p, model = pathlib.Path(a[0]), a[1]
        if not p.exists():
            print("unknown")
            return 0
        try:
            slugs = {m.get("slug") for m in load(p).get("models", [])}
        except Exception:
            print("unknown")
            return 0
        print("yes" if model in slugs else "no")

    elif cmd == "auth-mode":
        try:
            d = load(pathlib.Path(a[0]))
        except Exception:
            print("auth.json unreadable")
            return 0
        mode = d.get("auth_mode") or ("api_key" if d.get("OPENAI_API_KEY") else "chatgpt")
        print("mode: %s, tokens: %s" % (mode, "present" if d.get("tokens") else "absent"))

    elif cmd in ("guard-snapshot", "guard-check"):
        # Gemini's sandbox does not confine writes to the working directory, so we
        # fingerprint a small set of critical files around every run. This is a
        # tamper DETECTOR, not a security boundary, and it cannot see reads.
        snap_file, repo = a[0], a[1]
        scripts = a[2] if len(a) > 2 else ""
        snap = {}
        for p in guard_paths(repo, scripts):
            try:
                snap[str(p)] = hashlib.sha1(p.read_bytes()).hexdigest() if p.is_file() else "absent"
            except Exception:
                snap[str(p)] = "unreadable"
        if cmd == "guard-snapshot":
            save(snap_file, snap)
        else:
            before = load(snap_file) if pathlib.Path(snap_file).exists() else {}
            changed = [k for k, v in snap.items() if before.get(k, v) != v]
            task_dir = a[3] if len(a) > 3 else None
            if task_dir and changed:
                mp = task_dir + "/meta.json"
                m = load(mp)
                m["guard_changed"] = changed
                save(mp, m)
            print("\n".join(changed))

    elif cmd == "contract-get":
        src, field = a[:2]
        v = load(src).get(field)
        if isinstance(v, list):
            print(",".join(str(x) for x in v))
        elif v is None:
            print("")
        else:
            print(v)

    elif cmd == "review-parse":
        p = pathlib.Path(a[0])
        raw = p.read_text(encoding="utf-8", errors="replace") if p.exists() else ""
        out, start = None, raw.find(chr(123))
        if start >= 0:
            for end in range(len(raw), start, -1):
                try:
                    out = json.loads(raw[start:end])
                    break
                except Exception:
                    continue
        if not isinstance(out, dict):
            out = {"verdict": "unparsed", "findings": [], "raw": raw[:1500]}
        out.setdefault("verdict", "unknown")
        out.setdefault("findings", [])
        print(json.dumps(out, ensure_ascii=False, indent=2))

    elif cmd == "orphans":
        root = pathlib.Path(a[0])
        locks, wts = [], []
        for d in sorted((root / "locks").glob("slot-*")):
            pid = (d / "pid").read_text(encoding="utf-8").strip() if (d / "pid").exists() else ""
            locks.append({"lock": d.name, "pid": pid})
        for d in sorted(root.glob("2*")):
            if (d / "wt").exists() and not (d / "report.json").exists():
                wts.append(d.name)
        print(json.dumps({"stale_locks": locks, "tasks_without_report": wts},
                         ensure_ascii=False, indent=2))

    elif cmd == "stats":
        root = pathlib.Path(a[0])
        idx = root / "index.jsonl"
        tasks, merges, dur, tin, tout, by_status = 0, 0, 0, 0, 0, {}
        if idx.exists():
            for line in idx.read_text(encoding="utf-8", errors="replace").splitlines():
                try:
                    r = json.loads(line)
                except Exception:
                    continue
                if r.get("event") == "merge":
                    merges += 1
                    continue
                tasks += 1
                by_status[r.get("status")] = by_status.get(r.get("status"), 0) + 1
                dur += r.get("duration_s") or 0
                u = r.get("token_usage") or {}
                tin += u.get("input_tokens") or 0
                tout += u.get("output_tokens") or 0
        size_mb = round(sum(f.stat().st_size for f in root.rglob("*") if f.is_file()) / 1048576, 1)
        print(json.dumps({
            "tasks": tasks, "merges": merges, "by_status": by_status,
            "engine_seconds_total": dur,
            "engine_tokens": {"input_total": tin, "output_total": tout,
                             "note": "input includes cached tokens; cost is not computed"},
            "logs_size_mb": size_mb,
        }, ensure_ascii=False, indent=2))

    elif cmd == "gc":
        # Log rotation. NEVER removes: unfinished tasks, tasks with a worktree,
        # failures, or index.jsonl (the merge audit).
        import shutil
        import time
        root = pathlib.Path(a[0])
        days = int(a[1]) if len(a) > 1 else 30
        max_mb = int(a[2]) if len(a) > 2 else 500
        dry = (len(a) > 3 and a[3] == "1")
        now = time.time()
        removed, kept, freed = [], [], 0

        def task_dirs():
            return sorted((d for d in root.glob("2*") if d.is_dir()),
                          key=lambda p: p.stat().st_mtime)

        def size_of(p):
            return sum(f.stat().st_size for f in p.rglob("*") if f.is_file())

        def protect(d):
            if (d / "wt").exists():
                return "worktree present (may hold uncommitted work)"
            rp = d / "report.json"
            if not rp.exists():
                return "task not finished"
            try:
                st = json.loads(rp.read_text(encoding="utf-8")).get("status")
            except Exception:
                return "report unreadable"
            if st != "success":
                return "status %s — failure log kept" % st
            return None

        for d in task_dirs():
            age_days = (now - d.stat().st_mtime) / 86400
            why = protect(d)
            if why:
                kept.append({"task": d.name, "reason": why})
                continue
            if age_days > days:
                sz = size_of(d)
                removed.append({"task": d.name, "age_days": round(age_days, 1),
                                "mb": round(sz / 1048576, 2)})
                freed += sz
                if not dry:
                    shutil.rmtree(d, ignore_errors=True)

        done = {r["task"] for r in removed}
        total_mb = sum(size_of(d) for d in task_dirs() if d.name not in done) / 1048576
        while total_mb > max_mb:
            cand = [d for d in task_dirs() if not protect(d) and d.name not in done]
            if not cand:
                break
            d = cand[0]
            done.add(d.name)
            sz = size_of(d)
            removed.append({"task": d.name, "mb": round(sz / 1048576, 2),
                            "reason": "size limit"})
            freed += sz
            if not dry:
                shutil.rmtree(d, ignore_errors=True)
            total_mb -= sz / 1048576

        print(json.dumps({"dry_run": dry, "retention_days": days, "max_mb": max_mb,
                          "removed": removed, "kept_protected": kept,
                          "freed_mb": round(freed / 1048576, 2),
                          "note": "index.jsonl (merge audit) is never touched"},
                         ensure_ascii=False, indent=2))

    else:
        print("unknown subcommand: " + cmd, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
