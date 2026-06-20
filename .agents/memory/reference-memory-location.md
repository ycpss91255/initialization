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
canonical store as `.agents/{hook,rules,script,skills}`). `<repo>/.claude/
projects/memory` is a **compat symlink** into it, so Claude's HOME-side
`memory` symlink keeps resolving without touching the fragile HOME symlink.
Only the `memory/` subdir is symlinked — **not** the whole project directory.

**Correct layout (target):**
```
.agents/memory/                                             ← REAL files (canonical, tracked)
<repo>/.claude/projects/memory  →  ../../.agents/memory     ← compat symlink (tracked)
~/.claude/projects/-home-cyc-Desktop-initialization/        ← REAL directory
        ├── <session-id>.jsonl, <session-id>/               ← machine-local, gitignored
        └── memory  →  <repo>/.claude/projects/memory       ← HOME symlink (unchanged) → compat → .agents/memory
```
So the full resolve chain is HOME `memory` → repo `.claude/projects/memory` →
`.agents/memory/`.

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

**Tracking (`.gitignore`):** real memory tracked under `.agents/memory/`,
the `.claude` compat symlink tracked, sessions ignored —
```
.agents/*
!.agents/memory
!.agents/memory/**
.claude/projects/*
!.claude/projects/memory      # the compat symlink (no trailing slash)
```
Session `.jsonl` are machine-local and gitignored anyway, so keeping them
under `~/.claude` (real dir) loses nothing.

**Fix script:** `~/fix-claude-projects-symlink.sh` (idempotent; aborts if a
live claude session for the repo is running) converts the whole-dir symlink
into the correct layout above — real project dir + `memory/`-only symlink —
and moves existing transcripts in so they stay resumable.

**Multi-machine note:** on another machine ([[user-profile]]: rpi4/rpi5/
jetson), recreate the `memory/`-only symlink (run the fix script there), not
a whole-dir symlink. Relates to [[feedback-prefer-hook-over-memory]].
