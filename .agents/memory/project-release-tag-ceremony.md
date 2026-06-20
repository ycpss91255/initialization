---
name: project-release-tag-ceremony
description: "How init_ubuntu cuts version tags — release-tag.sh semver rules, RC requirement, .version sync"
metadata: 
  node_type: memory
  type: project
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
---

Tags are cut via `.claude/script/release-tag.sh <tag>` (exit-code-contract script; see [[prefer-hook-over-memory]] for why process lives in scripts/hooks). Rules (aligned with docker_harness#106):

- `vX.Y.Z-rcN` (the RC tag itself) → tag + push, no checks.
- `vX.Y.Z` where Z>0 (bug fix) → tag + push, no RC needed.
- `vX.Y.0` where Y bumped (feature/behaviour) → **requires a prior `vX.Y.0-rcN` whose CI is all success/skipped** before the final tag is allowed.
- `vX.0.0` where X bumped → above PLUS `RELEASE_X_BUMP_ACK=<exact-tag>` env var.

Also: a root `.version` file (currently `v0.0.0`) must equal the tag literal verbatim, so each tag step needs a matching `.version` bump committed to main first.

So cutting **v0.1.0** (a Y bump) is a multi-step ceremony, not one command: bump `.version`→`v0.1.0-rc1` → tag `v0.1.0-rc1` → RC CI green → bump `.version`→`v0.1.0` → tag `v0.1.0`. The `semver-bump` skill + `doc/process/release.md` are the canonical drivers.

0.1.0 ship gate (PRD §11.1): all `v0.1-mandatory` ACs green. That label is a PRD-table column, NOT a GitHub label — progress is tracked via the GitHub **0.1.0 milestone** (§12). As of 2026-06-18 that milestone is open=0 / closed=55 (complete); #77 is the post-tag real-hardware acceptance (user's job).
