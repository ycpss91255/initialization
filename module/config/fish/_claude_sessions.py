#!/usr/bin/env python3
"""Helper: dump info about all Claude Code sessions as JSONL.

One JSON object per line, fields:
  path, session_id, project, title, first_user, forked_from,
  last_epoch, message_count, size_bytes, model, cwd
"""
import glob
import json
import os
import re
import sys
from datetime import datetime

PROJECTS_DIR = os.path.expanduser("~/.claude/projects")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def _epoch(ts):
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def session_info_jsonl(path):
    sid = os.path.basename(path).removesuffix(".jsonl")
    project = os.path.basename(os.path.dirname(path))
    title = ""
    first_user = ""
    forked_from = None
    last_epoch = None
    message_count = 0
    model = ""
    cwd = ""
    try:
        size_bytes = os.path.getsize(path)
    except Exception:
        size_bytes = 0
    try:
        with open(path) as fp:
            for line in fp:
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                kind = d.get("type")
                if kind in ("user", "assistant"):
                    message_count += 1
                if not title and d.get("customTitle"):
                    title = d["customTitle"]
                if not forked_from and isinstance(d.get("forkedFrom"), dict):
                    forked_from = d["forkedFrom"].get("sessionId")
                if not cwd and d.get("cwd"):
                    cwd = d["cwd"]
                msg = d.get("message")
                if isinstance(msg, dict) and msg.get("model"):
                    model = msg["model"]
                ts = d.get("timestamp")
                if ts:
                    e = _epoch(ts)
                    if e is not None:
                        last_epoch = e
                if not first_user and kind == "user":
                    content = d.get("message", {}).get("content", "")
                    if isinstance(content, list):
                        text = ""
                        for c in content:
                            if isinstance(c, dict) and c.get("type") == "text":
                                text = c.get("text", "")
                                break
                        content = text
                    if isinstance(content, str):
                        content = content.strip()
                        if content and not content.startswith("<local-command") and not content.startswith("<command-"):
                            first_user = content.splitlines()[0][:60]
    except Exception:
        pass
    return {
        "path": path,
        "session_id": sid,
        "project": project,
        "title": title,
        "first_user": first_user,
        "forked_from": forked_from,
        "last_epoch": last_epoch,
        "message_count": message_count,
        "size_bytes": size_bytes,
        "model": model,
        "cwd": cwd,
    }


def session_info_dir(path):
    sid = os.path.basename(path)
    project = os.path.basename(os.path.dirname(path))
    first_user = ""
    metas = sorted(glob.glob(os.path.join(path, "subagents", "*.meta.json")))
    for meta in metas:
        try:
            with open(meta) as fp:
                d = json.load(fp)
                desc = d.get("description", "")
                if desc:
                    first_user = desc[:60]
                    break
        except Exception:
            pass

    # Enrich from the subagent transcripts (agent-*.jsonl), which carry cwd /
    # model / timestamps even though the session has no top-level <uuid>.jsonl.
    last_epoch = None
    message_count = 0
    model = ""
    cwd = ""
    size_bytes = 0
    for aj in sorted(glob.glob(os.path.join(path, "subagents", "*.jsonl"))):
        try:
            size_bytes += os.path.getsize(aj)
        except Exception:
            pass
        try:
            with open(aj) as fp:
                for line in fp:
                    try:
                        d = json.loads(line)
                    except Exception:
                        continue
                    if d.get("type") in ("user", "assistant"):
                        message_count += 1
                    if not cwd and d.get("cwd"):
                        cwd = d["cwd"]
                    msg = d.get("message")
                    if isinstance(msg, dict) and msg.get("model"):
                        model = msg["model"]
                    ts = d.get("timestamp")
                    if ts:
                        e = _epoch(ts)
                        if e is not None:
                            last_epoch = e
        except Exception:
            pass

    if last_epoch is None:
        try:
            last_epoch = os.path.getmtime(path)
        except Exception:
            last_epoch = None
    if message_count == 0:
        message_count = len(metas)

    return {
        "path": path,
        "session_id": sid,
        "project": project,
        "title": "",
        "first_user": first_user,
        "forked_from": None,
        "last_epoch": last_epoch,
        "message_count": message_count,
        "size_bytes": size_bytes,
        "model": model,
        "cwd": cwd,
    }


def main():
    seen_ids = set()
    for path in sorted(glob.glob(os.path.join(PROJECTS_DIR, "*", "*.jsonl"))):
        info = session_info_jsonl(path)
        seen_ids.add(info["session_id"])
        print(json.dumps(info, ensure_ascii=False))

    for entry in sorted(glob.glob(os.path.join(PROJECTS_DIR, "*", "*"))):
        if not os.path.isdir(entry):
            continue
        name = os.path.basename(entry)
        if not UUID_RE.match(name) or name in seen_ids:
            continue
        print(json.dumps(session_info_dir(entry), ensure_ascii=False))


if __name__ == "__main__":
    main()
