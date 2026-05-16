# Memory index

- [User profile](user-profile.md) — single-maintainer, personal-use, multi-platform (x86_64 / rpi4 / rpi5 / jetson)
- [Unify formats](feedback-unify-formats.md) — never maintain two parallel sources of truth for the same fact; unify
- [Folder naming](feedback-folder-plural-for-collections.md) — plural for collections, singular for concepts (per ADR-0005)
- [Memory location](reference-memory-location.md) — memory + session state live in repo at `.claude/projects/`, symlinked from `~/.claude/projects/`
- [Use Monitor for CI](feedback-use-monitor-for-ci.md) — never poll CI / long jobs; use Monitor tool for streaming events
