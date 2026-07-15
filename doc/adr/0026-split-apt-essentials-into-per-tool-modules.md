# ADR-0026: split the apt-essentials bundle into independent per-tool modules

- **Status:** Accepted
- **Date:** 2026-06-21
- **Revises:** ADR-0011 (apt-essentials universal pkg list, frozen at
  install) — the freeze mechanism is retained but the single-bundle module
  it applied to is decomposed
- **Relates to:** ADR-0019 (`list --json` schema), the 0.1.0 TUI-redesign
  PRD, `doc/module-spec.md`

## Context

`apt-essentials` is one module that installs a bundle (git, vim, curl, wget,
ca-certificates, build-essential, htop, unzip, jq, software-properties-common)
as a single unit. In the redesigned two-pane TUI (ADR-0024) a category page
lists one row per **module**, and the detail pane shows that module's
description and deps.

zh-TW verification raised the complaint that "base shows one line" — the user
expects to see git, vim, curl etc. as individually selectable rows, but the
data model has them as one opaque bundle. A grilling session re-decided the
data model: the user wants them as **independent modules**, each installable /
removable on its own (accepting that this is an engine / module-spec change).
The maintainer scoped this into 0.1.0 ("first release ships the complete data
model").

This interacts with ADR-0011: that ADR froze the resolved pkg list per host so
`is_installed` / `upgrade` stay deterministic. Per-tool modules where each
tool is a single apt package make the freeze largely moot for the simple
cases, but the freeze is still meaningful for any module that itself resolves
to a *set* of packages on a given platform.

## Decision

**Decompose the `apt-essentials` bundle into independent per-tool modules.**
Each tool that a user would reasonably want to install or remove on its own
becomes its own `module/<name>.module.sh` (archetype A, apt-only), with its
own lifecycle and its own `depends_on`.

1. **One module per independently-meaningful tool** (e.g. git, vim, curl,
   wget, build-essential, htop, jq, unzip). `ca-certificates` /
   `software-properties-common` and similar plumbing that nothing uses
   directly may stay as dependencies of the modules that need them rather
   than user-facing rows.
2. **`depends_on` replaces the bundle.** Modules that previously assumed the
   whole bundle was present now declare the specific tools they need (e.g. a
   build module `depends_on build-essential`). The resolver pulls them; the
   provenance shows "(required by X)" in the TUI Review screen.
3. **The ADR-0011 freeze mechanism is retained per module**, not for one
   bundle: a module whose install resolves to a *set* of packages on a given
   platform still freezes `frozen_pkgs` / `frozen_platform`. A module that is
   exactly one apt package needs no freeze (its `is_installed` is a single
   `dpkg -l`).

   > **Clarification (2026-07-14):** in practice the per-module freeze was
   > never actually built into a live module — every module shipped is either a
   > single apt package or a custom archetype, none of which resolve to a
   > platform-dependent *set*. The dead ADR-0011 migration/freeze code
   > (`frozen_pkgs` / `frozen_platform` state fields + the state-migration path)
   > was retired in PR #373. Per-module freeze therefore remains a **future
   > design option only**: if a future module ever needs to pin a
   > platform-resolved package set, this is the sanctioned mechanism to
   > reintroduce, but no current code depends on it.
4. **The compatibility-exclusion concept survives** as per-module platform
   guards (a module simply does not `detect` / install on a platform that
   can't support it) rather than one `INCOMPAT_BY_PLATFORM` map on the bundle.
5. **base category membership** is reassigned: the per-tool modules that
   constitute the universal devel base carry `category = base` so Quick
   Setup still installs them by default, but each is now its own selectable
   row in the TUI.

## Drivers

- **The TUI's one-row-per-module model demands real modules**, not a bundle,
  for "git on its own line, curl on its own line" to be possible without a
  display-only hack.
- **Granular install/remove** matches the apt mental model the whole product
  is built on (CONTEXT.md): a user can `remove vim` without losing git.
- **Cleaner dependency graph.** Modules declare exactly the tools they need
  instead of assuming an opaque bundle is present.

## Alternatives considered

- **Display-only expansion** (keep one module, render its package list as
  read-only sub-rows). Rejected by the maintainer: the sub-rows would not be
  independently installable/removable, which is the actual want.
- **Keep the bundle, show the package list only in the detail pane.**
  Rejected for the same reason — informative but not selectable.
- **Defer to 0.2.0.** Rejected by the maintainer's scope call: the first tag
  ships the complete data model so the TUI redesign lands against real
  modules, not a bundle plus a later migration.

## Consequences

- **`module/apt-essentials.module.sh` is removed**; its tools become
  `module/git.module.sh`, `module/vim.module.sh`, etc. ADR-0011's AC-36 /
  AC-37 / AC-37b are re-expressed against the new modules (or retired where a
  one-package module makes them trivial).
- **State migration**: existing state recording `apt-essentials` as installed
  must map to the new per-tool modules (forward-only, ADR-0008). The
  migration marks the constituent tools installed so upgrades keep working.
- **Sync (ADR-0013)**: per-tool modules sync individually; the bundle-level
  `frozen_pkgs` convergence note in ADR-0011 no longer applies to a single
  bundle but to whichever modules still freeze a set.
- **PRD §6.1 (base catalog)** is rewritten to list the per-tool modules.
- This is a 0.1.0 blocker by the maintainer's scope decision; it is the
  engine/data-model half of the 0.1.0 TUI-redesign PRD.
