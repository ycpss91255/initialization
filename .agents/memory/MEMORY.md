# Memory index

- [User profile](user-profile.md) — single-maintainer, personal-use, multi-platform (x86_64 / rpi4 / rpi5 / jetson)
- [Unify formats](feedback-unify-formats.md) — never maintain two parallel sources of truth for the same fact; unify
- [Folder naming](feedback-folder-all-singular.md) — all singular; only upstream-imposed + acronym exceptions (per ADR-0021, supersedes ADR-0005)
- [Memory location](reference-memory-location.md) — memory canonical at `.agents/memory/`, exposed via `.claude/memory` → `.agents/memory` (uniform with `.claude/{hook,rules,script,skills}`); HOME `~/.claude/projects/<key>/memory` → `.claude/memory` → `.agents/memory`; symlink ONLY `memory/` (whole-`projects/`-dir symlink breaks Claude's session picker; fix: `~/fix-claude-projects-symlink.sh`)
- [Use Monitor for CI](feedback-use-monitor-for-ci.md) — never poll CI / long jobs; use Monitor tool for streaming events
- [gh OAuth token limits](reference-gh-oauth-token-limits.md) — gho_ token can GET/DELETE rulesets but not PATCH; classic branch protection PUT works
- [Branch protection convention](project-classic-branch-protection-convention.md) — ycpss91255* repos govern main via classic protection + ci-passed aggregator, not rulesets
- [Prefer hook over memory](feedback-prefer-hook-over-memory.md) — process rules go to hooks (ADR for why); memory only when a hook can't enforce
- [Release tag ceremony](project-release-tag-ceremony.md) — release-tag.sh semver rules; Y/X bumps need a green RC first; .version must match tag; 0.1.0 = milestone (not label)
- [Autonomous test-gap remediation](feedback-autonomous-test-gap-remediation.md) — don't ask to fix bugs / close test gaps; drive via workflow; only ask on product/scope forks (e.g. cutting a release tag)
- [kcov merge exclude-region](project-kcov-merge-exclude-region.md) — --exclude-region must be on `kcov --merge` too (not just shards) or the AC-17 gate ignores it; i18n declare-gA tables count as uncovered, wrap with kcov-exclude markers
- [CI lint covers bats](project-ci-lint-covers-bats.md) — lint runs shellcheck -x on *.bats too (info severity); validate bats files with shellcheck before PR, prefer `VAR=val run ...` over a standalone `export` in @test bodies
