# ADR-0029: Standardize one-off bash tools on a template + test pattern

- **Status:** Accepted
- **Date:** 2026-07-04
- **Refs:**
  - ADR-0007 (exit-code-contract scripts default to `set -uo`) —
    `doc/adr/0007-exit-code-contract-scripts-default-to-set-uo.md`
  - ADR-0004 (tests must run in Docker only) —
    `doc/adr/0004-tests-must-run-in-docker-only.md`
  - PRD §6.5 / §6.6 (one-off tools vs modules-for-reusables) —
    `doc/prd/init-ubuntu.prd.md`
  - Template: `template/tool.template.sh`
  - Spec: `test/unit/tool_template_spec.bats`
  - Guide: `doc/guide/small-tool-template.md`

## Context

`init_ubuntu` has a `tool/` area (plus a handful of small helper scripts) for
genuine **one-off** bash scripts — personal host tweaks, machine-specific syncs,
"run this once" fixes. Unlike modules, they have no
`is_installed/install/upgrade/remove/purge` lifecycle, are not resolved by the
engine, and hold no `state.json` entry.

An audit found these ~16 one-off scripts had drifted into an inconsistent,
fragile shape:

- none carried a `--help`;
- most lacked explicit `set` flags — a **missing `set -u` already caused live
  bugs** (unset-variable expansion silently doing the wrong thing);
- zero were tested;
- none had a `--dry-run`, so there was no safe way to preview a mutation.

There was no canonical skeleton to copy, so every new one-off reinvented the
shape (usually badly). Modules already have four archetype templates and
conformance tests; one-off tools had nothing equivalent.

The maintainer approved a standard skeleton (with the repo logger) for this
purpose. It is explicitly **not** for reusable tools — those get promoted to
full modules (PRD §6.5/§6.6).

## Decision

**1. Adopt a single template for one-off tools: `template/tool.template.sh`.**
Every new `tool/` script starts from `cp template/tool.template.sh
tool/<name>.sh`. The skeleton bakes in:

- `#!/usr/bin/env bash` + `set -euo pipefail` — the ADR-0007 *always-act*
  family. A tool performs side effects; any intermediate failure must abort the
  whole run. (This is deliberately the opposite default from the exit-code-
  *contract* scripts — hooks, `release-tag.sh` — which use `set -uo` so a probe
  returning 1 does not abort. A tool is not a probe.) `set -u` here directly
  closes the class of live bugs the audit found.
- an optional source of the **live** repo logger (`lib/logger.sh`) for
  `log_info/log_warn/log_error`, with minimal stderr shims as a fallback so the
  tool still runs if copied out of the repo.
- a `usage()` heredoc and a `main()` with the exit-code contract:
  `-h|--help -> usage; exit 0`; no args `-> run`; unknown arg `-> usage >&2;
  exit 2`. This mirrors the module CLI's `0 = ok` / `2 = usage-error` contract.
- a `--dry-run` path and **grep-guarded idempotent** work.
- an explicit **no host package installs** rule (repo hard rule #2): if a script
  needs to install a package, it is a module, not a tool.

**2. Adopt a matching test pattern: `test/unit/tool_template_spec.bats`.** It
drives a reference instantiation of the template through the three canonical
cases — `--help` exits 0 and prints usage; an unknown arg exits 2; `--dry-run`
performs no mutation — plus idempotency and the `set -euo pipefail` guardrail.
New one-off tools copy and adapt it. Tests run in Docker only (ADR-0004).

**3. Draw the tool-vs-module line explicitly.** The template header, the guide,
and this ADR all state: one-offs use this template; anything **reusable** is
promoted to a module via one of the `module-*` archetype templates (PRD
§6.5/§6.6). A `tool/` script must not grow into a pseudo-module.

## Consequences

- New one-off tools are consistent, self-documenting (`--help`), previewable
  (`--dry-run`), idempotent, and crash-safe (`set -euo pipefail`) by default.
- The missing-`set -u` bug class is closed for anything built from the template.
- One-off tools become testable with a copy-paste spec; the template itself is
  guarded by `tool_template_spec.bats` so drift is caught.
- Existing `tool/` scripts are **not** retrofitted by this ADR; migrating them
  onto the template is follow-up work. This ADR establishes the standard for new
  and migrated tools.
- The tool/module boundary is now written down, reducing the temptation to let a
  one-off accrete lifecycle logic instead of being promoted.

## Considered Options

- **Do nothing / keep ad-hoc scripts.** Rejected: the audit showed this produces
  no `--help`, missing `set` flags (live bugs), and zero tests.
- **Force every one-off into a full module.** Rejected: modules carry lifecycle,
  engine resolution, and `state.json` overhead that genuine one-offs do not need;
  PRD §6.5/§6.6 already distinguishes the two. Over-modularizing one-offs adds
  ceremony without value.
- **Reuse the `module-custom` template for tools.** Rejected: it drags in the
  10-function lifecycle, dual-mode bootstrap, and metadata/i18n surface that a
  one-off does not have. A dedicated, smaller skeleton keeps one-offs one-off.
