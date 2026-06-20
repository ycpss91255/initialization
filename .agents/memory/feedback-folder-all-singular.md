---
name: feedback-folder-all-singular
description: Folder names are all-singular (supersedes ADR-0005's plural-for-collections); see ADR-0021
metadata:
  type: feedback
---

Folder naming in init_ubuntu is **all-singular**, zero judgment calls:

- **Every repo-owned directory** → **singular**:
  `test/`, `script/`, `doc/`, `module/`, `template/`, `lib/`,
  `config/`, `changelog/`, `.claude/hook/`, `.claude/script/`.
- **Acronyms** → preserve OSS convention:
  `adr/`, `prd/`, `ci/` (not `adrs/`, `prds/`, `cis/`).
- **Upstream-imposed** → keep upstream's choice (fish `completions/` /
  `functions/`, yazi `plugins/` / `flavors/`, QMK `keyboards/`,
  tmux-powerline `segments/` / `themes/`, lnav `formats/`, nvimdots
  dirs, `.claude/skills/` / `.claude/commands/` / `.claude/agents/`
  Claude Code scan paths).
- **File names** (including ones ending in `s`, e.g.
  `apt-essentials.module.sh`) are **out of scope** — separate
  discussion deferred to 0.2.0.

**History:** M7-A set "all singular" (commit 6fc3d6c) → ADR-0005
(2026-05-16) reverted to plural-for-collections + singular-for-concepts
citing industry convention → owner re-reverted on 2026-05-21
(issue #32, ADR-0021): the per-directory "collection vs concept"
classification cost exceeded the industry-alignment benefit for a
single-maintainer repo. A zero-exception singular rule needs no
judgment; the only remaining questions are "upstream-imposed?" and
"acronym?".

**How to apply:** Name every new directory singular. Only deviate when
an upstream tool mandates the name or the name is an acronym. Never
reintroduce a collection-vs-concept distinction.

Supersedes the previous plural-for-collections memory
(`feedback-folder-plural-for-collections.md`, renamed to this file) and
ADR-0005 (now marked Superseded by ADR-0021).

Related: [[feedback-unify-formats]] (one source of truth — the naming
rule lives in ADR-0021; AGENTS.md and this memory file just point at it).
