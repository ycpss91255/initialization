#!/usr/bin/env python3
"""Helper: dump info about all Claude Code sessions as JSONL.

One JSON object per line, fields:
  path, session_id, project, title, first_user, forked_from
"""
import glob
import json
import os
import sys

PROJECTS_DIR = os.path.expanduser("~/.claude/projects")


def session_info(path):
    sid = os.path.basename(path)[:-len(".jsonl")] if path.endswith(".jsonl") else os.path.basename(path)
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


def main():
    for path in sorted(glob.glob(os.path.join(PROJECTS_DIR, "*", "*.jsonl"))):
        print(json.dumps(session_info(path), ensure_ascii=False))


if __name__ == "__main__":
    main()
