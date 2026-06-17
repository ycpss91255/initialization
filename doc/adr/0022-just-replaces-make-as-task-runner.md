# ADR-0022: `just` replaces `make` as the task runner

- **Status:** Accepted
- **Date:** 2026-06-18
- **Relates to:** ADR-0003 (language choice), ADR-0004 (tests run in Docker only)

## Context

init_ubuntu's CI entry points lived in a plain `Makefile`, whose header
records that it was borrowed from `ycpss91255-docker/base` v0.28.0
(commit ade915a) `Makefile.ci`. `base` is the upstream source of this
repo's CI harness (`Dockerfile.test-tools` / `script/ci/ci.sh` /
`.codecov.yaml`). `base` has since migrated to `just` as its single task
runner (v0.41.0, ADR-00000005 "just is the single runner") and retired
its `Makefile.ci`. Not following lets init_ubuntu drift from the source
of its harness.

Two concrete problems with `make` here:

1. **make is used purely as a task runner.** The repo uses none of make's
   real value — dependency graphs, incremental rebuilds, timestamp
   tracking. Every target just shells out to `./script/ci/ci.sh`. The
   tab-sensitivity, `.PHONY` boilerplate, and `$$` escaping are pure
   overhead for that use.
2. **Argument passing is awkward.** CI invokes
   `make coverage-unit MODULE=core TEST_TOOLS_PREBUILT=1` (make-variable
   style). `just` recipe parameters (`just -f justfile.ci coverage-unit core`)
   are far cleaner, and env toggles read naturally as a prefix
   (`TEST_TOOLS_PREBUILT=1 just …`).

This is framed honestly as an **alignment + ergonomics** migration, not a
functional requirement.

## Decision

1. **`just` is the single task runner; `make` is retired.** The `Makefile`
   is deleted in the same change set (hard cut — no `Makefile` alias kept,
   since make/just arg styles differ and an alias cannot forward them
   painlessly, and a kept alias would be a second source of truth).
2. **Two just files**, mirroring `base`'s split:
   - `justfile.ci` — the CI / test gate (`just -f justfile.ci <recipe>`),
     a 1:1 port of the old Makefile targets (`test` / `test-unit` /
     `test-integration` / `lint` / `coverage` / `coverage-unit` /
     `coverage-merge` / `build-test-tools` / `clean`; `help` → `default`).
   - `justfile` — the auto-discovered user-facing file (net-new), thin
     pass-through wrappers around the host entry scripts.
   > Filenames follow init_ubuntu's existing "plain" decision (the same
   > rationale that renamed base's `Makefile.ci` → plain `Makefile`): we
   > align with base on the **recipe conventions and interface**, not the
   > filename.
3. **init_ubuntu-specific mechanics base lacks are preserved:**
   - Content-keyed image tag (`TEST_TOOLS_IMAGE` via
     `script/ci/resolve_test_tools_tag.sh`) using just `export` +
     backtick assignment + `env_var_or_default` (an explicit
     `TEST_TOOLS_IMAGE` on the command line / env still wins, mirroring
     the Makefile `ifeq origin undefined`).
   - `MODULE=<name>|core` → just positional recipe parameter
     (`test-unit module=""`).
   - The `TEST_TOOLS_PREBUILT=1` toggle. **just has no conditional
     dependencies**, so the Makefile `ifeq` that toggled `$(TEST_TOOLS_DEP)`
     is reproduced by a hidden, always-run `_ensure-image` dep whose BODY
     is conditional: it builds the image unless `TEST_TOOLS_PREBUILT=1`.
     `ci.sh`'s CLI is unchanged — the conditional is not folded into it.
4. **`just` binary provisioning** (following base):
   - CI runner: `extractions/setup-just@v3` (ubuntu-latest ships no
     `just`; the official install.sh returns 403 from GHA runners).
   - test-tools image: `apk add --no-cache just` in
     `dockerfile/Dockerfile.test-tools` (keeps in-container invocations
     working).
   - Dev host: must install `just` manually (documented in
     `doc/TESTING.md`).

## Consequences

- A **new binary dependency** (`just`) is introduced — the honest
  trade-off. It is mitigated: CI and the test-tools image provision it
  automatically, and a single-maintainer personal repo can install it
  once on each dev host.
- All references to `make` / `Makefile` are updated atomically in the same
  change set: `.github/workflows/ci.yaml`, the docker hook whitelist
  (`just` added as a safe first token), `script/ci/generate_module_filters.sh`
  (+ its spec), docs (`TESTING.md`, `architecture.md`, `worktree.md`,
  `module-authoring.md`, the PRD), ADR-0004, `AGENTS.md`/`CONTEXT.md`,
  templates, `compose.yaml` comments, and assorted script comments.
- **Relation to ADR-0003 — no conflict.** ADR-0003 governs the
  *implementation language* (bash, with documented migration triggers).
  ADR-0022 governs the *task-entry-point tool*. Swapping make→just does
  not change what any script is written in; ci.sh and every recipe body
  stay bash.
- **Relation to ADR-0004 — preserved.** The Docker-only test rule is
  unchanged: `justfile.ci` recipes still route through
  `./script/ci/ci.sh` → `docker compose run --rm ci …`. The
  `.claude/hook/test-must-use-docker.sh` whitelist gains `just` as a
  known-safe first token (it never runs Module Action Phases itself; the
  hook still blocks bats / module install/upgrade/remove/purge on the
  host). The user-facing `justfile` runs the real installer, which is the
  intended use for a USER on their own machine — user-facing ≠
  agent-facing.
