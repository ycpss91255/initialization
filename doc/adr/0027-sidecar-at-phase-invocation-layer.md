# Sidecar write/remove lives at the phase-invocation layer; archetype macros emit all 10 lifecycle functions

- **Status:** Accepted
- **Date:** 2026-06-21

This refines two earlier decisions without overturning them:

- **ADR-0001** pinned that the Sidecar is written by BOTH Standalone and Engine
  modes (the *whether*). It did not pin *where* in the call path the write
  happens — early modules each hand-wrote `module_sidecar_write` inside their
  own `install()`/`upgrade()` and `module_sidecar_remove` inside
  `remove()`/`purge()`. That duplicated the write across 29 of 39 modules and
  meant a new module (or a hand-written archetype-D module) could silently
  forget the Sidecar.
- **ADR-0002** made all 10 Lifecycle functions mandatory and said the archetype
  macros must provide defaults for the slots archetype users shouldn't have to
  hand-write. In practice the macros only emitted 6-7 functions; `is_outdated`
  and `doctor` were still hand-written per module (~20 copies of the same
  is_installed-plus-warn `doctor`).

## Decision

**1. The Sidecar write/remove moves to the phase-invocation layer.** One shared
helper — `_module_sidecar_after_phase <phase> <name>` (lib/module_helper.sh) —
is called from BOTH invokers, AFTER a phase succeeds:

- **Engine**: `lib/runner.sh` `_runner_run_phase`, inside the module sub-shell,
  co-located with the existing post-install dep-snapshot / action_required
  block.
- **Standalone**: `lib/module_helper.sh` `module_standalone_main`, wrapping the
  dispatched phase.

`install`/`upgrade` -> `module_sidecar_write "${name}" "$(module_provided_version)"`;
`remove`/`purge` -> `module_sidecar_remove "${name}"`. It is a no-op on
`INIT_UBUNTU_DRY_RUN=true` and for read-only / diagnostic phases. A module's
`install()` now only mutates the system; the invoker records the Sidecar. This
covers all 39 modules (including hand-written archetype-D) in both modes with a
single write site.

**2. `module_provided_version` is the standardized version hook** the wrapper
calls. It is archetype-defaulted and per-module overridable:

- apt -> `dpkg-query` of `APT_PKGS[0]`, falling back to `VERSION_PROVIDED`.
- github-release -> `MODULE_GH_RESOLVED_VERSION` (the resolved release tag,
  published by the archetype fetch helper and every module-specific resolver);
  on an idempotent re-install that short-circuited without re-resolving, it
  preserves the existing Sidecar version rather than clobbering it; final
  fallback is `VERSION_PROVIDED`.
- config -> `VERSION_PROVIDED`.
- generic default -> `VERSION_PROVIDED`, so hand-written archetype-D modules
  work without defining anything; they override when they have a real
  runtime-resolved version (e.g. claude-code parses `claude --version`).

**3. The archetype macros now emit ALL 10 Lifecycle functions.**
`module_use_apt_archetype` / `module_use_github_release_archetype` /
`module_use_config_archetype` add defaults for `is_outdated` (the existing
`module_default_*_is_outdated`) and `doctor` (a new `module_default_doctor`:
`is_installed` + a `log_warn` on failure — the pattern ~20 modules hand-wrote),
plus the `module_provided_version` hook. `detect` and `is_recommended` stay
module-defined stubs (genuinely module-specific). Modules can still override any
emitted function after the macro (bash late-binding).

## Consequences

- The per-module `module_sidecar_write`/`module_sidecar_remove` calls and the
  per-module `_xxx_pkg_version` helpers are removed from the 29 modules that had
  them; the redundant hand-written `is_outdated`/`doctor` stubs are removed from
  the modules that just repeated the default. Genuine overrides (metadata
  self-check, Sidecar-drift detection, daemon/service checks, version-compare
  `is_outdated`) stay.
- `doctor` is now strictly read-only (diagnostic): it may *warn* about a missing
  Sidecar but no longer *heals* it (re-run install/upgrade to heal). The
  binary-`--version` probe several modules ran in `doctor` is covered by
  `verify` (TEST_VERIFY_CMD); the default `doctor` tracks `is_installed`.
- The Sidecar invariant (`is_installed() == false` ↔ Sidecar absent) is
  preserved, now enforced at the invoker layer; module unit tests that asserted
  a Sidecar after calling `install()` directly route through the invoker
  (`module_standalone_main install` or the runner).
- Three pre-existing hand-written archetype-D modules (docker, font,
  nvidia-driver) still do not implement `is_outdated`/`doctor`; that gap is
  out of scope here (their tests pin the graceful exit-2 contract) and tracked
  separately.

## Considered Options

- **Keep the write in each module's lifecycle function** (status quo): rejected
  — 29 duplicated call sites, easy to forget, and impossible to enforce for
  archetype-D without copy-paste.
- **Write the Sidecar in the archetype default `install`/`remove` bodies
  only**: rejected — does not cover archetype-D (hand-written) modules, and
  modules that override `install` would lose it.
- **Emit only 6-7 functions from the macros and keep `doctor` optional**:
  rejected per ADR-0002 — optional slots make Engine behavior depend on which
  module you point it at.
