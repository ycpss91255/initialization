---
name: feedback-unify-formats
description: When two formats or two sources of truth need maintaining for the same fact, unify them — don't keep both
metadata:
  type: feedback
---

When you find a place where the same fact is expressed in two formats / two
files / two systems that must be kept in sync, **unify them**. Don't ship a
"we'll maintain both" answer.

**Why:** User stated this verbatim — `"後續如果有不合理的類似這種需要維護兩套的都要做統一"`.
Context: this came up during the M7-A v2 contract refactor where the original
design had separate `DESCRIPTION_EN` / `DESCRIPTION_ZH_TW` scalar variables.
The user pushed for `declare -A` with language-keyed entries because the
scalar approach forced two parallel edits per i18n change. Same principle
applied later to:
- Standalone vs engine state writes (ADR-0001 resolved which writes Sidecar)
- `CLAUDE.md` vs `AGENTS.md` (resolved by symlinking CLAUDE.md → AGENTS.md)
- `setup_ubuntu update` vs lifecycle `update()` (renamed lifecycle to
  `upgrade()` to remove the name collision)

**How to apply:** Before proposing a design that maintains two parallel
expressions of the same fact, stop and find the unifying primitive. Two
formats is almost never the right answer — usually it's an unowned design
decision being deferred. If genuinely needed (e.g. legacy compat), call it
out explicitly and put it in an ADR with an explicit migration path.

Related: [[user-profile]] (personal-use scope means there's rarely a real
legacy-compat obligation that forces dual-format).
