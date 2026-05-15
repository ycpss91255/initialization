# Changelog

All notable changes to `init_ubuntu` are documented here.

The format is based on
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning 2.0.0](https://semver.org/),
with project-specific bump rules (see `docs/processes/release.md`):

- **X bump** (`v1.0.0`, `v2.0.0`) — ceremonial; requires explicit user ACK.
- **Y bump** (`v0.1.0`, `v0.2.0`) — features + breaking changes; requires
  `vX.Y.0-rcN` tag with passing CI before promotion to `vX.Y.0`.
- **Z bump** (`v0.1.1`, `v0.1.2`) — bug fix only; no RC, no ACK.

PR-time CHANGELOG entries: add to `[Unreleased]` as part of the change PR,
not deferred to release. `release-tag.sh` promotes `[Unreleased]` →
`[vX.Y.Z] - YYYY-MM-DD` automatically.

---

## [Unreleased]

### Added

#### M1 — PRD + architecture + module contract (commit 50a41eb)

- Product spec at `docs/prd/init-ubuntu.prd.md` covering MVP scope, milestones
  (M1-M15), acceptance criteria, exit codes, CLI surface, state model.
- System architecture at `docs/architecture.md` covering engine layering
  (dispatcher / runner / registry / resolver / state).
- Module v1 contract at `docs/module-spec.md` defining metadata schema,
  lifecycle functions, archetype concepts.

#### M2 — Test harness (commit 82b5a7e)

- Borrowed + customized `ycpss91255-docker/base` v0.28.0 test rig.
- Docker-only test execution via `Makefile` + `scripts/ci/ci.sh` +
  `compose.yaml`.
- bats unit + integration test infrastructure at `tests/unit/` and
  `tests/integration/`.

#### M3 — Engine basics: logger, helpers, environment detection (commits 4502ecc, 62b173f)

- `lib/logger.sh` with JSONL `log_event` for structured CI-friendly logs.
- `lib/general.sh` with portable helpers (`have_sudo_access`, `is_wsl`, ...).
- `lib/detect.sh` + `lib/platform.sh` with `INIT_UBUNTU_FORM_FACTOR`
  classifier (desktop / server / wsl / container variants).

#### M4 — Module engine: registry, resolver, runner, state (commits 41fca5f, 6827b79, c5af7a4)

- `lib/registry.sh` — module discovery, metadata extraction, DEPENDS_ON
  graph build.
- `lib/resolver.sh` — topological sort with cycle detection +
  CONFLICTS_WITH validation.
- `lib/runner.sh` — per-phase orchestration with sub-shell isolation,
  JSONL phase events, state.json recording.
- `lib/state.sh` — `${XDG_STATE_HOME}/init_ubuntu/state.json` with flock,
  import/export, atomic writes.
- `modules/apt-essentials.module.sh` — reference module (apt archetype).
- `modules/docker.module.sh` — reference module (custom archetype).
- `templates/module.template.sh` — v1 module skeleton.
- `tests/unit/e2e_spec.bats` — end-to-end install/remove dry-run.

#### M5 — CLI + sync + apt-style subcommands (commit be6e5b1)

- `setup_ubuntu.sh` dispatcher with apt-aligned subcommands:
  `install / remove / purge / list / show / status / update / export /
  import / help / version`.
- `lib/sync.sh` — sync `state.json` ↔ filesystem reality after manual
  apt operations.
- `lib/config.sh` — `${XDG_CONFIG_HOME}/init_ubuntu/config.ini` reader
  with `[section.key]` access pattern.

#### M7-A — v2 module contract refactor (commit 6fc3d6c)

- All 10 lifecycle functions become mandatory (ADR-0002):
  `detect / is_recommended / is_installed / install / upgrade / remove /
  purge / verify / is_outdated / doctor`. (`upgrade` was `update` at this
  commit, renamed later in #68.)
- i18n migrated from scalar `DESCRIPTION_EN` / `_ZH_TW` to associative
  array `declare -gA DESCRIPTION=([en]=... [zh-TW]=...)`. Supported langs:
  en, zh-TW, zh-CN, ja.
- Standalone vs Engine dual-mode header: `bash modules/foo.module.sh install`
  works as a self-contained CLI without `setup_ubuntu` (ADR-0001 defines
  the Sidecar vs state.json write split).
- Archetype macros `module_use_apt_archetype` / `_github_release_` /
  `_config_` — one-line lifecycle binding.
- Metadata fields trimmed: dropped MAINTAINER, RECOVERY_FALLBACK,
  PARALLEL_GROUP, INSTALL_TIME_ESTIMATE, DISK_SPACE_ESTIMATE.
- Folder naming convention enforced (singular):
  `docs/` → `docs/`, `tests/helpers/` → `tests/helpers/`,
  `tests/unit/modules/` → `tests/unit/modules/`, `modules/tools/` →
  `modules/tools/`. Hook `.claude/hooks/test-must-use-docker.sh` enforces
  Docker-only test execution (ADR-0004).
- ADRs 0001-0004 introduced (`docs/adr/`):
  0001 standalone/engine state boundary,
  0002 all 10 lifecycle functions mandatory,
  0003 language choice + migration triggers,
  0004 tests-must-run-in-docker-only.
- `CONTEXT.md` domain glossary added.
- Refactored 10 v2 modules: apt-essentials, docker, fish, font,
  git-config, neovim, nvidia-driver, shell, ssh-config, tmux.

#### M7-#68 — Template split into 4 archetypes (commit 57df2e3)

- `templates/module.template.sh` (unified, all archetypes commented out)
  replaced with 4 specialized templates:
  - `templates/module-apt.template.sh` (archetype A)
  - `templates/module-github-release.template.sh` (archetype B)
  - `templates/module-config.template.sh` (archetype C)
  - `templates/module-custom.template.sh` (archetype D, hand-written)
- `tests/unit/template_consistency_spec.bats` — hash-compares shared
  sentinel-delimited sections (shared-bootstrap / shared-metadata /
  shared-lifecycle-stubs / shared-footer) across the 4 templates to
  detect drift.
- `tests/unit/template_smoke_spec.bats` — rewritten to iterate the 18
  smoke checks (`--help` / `--version` / install/upgrade/remove/purge/
  verify --dry-run / is-installed / is-outdated / doctor / info /
  status / source-mode / no-side-effects) across all 4 archetypes.
- Test count: 255 → 267 (8 new archetype-iterating smoke + 11 consistency).

#### Engine: upgrade / verify subcommands + state.json fields (issue #7)

- `setup_ubuntu upgrade [<module>...] [-y] [--dry-run]` — calls each
  module's `upgrade()` (was previously misrouted to `runner_install`).
  No args = upgrade every module recorded in `state.json` as
  installed. Engine refuses root for the real-run path
  (PRD §10), dry-run + empty-modules paths stay root-safe.
- `setup_ubuntu verify [<module>...] [--dry-run]` — new subcommand,
  calls each module's `verify()`. No args = verify all installed.
  Safe to invoke as root (no apt mutation).
- `lib/runner.sh`: `runner_upgrade` / `runner_verify` / `runner_doctor`
  added on top of the generic `_runner_run_phase`. All three
  hand off to module's `upgrade()` / `verify()` / `doctor()` per
  ADR-0002.
- `lib/state.sh`:
  - `state_record_upgrade <name> <version>` — stamps
    `version_provided` + `last_upgraded_at` (ISO 8601 UTC).
    No-op if the module isn't in `.installed`.
  - `state_record_verify <name>` — stamps `last_verified_at`.
- Runner state-recording switch (`_runner_run_phase`) updated:
  on successful `upgrade` → `state_record_upgrade`; on successful
  `verify` → `state_record_verify`. Existing `install` /
  `remove` / `purge` recording unchanged.
- Tests: 267 → 278 (5 new runner phase tests + 6 state-record
  tests).

`setup_ubuntu doctor` per-module behaviour (running each module's
`doctor()` instead of the existing state-drift detection) is
deferred to a follow-up — `runner_doctor` is implemented but the
existing `_dispatcher_doctor` keeps its current state-drift
semantics until the design question (state-drift vs per-module
doctor()) is decided.

#### Release workflow — port from docker_harness#22 + #106 (commit 1b40cfb)

Alignment with `ycpss91255-docker/docker_harness` release infrastructure:

- `.claude/scripts/release-tag.sh` — canonical primitive for cutting
  version tags. Decision tree: RC tag short-circuits; `Z>0` patch
  short-circuits; `Y` bump requires passing `vX.Y.0-rcN` CI; `X` bump
  also requires `RELEASE_X_BUMP_ACK=<tag>`. Verifies `.version`
  literal matches the tag.
- `.claude/skills/semver-bump/SKILL.md` — agent-facing companion.
- `.claude/hooks/enforce_semver_tag_via_script.sh` — DENIES ad-hoc
  `git tag v*` / `git push origin v*` / `git push --tags`; forces
  callers through `release-tag.sh`.
- `.claude/hooks/check_main_fresh_before_worktree.sh` — BLOCKs
  `git worktree add ... main` when local main is behind origin/main.
- `.claude/hooks/remind_main_sync.sh` — non-blocking reminder on
  `gh pr merge` to `git pull --ff-only origin main` after merge.
- `.claude/hooks/check_changelog_drift.sh` — non-blocking reminder when
  `git commit` stages non-doc code without a CHANGELOG entry.
- `.claude/hooks/enforce_gh_body_file.sh` — enforces `--body-file`
  convention on `gh issue/pr create/comment` (docker_harness
  gh-artifact-format skill rules 1-8).
- `.claude/hooks/enforce_gh_english.sh` — **new (not in docker_harness)**:
  DENIES `gh issue/pr create/comment` whose title / body contains CJK
  characters. Project rule: GitHub interaction is English-only.
- `docs/processes/release.md` — release workflow documentation.
- `docs/processes/worktree.md` — already in [Unreleased] under Phase 1
  (commit 6e840d1).
- `.version` — `v0.0.0` baseline (commit 6e840d1).
- All 7 hooks registered in `.claude/settings.json`.

### Changed

- **Folder naming reverted to plural-for-collections + singular-for-concepts**
  (ADR-0005). M7-A's "all folders singular" hard rule is replaced after
  three observations forced a re-evaluation: industry convention is
  plural for collections (Linux kernel, Python, Rust, Git internals);
  sibling repo `ycpss91255-docker/docker_harness` is itself mixed; the
  exception list for upstream-mandated plurals kept growing. Renames:
  `doc/` → `docs/`, `doc/agent/` → `docs/agents/`,
  `doc/process/` → `docs/processes/`, `module/` → `modules/`,
  `module/tool/` → `modules/tools/`, `script/` → `scripts/`,
  `script/hook/test-must-use-docker.sh` → `.claude/hooks/test-must-use-docker.sh`
  (also relocated since all hooks are Claude PreToolUse, matching
  docker_harness `.claude/hooks/`), `test/` → `tests/`,
  `test/helper/` → `tests/helpers/`,
  `test/unit/module/` → `tests/unit/modules/`,
  `template/` → `templates/`. Kept singular: `lib/`, `docs/adr/`,
  `docs/changelog/`, `docs/prd/`, `modules/config/`,
  `modules/submodule/` (deprecated path), `scripts/ci/`,
  `tests/unit/`, `tests/integration/`. AGENTS.md Hard rule #2
  rewritten to point at ADR-0005.
- **Lifecycle phase rename: `update()` → `upgrade()`** (commit 57df2e3).
  PRD §5.1 / §13.2 has long aligned the CLI with apt
  (`setup_ubuntu update` = registry rescan, `setup_ubuntu upgrade` = run
  lifecycle upgrade) but the implementation still defined module-level
  `update()`. Renamed across:
  - `lib/module_helper.sh` archetype macros, default implementations,
    standalone CLI accepted phases, dryrun_guard labels, `--help` text.
  - 6 v2 modules (apt-essentials, docker, fish, font, nvidia-driver,
    tmux).
  - `tests/unit/module_helper_spec.bats` archetype function-list assertion.
  - `setup_ubuntu update` (registry rescan subcommand) **unchanged**.
- **File rename: `lib/module_helpers.sh` → `lib/module_helper.sh`**
  (commit 57df2e3). Folder-name singular convention extended to filenames;
  `git mv` preserves history; all 16 references updated.
- AGENTS.md + `docs/agents/{issue-tracker,triage-labels,domain}.md` added
  (commit 68dcf55) for `setup-matt-pocock-skills` scaffolding;
  `CLAUDE.md` is a symlink to `AGENTS.md` so Claude Code and
  AGENTS.md-aware CLIs read the same content.
- `.claude/` and `CLAUDE.md` un-gitignored (commit 1a8f44c). Project-wide
  Claude Code config (hooks, plugins) moved into tracked
  `.claude/settings.json`; only `.claude/settings.local.json`
  (machine-specific permission allow-list) remains gitignored. The
  Docker-only PreToolUse hook now follows the repo on clone.

### Fixed

- `module_default_apt_is_installed`: `${#APT_PKGS[@]:-0}` bad-substitution
  under `set -u` (would crash if an apt-archetype module's smoke test
  triggered the macro path) — replaced with `declare -p` existence
  check (commit 57df2e3).
- `module_standalone_usage` `--help` text missing `upgrade` phase
  (commit 57df2e3).
- PreToolUse hook `test-must-use-docker.sh` false-positive on commit
  messages and grep output containing literal "host bats" /
  "apt-get install" (commit 97e8c0e) — added first-token whitelist of
  safe commands (git, grep, sed, awk, ...).

### Removed

- Legacy `templates/{func,module,submodule,test}_tmp.sh` (commit 6fc3d6c).
- Legacy `modules/setup_*.sh` scripts being replaced by v2 modules
  (incremental, per M7 batch).
- 5 metadata fields no longer carried: MAINTAINER, RECOVERY_FALLBACK,
  PARALLEL_GROUP, INSTALL_TIME_ESTIMATE, DISK_SPACE_ESTIMATE (commit
  6fc3d6c).

---

[Unreleased]: https://github.com/ycpss91255/initialization/compare/...HEAD
