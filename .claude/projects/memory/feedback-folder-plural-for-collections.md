---
name: feedback-folder-plural-for-collections
description: Folder names follow plural-for-collections + singular-for-concepts (industry convention); see ADR-0005
metadata:
  type: feedback
---

Folder naming in init_ubuntu follows a **semantic** convention, not a
flat "always singular" or "always plural" rule:

- **Collection** (multiple items of same kind) → **plural**:
  `tests/`, `scripts/`, `hooks/`, `docs/`, `modules/`, `templates/`,
  `tools/`, `helpers/`, `agents/`, `processes/`.
- **Concept / role / uncountable** → **singular**:
  `lib/`, `bin/`, `src/`, `config/`, `changelog/`, `data/`.
- **Acronyms** → preserve OSS convention:
  `adr/`, `prd/`, `ci/` (not `adrs/`, `prds/`, `cis/`).
- **Non-collection categorical** → singular:
  `tests/unit/`, `tests/integration/` ("unit" / "integration" are
  categories, not counts).
- **Upstream-imposed** → keep upstream's choice (fish `completions/`,
  QMK `keyboards/`, etc.).

**Why:** Set during M7-A as "all singular" hard rule (commit 6fc3d6c).
Reverted same week after three observations:
(1) industry convention is opposite (Linux kernel `drivers/`, Python
`tests/`, Rust `tests/`, Git `.git/hooks/`);
(2) sibling repo `ycpss91255-docker/docker_harness` is itself mixed
(`doc/` singular, `.claude/scripts/` plural), so "align with
docker_harness" couldn't anchor the all-singular rule;
(3) the exception list under all-singular kept growing (fish, yazi,
QMK, neovim nvimdots, tmux-powerline, lnav all enforce plural for
their tool-managed dirs).

User: `算了改回複數好了, 行業標準好像是複數為主?` (2026-05-16). After
verifying industry data and docker_harness's actual mixed state, the
revert landed in the same commit as ADR-0005.

**How to apply:** When naming a new directory, ask "is this a
collection (multiple items) or a concept (one named thing)?" Plural
for collections, singular for concepts. For ambiguous names
(`process/` vs `processes/`), favour plural when the dir will hold
N+ items of the same kind (e.g. `docs/processes/{worktree,release}.md`).

Supersedes the previous singular hard rule (which had no separate memory
file — it was only documented in AGENTS.md and now superseded there too).

Related: [[feedback-unify-formats]] (don't maintain two parallel sources
of truth — the rename was triggered partly by the realisation that the
"all-singular" anchor and the upstream-plural reality were exactly two
parallel sources of truth).
