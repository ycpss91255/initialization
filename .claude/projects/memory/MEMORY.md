# Memory index

- [User profile](user-profile.md) — single-maintainer, personal-use, multi-platform (x86_64 / rpi4 / rpi5 / jetson)
- [Unify formats](feedback-unify-formats.md) — never maintain two parallel sources of truth for the same fact; unify
- [Folder naming](feedback-folder-all-singular.md) — all singular; only upstream-imposed + acronym exceptions (per ADR-0021, supersedes ADR-0005)
- [Memory location](reference-memory-location.md) — memory + session state live in repo at `.claude/projects/`, symlinked from `~/.claude/projects/`
- [Use Monitor for CI](feedback-use-monitor-for-ci.md) — never poll CI / long jobs; use Monitor tool for streaming events
- [gh OAuth token limits](reference-gh-oauth-token-limits.md) — gho_ token can GET/DELETE rulesets but not PATCH; classic branch protection PUT works
- [Branch protection convention](project-classic-branch-protection-convention.md) — ycpss91255* repos govern main via classic protection + ci-passed aggregator, not rulesets
- [Prefer hook over memory](feedback-prefer-hook-over-memory.md) — process rules go to hooks (ADR for why); memory only when a hook can't enforce
