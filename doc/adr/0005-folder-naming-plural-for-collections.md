# ADR-0005: Folder naming follows plural-for-collections + singular-for-concepts

- **Status:** Superseded by ADR-0021
- **Date:** 2026-05-16
- **Supersedes:** the implicit "all folders singular" hard rule set during
  M7-A (commit 6fc3d6c, AGENTS.md "Hard rule #2") is replaced by this
  nuanced rule.

## Context

During M7-A (`refactor(M7-A): v2 module contract`, May 13), a project-wide
folder rename normalised every directory name to singular:
`docs/` → `doc/`, `tests/` → `test/`, `scripts/` → `script/`,
`modules/` → `module/`, `tests/helpers/` → `test/helper/`,
`tests/unit/modules/` → `test/unit/module/`, etc.
The convention was elevated to a hard rule in `AGENTS.md`.

The original motivation was internal consistency — "always singular, no
exceptions except upstream-mandated plurals (fish `completions/`, yazi
`plugins/`, QMK `keyboards/`)".

After the rule had been in place for a few days, three observations
forced a re-evaluation:

1. **Industry convention is the opposite for collection directories.**
   Linux kernel uses `drivers/`, `tools/`, `scripts/`. Python projects
   use `tests/`, `docs/`, `scripts/`. Node/JS: `scripts/`, `tests/`,
   `node_modules/`. Rust: `tests/`, `examples/`, `benches/`. Git itself:
   `.git/hooks/`, `.git/objects/`, `.git/refs/`. The plural form is the
   default mental model for "directory containing N items of the same
   kind".

2. **The sibling repo `ycpss91255-docker/docker_harness` is itself mixed**
   — uses `doc/` (singular) at top level but `.claude/scripts/`,
   `.claude/hooks/` (plural) for collections. So "align with
   docker_harness" cannot anchor a hard rule because the anchor itself
   is inconsistent.

3. **The exception list under the all-singular rule kept growing.**
   Fish, yazi, QMK, neovim's nvimdots, tmux-powerline, lnav, and the
   `.claude/` standard layout all use plural for directories that are
   semantically "collections". Maintaining a singular convention in
   init_ubuntu while every upstream uses plural created a recurring
   "what's the exception list?" question.

## Decision

Adopt a more nuanced rule that maps to how directories are
semantically used:

- **Collection directories** (multiple items of the same kind) → plural.
  Examples: `tests/`, `scripts/`, `hooks/`, `docs/`, `modules/`,
  `templates/`, `tools/`, `helpers/`, `agents/`, `processes/`.

- **Concept / role directories** (one named thing) → singular.
  Examples: `lib/` (the library), `bin/` (the binaries dir, fixed name),
  `src/` (the source).

- **Uncountable nouns** → singular.
  Examples: `config/`, `changelog/`, `data/`.

- **Acronyms** → preserve as written; both forms acceptable but use the
  form already conventional for that acronym. Examples: `adr/`
  (architectural decision records — `adr/` is more common than `adrs/`
  in OSS), `prd/`, `ci/`.

- **Non-collection categorical names** → singular. Examples:
  `tests/unit/`, `tests/integration/` (the words "unit" and
  "integration" are categories, not "multiple units" — pytest's
  convention also keeps these singular).

- **Upstream-imposed names** → keep whatever the upstream uses, even if
  it violates the rule above. Examples: fish's `completions/`,
  `functions/`; QMK's `keyboards/`; tmux-powerline's `segments/`,
  `themes/`; lnav's `formats/`; neovim nvimdots' `configs/`, `plugins/`,
  `lsp-servers/`. These are non-negotiable because the upstream tool
  reads them by name.

## Alternatives considered

### A. Keep singular-only (M7-A's original rule)

Pros: maximum internal consistency; one mental model.

Cons:
- Misaligned with every upstream tool's layout
- Misaligned with all major OSS projects
- Long-running exception list (≥ 6 upstreams already)
- Caused this re-evaluation immediately after enforcement

Rejected.

### B. Plural-only for everything

Pros: simpler than the nuanced rule.

Cons:
- Breaks `lib/` (universal singular convention)
- Breaks `bin/` (POSIX convention)
- "Configs/" for `config/` reads wrong (configuration is uncountable)
- Some directories really are single-concept (`src/`, `cmd/`)

Rejected.

### C. No rule, mix as needed

Pros: zero friction.

Cons:
- Drift accumulates over time
- New contributors have no anchor
- Past evidence (M7-A) shows lack of an anchor leads to ad-hoc inconsistency

Rejected.

## Consequences

### Positive

- Aligns with industry conventions (zero learning curve for OSS contributors)
- Naturally absorbs upstream-mandated plurals without an exception list
- Maps directly to semantic intent (multiple-of-X vs single-named-thing)

### Negative / cost

- One-time rename churn (this commit, 13 directory renames + ~30 file
  reference updates). See the `Changed` section of the next CHANGELOG
  entry.
- "Plural-vs-singular" judgement calls still needed for borderline
  names — but the underlying principle (semantic intent) gives a default
  answer for each.

### Migration applied in the commit that lands this ADR

Renamed:
`doc/` → `docs/`,
`doc/agent/` → `docs/agents/`,
`doc/process/` → `docs/processes/`,
`module/` → `modules/`,
`module/tool/` → `modules/tools/`,
`script/` → `scripts/`,
`script/hook/test-must-use-docker.sh` → `.claude/hooks/test-must-use-docker.sh`
(also relocated from `scripts/hook/` to `.claude/hooks/` since all
remaining hooks are Claude PreToolUse and live under `.claude/hooks/`,
matching docker_harness `.claude/hooks/` convention and `.git/hooks/`),
`test/` → `tests/`,
`test/helper/` → `tests/helpers/`,
`test/unit/module/` → `tests/unit/modules/`,
`template/` → `templates/`.

Kept singular:
`lib/`, `docs/adr/`, `docs/changelog/`, `docs/prd/`, `modules/config/`,
`modules/submodule/` (legacy, deprecated path — not worth churn),
`scripts/ci/`, `tests/unit/`, `tests/integration/`.

`AGENTS.md` Hard rule #2 rewritten to point at this ADR instead of
prescribing singular-only.

## References

- M7-A original singular rule: commit 6fc3d6c.
- `[[feedback-folder-plural-for-collections]]` memory entry (new in
  this commit) records the lived experience that led to the revert.
