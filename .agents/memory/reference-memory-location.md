---
name: reference-memory-location
description: "Only memory/ should be symlinked into the repo — NOT the whole ~/.claude/projects/<key> dir, which breaks Claude's session picker / name-resume"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 8ba6bcda-c376-40fd-b42f-95fb42a5af29
---

The git-tracked **memory** for this repo lives canonically at
`<repo>/.agents/memory/` (tool-agnostic, shareable by other agent CLIs — same
canonical store as `.agents/{hook,rules,script,skills}`). It is exposed the SAME
way those are: a `<repo>/.claude/memory` symlink → `../.agents/memory` (uniform
with `.claude/hook` → `../.agents/hook` etc.). Claude's HOME-side `memory`
symlink then points at `.claude/memory` (NOT straight into `.agents`, and NOT
the whole project dir — only the `memory/` subdir).

**Correct layout (target):**
```
<repo>/.agents/memory/                                      ← REAL files (canonical, tracked)
<repo>/.claude/memory  →  ../.agents/memory                 ← symlink (tracked; uniform with .claude/{hook,rules,script,skills})
~/.claude/projects/-home-cyc-Desktop-initialization/        ← REAL directory (Claude's fixed HOME convention)
        ├── <session-id>.jsonl, <session-id>/               ← machine-local, gitignored
        └── memory  →  <repo>/.claude/memory                ← HOME symlink → .claude/memory → .agents/memory
```
Resolve chain: HOME `memory` → `<repo>/.claude/memory` → `<repo>/.agents/memory/`.
The `projects/<key>/` layer exists ONLY on the HOME side (Claude reads memory
from `~/.claude/projects/<key>/memory/` by hard convention — that part cannot
move); the repo side has nothing under `.claude/projects/`.

**Why not symlink the whole `projects/<key>` dir** (the original mistake,
2026-05 migration): Claude Code's session picker enumerates
`~/.claude/projects/` and **skips entries that are symlinks** (an
`isDirectory()`-style check is false for a symlink). So a whole-dir symlink
makes `claude -r` show no sessions and `claude -r <name>` fail to resolve —
while `claude -r <full-session-id>` still works (it opens the path directly,
following the symlink). Confirmed 2026-06-18 on v2.1.179; the
`-home-cyc-Desktop-initialization` entry was the only symlinked project and
the only one with a broken picker. Session names persist as `customTitle`
in each transcript's first JSONL line, so name-resume is otherwise supported.

**Tracking (`.gitignore`):** real memory tracked under `.agents/memory/`; the
`.claude/memory` symlink tracked (no rule ignores it); repo-side
`.claude/projects/` ignored —
```
.agents/*
!.agents/memory
!.agents/memory/**
.claude/projects/
```
Session `.jsonl` are machine-local and live under `~/.claude` (real dir), so
nothing of value is in the repo-side `.claude/projects/` (it no longer exists).

**Fix script:** `~/fix-claude-projects-symlink.sh` (idempotent; aborts if a
live claude session for the repo is running) ensures `~/.claude/projects/<key>`
is a REAL dir (not a whole-dir symlink) with `memory/` symlinked to
**`<repo>/.claude/memory`** (which in turn → `.agents/memory`), and moves
existing transcripts in so they stay resumable.

**Multi-machine note:** on another machine ([[user-profile]]: rpi4/rpi5/
jetson), recreate the `memory/`-only symlink (run the fix script there), not
a whole-dir symlink. Relates to [[feedback-prefer-hook-over-memory]].
