#!/usr/bin/env python3
"""Helper: dump info about all Claude Code sessions as JSONL.

One JSON object per line, fields:
  path, session_id, project, title, first_user, forked_from
"""
import glob
import json
import os
import re
import sys

PROJECTS_DIR = os.path.expanduser("~/.claude/projects")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def session_info_jsonl(path):
    sid = os.path.basename(path).removesuffix(".jsonl")
    project = os.path.basename(os.path.dirname(path))
    title = ""
    first_user = ""
    forked_from = None
    try:
        with open(path) as fp:
            for i, line in enumerate(fp):
                if i > 50:
                    break
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                if not title and d.get("customTitle"):
                    title = d["customTitle"]
                if not forked_from and isinstance(d.get("forkedFrom"), dict):
                    forked_from = d["forkedFrom"].get("sessionId")
                if not first_user and d.get("type") == "user":
                    msg = d.get("message", {}).get("content", "")
                    if isinstance(msg, list):
                        text = ""
                        for c in msg:
                            if isinstance(c, dict) and c.get("type") == "text":
                                text = c.get("text", "")
                                break
                        msg = text
                    if isinstance(msg, str):
                        msg = msg.strip()
                        if msg and not msg.startswith("<local-command") and not msg.startswith("<command-"):
                            first_user = msg.splitlines()[0][:60]
    except Exception:
        pass
    return {
        "path": path,
        "session_id": sid,
        "project": project,
        "title": title,
        "first_user": first_user,
        "forked_from": forked_from,
    }


def session_info_dir(path):
    sid = os.path.basename(path)
    project = os.path.basename(os.path.dirname(path))
    first_user = ""
    for meta in sorted(glob.glob(os.path.join(path, "subagents", "*.meta.json"))):
        try:
            with open(meta) as fp:
                d = json.load(fp)
                desc = d.get("description", "")
                if desc:
                    first_user = desc[:60]
                    break
        except Exception:
            pass
    return {
        "path": path,
        "session_id": sid,
        "project": project,
        "title": "",
        "first_user": first_user,
        "forked_from": None,
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
