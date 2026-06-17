# Domain Docs

How the engineering skills should consume this repo's domain documentation when
exploring the codebase.

> **Repo convention**: Folder names are singular here (hard rule). ADR path is
> `doc/adr/`, not `docs/adr/`. The seed templates in the upstream skill use
> plural names — translate accordingly when reading skill instructions.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root — domain glossary (Module / Archetype /
  Lifecycle / Phase / Engine / Standalone / Sidecar / State / Config / Manual
  flag + flagged ambiguities).
- **`doc/adr/`** — read ADRs that touch the area you're about to work in:
  - `0001-standalone-engine-state-boundary.md`
  - `0002-all-lifecycle-functions-mandatory.md`
  - `0003-language-choice-and-migration-triggers.md`
  - `0004-tests-must-run-in-docker-only.md`
- **`doc/module-spec.md`** — single source of truth for module v2 contract.
- **`doc/prd/init-ubuntu.prd.md`** — product spec, §13.2 captures past
  grilling decisions (Q1–Q31).
- **`doc/architecture.md`** — engine layering, state.json + sidecar locations.

If any of these don't exist, **proceed silently**. Don't flag absence; don't
suggest creating them upfront. The producer skill (`/grill-with-docs`) creates
them lazily when terms or decisions actually get resolved.

## File structure

This is a single-context repo:

```
/
├── CONTEXT.md
├── doc/
│   ├── adr/
│   │   ├── 0001-standalone-engine-state-boundary.md
│   │   ├── 0002-all-lifecycle-functions-mandatory.md
│   │   ├── 0003-language-choice-and-migration-triggers.md
│   │   └── 0004-tests-must-run-in-docker-only.md
│   ├── architecture.md
│   ├── module-spec.md
│   ├── prd/
│   └── TESTING.md
├── lib/
├── module/
└── test/
```

No `CONTEXT-MAP.md` — there is exactly one context for the whole repo.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor
proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md`.
Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal — either
you're inventing language the project doesn't use (reconsider) or there's a
real gap (note it for `/grill-with-docs`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than
silently overriding:

> _Contradicts ADR-0004 (Docker-only tests) — but worth reopening because…_

Note that ADR-0004 is enforced via a PreToolUse hook
(`.claude/hook/test-must-use-docker.sh`); contradicting it isn't just a docs
issue, it'll get blocked at tool invocation time.
