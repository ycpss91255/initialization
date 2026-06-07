# ADR-0021: Folder naming is all-singular

- **Status:** Accepted
- **Date:** 2026-05-21
- **Supersedes:** ADR-0005 (plural-for-collections + singular-for-concepts)

## Context

ADR-0005 (2026-05-16) replaced the original M7-A "all folders singular"
hard rule with a nuanced convention: plural for collection directories
(`docs/`, `tests/`, `scripts/`, `modules/`, `templates/`), singular for
concept / role / uncountable directories (`lib/`, `config/`,
`changelog/`), acronyms as-is (`adr/`, `prd/`, `ci/`), and
upstream-imposed layouts untouched.

On 2026-05-21 the owner decided to revert to all-singular. After living
with the ADR-0005 rule, the classification cost turned out to be the
real problem: every new directory requires a "is this a collection or a
concept?" judgment call, and borderline cases (`changelog/`, `config/`,
`worktree/`) generate exactly the kind of naming debate the convention
was supposed to eliminate. A zero-exception singular rule has no
judgment cost at all — the industry-convention benefit ADR-0005 cited
does not outweigh that for a single-maintainer personal repo.

## Decision

1. **Every repo-owned directory name is singular.** `doc/`, `test/`,
   `script/`, `module/`, `template/`, `lib/`, `config/`, `changelog/`,
   `.claude/hook/`, `.claude/script/`, etc.
2. Only two exception classes remain:
   - **Upstream-imposed layouts** keep whatever the upstream tool
     requires or ships: fish `completions/` / `functions/`, yazi
     `plugins/` / `flavors/`, QMK `keyboards/` / `keymaps/`,
     tmux-powerline `segments/` / `themes/`, lnav `formats/`, nvimdots
     `configs/` / `plugins/`, `.claude/skills/` / `.claude/commands/` /
     `.claude/agents/` (Claude Code scan paths), and similar.
   - **Acronyms** stay as-is: `adr/`, `prd/`, `ci/`.
3. **File names are out of scope.** Files whose names end in `s`
   (e.g. `apt-essentials.module.sh`) are a separate discussion,
   deferred to the 0.2.0 cycle.

## Consequences

- The repo-wide rename `docs/`→`doc/`, `tests/`→`test/`,
  `scripts/`→`script/`, `modules/`→`module/`, `templates/`→`template/`,
  `.claude/hooks/`→`.claude/hook/`, `.claude/scripts/`→`.claude/script/`
  (plus inner `agents/`→`agent/`, `processes/`→`process/`,
  `guides/`→`guide/`, `helpers/`→`helper/`, `unit/modules/`→
  `unit/module/`) lands together with this ADR (issue #32).
- New directories never need a collection-vs-concept judgment; the only
  questions are "is this upstream-imposed?" and "is this an acronym?".
- ADR-0005 is marked Superseded; its content stays as the historical
  record of why plural was tried.
- Out-of-tree consumers of renamed paths (shell history, muscle memory,
  external notes) break once; this is accepted for a personal repo.
