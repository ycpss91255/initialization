---
name: reference-memory-location
description: Memory and session state physically live in repo at .claude/projects/, with ~/.claude/projects/...-initialization symlinked to it
metadata:
  type: reference
---

Claude Code's per-project session state for this repo was relocated from
`~/.claude/projects/-home-cyc-Desktop-initialization/` into the repo at
`<repo>/.claude/projects/`, with the user-side path replaced by a symlink:

```
~/.claude/projects/-home-cyc-Desktop-initialization → /home/cyc/Desktop/initialization/.claude/projects
```

Contents:
- `.claude/projects/memory/` — **tracked**. Memory files this skill writes.
- `.claude/projects/*.jsonl` — **gitignored**. Per-session conversation
  transcripts (50+ MB each). Useful as local fallback, never committed.
- `.claude/projects/<session-id>/` — **gitignored**. Per-session sidecar
  state (todos, file snapshots).

`.gitignore` pattern that enforces this:
```
.claude/projects/*
!.claude/projects/memory/
!.claude/projects/memory/**
```

**Implication for memory operations:** writes to memory work normally
through the system-prompt-documented path. They land in repo and version
along with everything else. Don't accidentally write to `~/.claude/projects/`
expecting it to be private — the symlink means it's the same directory.

**Multi-machine note:** If the user clones this repo on another machine
(rpi4 / rpi5 / jetson per [[user-profile]]), the symlink under `~/.claude/`
must be recreated there manually. The setup commands are documented in
this conversation's earlier turns (May 2026 M7-A migration).
