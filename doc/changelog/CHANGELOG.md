# Changelog

All notable changes to `init_ubuntu` are documented here.

The format is based on
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning 2.0.0](https://semver.org/),
with project-specific bump rules (see `doc/process/release.md`):

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

- Product spec at `doc/prd/init-ubuntu.prd.md` covering MVP scope, milestones
  (M1-M15), acceptance criteria, exit codes, CLI surface, state model.
- System architecture at `doc/architecture.md` covering engine layering
  (dispatcher / runner / registry / resolver / state).
- Module v1 contract at `doc/module-spec.md` defining metadata schema,
  lifecycle functions, archetype concepts.

#### M2 — Test harness (commit 82b5a7e)

- Borrowed + customized `ycpss91255-docker/base` v0.28.0 test rig.
- Docker-only test execution via `Makefile` + `script/ci/ci.sh` +
  `compose.yaml`.
- bats unit + integration test infrastructure at `test/unit/` and
  `test/integration/`.

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
- `module/apt-essentials.module.sh` — reference module (apt archetype).
- `module/docker.module.sh` — reference module (custom archetype).
- `template/module.template.sh` — v1 module skeleton.
- `test/unit/e2e_spec.bats` — end-to-end install/remove dry-run.

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
- Standalone vs Engine dual-mode header: `bash module/foo.module.sh install`
  works as a self-contained CLI without `setup_ubuntu` (ADR-0001 defines
  the Sidecar vs state.json write split).
- Archetype macros `module_use_apt_archetype` / `_github_release_` /
  `_config_` — one-line lifecycle binding.
- Metadata fields trimmed: dropped MAINTAINER, RECOVERY_FALLBACK,
  PARALLEL_GROUP, INSTALL_TIME_ESTIMATE, DISK_SPACE_ESTIMATE.
- Folder naming convention enforced (singular):
  `docs/` → `doc/`, `test/helpers/` → `test/helper/`,
  `test/unit/modules/` → `test/unit/module/`, `module/tools/` →
  `module/tool/`. Hook `script/hook/test-must-use-docker.sh` enforces
  Docker-only test execution (ADR-0004).
- ADRs 0001-0004 introduced (`doc/adr/`):
  0001 standalone/engine state boundary,
  0002 all 10 lifecycle functions mandatory,
  0003 language choice + migration triggers,
  0004 tests-must-run-in-docker-only.
- `CONTEXT.md` domain glossary added.
- Refactored 10 v2 modules: apt-essentials, docker, fish, font,
  git-config, neovim, nvidia-driver, shell, ssh-config, tmux.

#### M7-#68 — Template split into 4 archetypes (commit 57df2e3)

- `template/module.template.sh` (unified, all archetypes commented out)
  replaced with 4 specialized templates:
  - `template/module-apt.template.sh` (archetype A)
  - `template/module-github-release.template.sh` (archetype B)
  - `template/module-config.template.sh` (archetype C)
  - `template/module-custom.template.sh` (archetype D, hand-written)
- `test/unit/template_consistency_spec.bats` — hash-compares shared
  sentinel-delimited sections (shared-bootstrap / shared-metadata /
  shared-lifecycle-stubs / shared-footer) across the 4 templates to
  detect drift.
- `test/unit/template_smoke_spec.bats` — rewritten to iterate the 18
  smoke checks (`--help` / `--version` / install/upgrade/remove/purge/
  verify --dry-run / is-installed / is-outdated / doctor / info /
  status / source-mode / no-side-effects) across all 4 archetypes.
- Test count: 255 → 267 (8 new archetype-iterating smoke + 11 consistency).

### Changed

- **Lifecycle phase rename: `update()` → `upgrade()`** (commit 57df2e3).
  PRD §5.1 / §13.2 has long aligned the CLI with apt
  (`setup_ubuntu update` = registry rescan, `setup_ubuntu upgrade` = run
  lifecycle upgrade) but the implementation still defined module-level
  `update()`. Renamed across:
  - `lib/module_helper.sh` archetype macros, default implementations,
    standalone CLI accepted phases, dryrun_guard labels, `--help` text.
  - 6 v2 modules (apt-essentials, docker, fish, font, nvidia-driver,
    tmux).
  - `test/unit/module_helper_spec.bats` archetype function-list assertion.
  - `setup_ubuntu update` (registry rescan subcommand) **unchanged**.
- **File rename: `lib/module_helpers.sh` → `lib/module_helper.sh`**
  (commit 57df2e3). Folder-name singular convention extended to filenames;
  `git mv` preserves history; all 16 references updated.
- AGENTS.md + `doc/agent/{issue-tracker,triage-labels,domain}.md` added
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

- Legacy `template/{func,module,submodule,test}_tmp.sh` (commit 6fc3d6c).
- Legacy `module/setup_*.sh` scripts being replaced by v2 modules
  (incremental, per M7 batch).
- 5 metadata fields no longer carried: MAINTAINER, RECOVERY_FALLBACK,
  PARALLEL_GROUP, INSTALL_TIME_ESTIMATE, DISK_SPACE_ESTIMATE (commit
  6fc3d6c).

---

[Unreleased]: https://github.com/ycpss91255/initialization/compare/...HEAD
