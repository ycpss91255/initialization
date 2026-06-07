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

- **State robustness** (issue #41, PRD §10.1): reading a corrupt
  `state.json` now quarantines it (`mv` → `state.json.corrupt.<ts>`) and
  fails fast (exit 1) with recovery guidance — re-run install to rebuild
  records (modules are idempotent) or manually fix the quarantined file
  and rename it back. Never silently rebuilt, so manual / dep snapshot
  data is never lost (automated repair stays `doctor --fix`, 0.3.0).
  Contended state writes print a one-line wait notice; after
  `INIT_UBUNTU_LOCK_TIMEOUT` (default 30 s) the writer exits 1 printing
  the lock holder info (PID / lock file path).

### Changed

- **Module tools directory relocated to top-level `tool/`** (issue #46,
  PRD §6.5): holding area for one-off scripts — not in the module
  catalog, not in the TUI, not in the install pipeline; per-file
  destinations deferred to 0.2+. Engine registry scan (`lib/registry.sh`)
  only reads `module/*.module.sh`, so `tool/` is outside its scope.
  CI lint prune list, kcov excludes, and `.codecov.yaml` ignore updated.
  ADR-0021 leftovers finished in the same pass:
  `test/unit/hooks/`→`test/unit/hook/`,
  `test/unit/scripts/`→`test/unit/script/`.
- **CI path filter now actually skips heavy jobs on doc-only / meta-only
  PRs** (issue #27): the all-negated `changes` filter gets
  `predicate-quantifier: every` (without it the default `some` quantifier
  matched nearly every file, so `code` was effectively always true), and
  the exclusion list adds `.claude/**`, `.github/ISSUE_TEMPLATE/**`, and
  `**/*.adoc`. `ci-passed` name and aggregation semantics unchanged
  (skipped heavy jobs still count as pass).
- **CI builds the test-tools image once and reuses it** (issue #26):
  new `build-image` job builds `test-tools:local` via
  `docker/build-push-action@v6` with GHA layer cache and uploads it as a
  1-day tar artifact; `lint` / `test-unit` / `test-integration`
  `docker load` the artifact instead of cold-building per job. `coverage`
  runs in the upstream `kcov/kcov` image and skips the test-tools build
  entirely. `Makefile` gains a `TEST_TOOLS_PREBUILT=1` escape hatch that
  drops the `build-test-tools` prerequisite (CI-only; local dev behavior
  unchanged). `ci-passed` aggregator now also requires `build-image`
  (required-check name unchanged).
- **Folder naming reverted to all-singular** (issue #32, ADR-0021
  supersedes ADR-0005): `docs/`→`doc/`, `tests/`→`test/`
  (`helpers/`→`helper/`, `unit/modules/`→`unit/module/`),
  `scripts/`→`script/`, `modules/`→`module/`, `templates/`→`template/`,
  `.claude/hooks/`→`.claude/hook/`, `.claude/scripts/`→`.claude/script/`,
  `docs/agents/`→`doc/agent/`, `docs/processes/`→`doc/process/`,
  `docs/guides/`→`doc/guide/`. Upstream-imposed dirs and acronyms
  (`adr/`, `prd/`, `ci/`) unchanged; file names ending in `s` deferred
  to 0.2.0. User-local module dir is now
  `${XDG_CONFIG_HOME}/init_ubuntu/module/` (was `.../modules/`).

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
  `doc/` → `doc/`, `test/helper/` → `test/helper/`,
  `test/unit/module/` → `test/unit/module/`, `tool/` →
  `tool/`. Hook `.claude/hook/test-must-use-docker.sh` enforces
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

#### CI workflow — GitHub Actions (issue #2)

- `.github/workflows/ci.yaml` with 5 jobs:
  - `lint` — `make lint` (shellcheck + hadolint + fish syntax),
    always runs even on doc-only PRs.
  - `test-unit` — `make test-unit`, skipped on doc-only PRs.
  - `test-integration` — `make test-integration`, skipped on doc-only.
  - `coverage` — `make coverage` (kcov), uploaded as artefact;
    skipped on doc-only.
  - `ci-passed` — aggregator that succeeds iff lint passed and the
    heavy three either passed or skipped. Single check name for
    `required_status_checks` to anchor on (#3).
- Path filter via `dorny/paths-filter@v3`: `code` output is `false`
  for changes touching only `doc/**`, `**/*.md`, `LICENSE*`,
  `.gitignore`, `.codecov.yaml`.
- Triggers: PR to `main`, push to `main`, push to `v*` tags (so
  `release-tag.sh`'s CI-conclusion query for RC tags works).
- `concurrency` group cancels in-flight PR runs on new pushes.

#### ShellCheck baseline — base-aligned, no global config

Convention: no project-wide `.shellcheckrc`. Every disable lives at its
call site with a wiki-link rationale, matching the upstream
`ycpss91255-docker/base` pattern. Lint level stays at shellcheck's
default severity (style/info/warning/error all reported).

- `script/ci/ci.sh`:
  - Fix exclude-path typo `module/tool` → `tool` (post-
    ADR-0005 plural rename had not been propagated).
  - Extend `_find_lintable_sh` to pick up `*.bash` + `*.bats` too.
  - Exclude legacy paths slated for removal per PRD §6.5/§6.6:
    `module/submodule/`, `module/function/`, `module/setup_*.sh`,
    `module/anydesk.sh`, `install-nvidia-driver.sh` — these predate
    the v2 module pattern; their shellcheck disables stay as-is until
    relocation.
  - Add `jq` to `_install_deps_for_coverage` apt-get list (kcov/kcov
    image lacks it; `lib/state.sh` needs jq for state.json mutation).
  - Refactor `_bats_args` → `_set_bats_args_arr` populating global
    `BATS_ARGS_ARR`; callers now `bats "${BATS_ARGS_ARR[@]}"` instead of
    `bats $(_bats_args)` (SC2046 proper fix).
- Proper fixes (no disable):
  - `lib/detect.sh:268`, `lib/platform.sh:42`: escape `\}` in case
    pattern (SC1083 — literal `}` matches JSON `null}` object close).
  - `lib/module_helper.sh`: remove `"$@"` from 18 archetype inner
    wrappers — never called with args, fixes SC2119/SC2120.
  - All `lib/*.sh` + `module/*.module.sh` + `template/*.sh`:
    defensive `${BASH_SOURCE[0]:-}` / `${0:-}` (matches base).
  - `test/unit/module_helper_spec.bats:205`: use
    `declare -A DESCRIPTION=([en]="...")` for assoc array (SC2190).
  - `module/font.module.sh`: `command -v X && X || true` → explicit
    `if ... then ... fi` (SC2015).
- Disable-with-rationale (wiki-link inline at each disable):
  - 10 `module/*.module.sh` + 4 `template/module-*.template.sh`:
    file-top SC2034 — metadata vars consumed by engine post-source.
  - 1 `test/unit/module_helper_spec.bats` file-top SC2034/SC2317.
  - 6 `test/unit/*_spec.bats`: file-top SC1091 — tests source libs
    via runtime `${LIB_DIR}` shellcheck can't statically resolve.
  - `lib/module_helper.sh`: file-top SC2317 — archetype-macro inner
    wrappers dispatched indirectly via `${_phase}` (lib/runner.sh).
  - `lib/sync.sh`: file-top SC2029 — SSH cmds expand `${_remote_path}`
    client-side intentionally.
  - `module/docker.module.sh`: per-fn SC2032/SC2033 above `install()`
    — function name shadows `/usr/bin/install`; harmless because `sudo
    install` invokes the binary (sudo clears function table).
  - `test/unit/i18n_spec.bats`: file-top SC2030/SC2031 — bats `run`
    spawns subshell, test setups `export LANG=...` stage env.
  - `test/unit/module/docker_spec.bats`, `template/test.template.bats`:
    file-top SC2317 — test mocks dispatched indirectly.
  - `test/unit/template_smoke_spec.bats:34`: per-block SC2016 above
    multi-line `sed` with literal `${MODULE_DIR}` template placeholders.
  - `lib/module_helper.sh:45`: per-line SC2120 on i18n wrapper —
    optional `<lang>` arg.
  - `lib/module_helper.sh:478`: per-line SC2119 on call without args
    (uses INIT_UBUNTU_LANG default).

#### Engine subshell isolation: `bash -c` → `(...)` (coverage compat)

`lib/runner.sh:_runner_run_phase` switches the module-dispatch
subshell from `bash --noprofile --norc -c "..."` to `(...)` fork.

Why: kcov-instrumented bash (the coverage target's image) leaves
`$BASH_SOURCE` / `$FUNCNAME` unbound inside `bash -c` contexts.
Under `set -u`, kcov's ptrace-driven line-attribution hits the
unset parameter and tears down the subshell on every command. The
fork-style subshell inherits these arrays from the parent shell, so
the strict-mode contract holds and coverage instrumentation stays
happy. Isolation guarantee is unchanged — `(...)` is still a true
subshell (side-effects don't leak back to the engine), just cheaper
than `exec`-ing a new bash.

Parent shell (`setup_ubuntu.sh` or bats `_load_engine`) is now
responsible for sourcing `logger.sh` / `general.sh` /
`module_helper.sh` once; the subshell inherits them. The subshell
still `source`s the module file itself and dispatches to `${_phase}`.

- `.gitignore`: add `/coverage/` to ignore the kcov output dir.

#### ADR-0006 — OTel-aligned logger schema (decision only; issue #8)

- `doc/adr/0006-otel-aligned-logger-schema.md` — decision to migrate
  `lib/logger.sh` `log_event` JSONL output to mirror the OpenTelemetry
  Logs Data Model + W3C Trace Context, without adopting the OTel SDK
  or Collector. Sourced from the project author's observability
  playbook (Notion: "Debug 資訊架構：從 print 到 Observability",
  2026-05-12). Key choices:
  - Field rename: `ts` → `timestamp`, `level` → `severity_text`,
    `event` → `body`, top-level `module` → nested
    `attributes.service.name`.
  - All business payload nested under `attributes` (OTel SemConv).
  - Add `attributes.service.lang = "bash"`, `attributes.code.filepath`
    + `code.lineno`.
  - Add `trace_id` (per-`setup_ubuntu`-invocation, UUID v7 preferred)
    + `span_id` (per-phase-per-module). Auto-propagate via env into
    sub-shells.
  - Mirror `log_info` / `log_warn` / `log_error` to JSONL too.
  - Per-session log file rotation:
    `${XDG_STATE_HOME}/init_ubuntu/logs/<trace_id>.jsonl` + `latest`
    symlink.
  - `doc/guide/log-queries.md` will ship lnav format file with
    `opid-field: trace_id` (free timeline view) + jq snippet library.
- Implementation deferred to issue #8; gated on PRs #4 / #6 / #7
  merging first to avoid CHANGELOG and `lib/runner.sh` conflicts.

#### Archetype cookbook (issue #5, task #69)

- `doc/guide/archetype-cookbook.md` — companion to the 4 archetype
  templates. Documents:
  - Decision tree for picking archetype A / B / C / D.
  - Pure-archetype usage (apt-essentials, neovim, git-config, font).
  - **Hybrid + super-call override pattern** — using
    `module_use_apt_archetype` then overriding `install()` (docker
    is the reference: apt-repo key+source setup + `usermod -aG`).
  - Capture-and-chain pattern: `_orig_install=$(declare -f
    module_default_apt_install | sed '1d;$d')` to `eval` the
    original then add post-steps.
  - `is_outdated()` recipes per archetype (apt-list-upgradable,
    gh-release-tag-compare, sha256sum-config-hash, custom).
  - 5 common pitfalls: bad-substitution arrays, `declare -A` vs
    `declare -gA`, `cd` outside subshell, standalone vs engine
    state writes (ADR-0001), `update` vs `upgrade` naming.
- Templates' authoring docstring paths fixed:
  `doc/guide/archetype-cookbook.md` → `doc/guide/archetype-cookbook.md`
  (per ADR-0005, plural for the collection dir).

#### wait-pr-ci skill + hook (issue #15)

Port of docker_harness's `wait-pr-ci` triple so `gh pr create` is
followed by a non-context-burning CI monitor instead of a sleep
poll. Three components:

- `.claude/script/wait-pr-ci.sh` — the polling primitive. Wraps
  `gh pr view` + `gh pr checks` with terminal-state detection
  (success / failure / merged / closed). Designed to be the body
  of a Claude Code Monitor invocation. SKIPPED checks count as
  success (matches the path-filter doc-only behaviour from #4's
  CI workflow).
- `.claude/skills/wait-pr-ci/SKILL.md` — agent-facing flow doc.
  When to invoke (post `gh pr create`, post force-push, when
  checking on another agent's PR), how to read the output.
- `.claude/hook/remind_pr_wait_ci.sh` — PreToolUse Bash hook.
  Fires when the agent is about to run `gh pr create` and emits
  a non-blocking systemMessage reminding to invoke the skill
  after the PR opens. Registered as the 8th entry in
  `.claude/settings.json` PreToolUse Bash matcher.

#### User-local module discovery (issue #13, PRD §13.2 Q35)

- `lib/registry.sh`: `registry_load_all` now scans a second directory
  after the bundled `module/` — defaults to
  `${INIT_UBUNTU_USER_MODULE_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/init_ubuntu/module}`.
  Skipped silently if absent (engine works on hosts that never opt in).
- Name collision: user-local wins by overwriting the bundled entry;
  `log_warn` (or stderr fallback if logger not loaded) reports the
  override with both paths.
- Internal: existing scan loop extracted to private
  `_registry_load_one_dir(dir, is_user_local)` helper. Public API
  `registry_load_all` keeps backwards-compatible single-arg
  signature.
- Tests: 267 → 271 (4 new in `test/unit/registry_spec.bats`):
  - user-local module appears in `registry_list_names`
  - user-local NAME collision overrides bundled metadata
  - collision emits `user-local override` warn line
  - absent user dir is a no-op

#### apt archetype: is_outdated default via apt list --upgradable (issue #11)

- `lib/module_helper.sh`: new `module_default_apt_is_outdated` —
  returns 0 (outdated) if any package in `APT_PKGS` appears in
  `apt list --upgradable` output, 1 otherwise. No sudo required;
  graceful on hosts without apt (`apt -> empty -> 1`).
- `module_use_apt_archetype` macro now binds `is_outdated()` too
  (was 6 fns → 7 fns). Module authors get the default for free; can
  still override after the macro.
- Test: `module_use_apt_archetype` function-list assertion updated
  to include `is_outdated` (now 7).
- Test: `template_smoke_spec`'s `is-outdated` case split per
  archetype — apt returns 1 (macro-provided, empty APT_PKGS = not
  outdated); github-release / config / custom still return 2 (not
  implemented).

Follow-ups (not in this PR):
- github-release archetype `is_outdated` default — needs a
  `module_sidecar_get_version` helper to read
  `${XDG_STATE_HOME}/init_ubuntu/versions/<name>`. Separate task.
- config archetype `is_outdated` default — sha256sum-based diff;
  ~15-line stub but ships cleanly in its own PR.

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

- `.claude/script/release-tag.sh` — canonical primitive for cutting
  version tags. Decision tree: RC tag short-circuits; `Z>0` patch
  short-circuits; `Y` bump requires passing `vX.Y.0-rcN` CI; `X` bump
  also requires `RELEASE_X_BUMP_ACK=<tag>`. Verifies `.version`
  literal matches the tag.
- `.claude/skills/semver-bump/SKILL.md` — agent-facing companion.
- `.claude/hook/enforce_semver_tag_via_script.sh` — DENIES ad-hoc
  `git tag v*` / `git push origin v*` / `git push --tags`; forces
  callers through `release-tag.sh`.
- `.claude/hook/check_main_fresh_before_worktree.sh` — BLOCKs
  `git worktree add ... main` when local main is behind origin/main.
- `.claude/hook/remind_main_sync.sh` — non-blocking reminder on
  `gh pr merge` to `git pull --ff-only origin main` after merge.
- `.claude/hook/check_changelog_drift.sh` — non-blocking reminder when
  `git commit` stages non-doc code without a CHANGELOG entry.
- `.claude/hook/enforce_gh_body_file.sh` — enforces `--body-file`
  convention on `gh issue/pr create/comment` (docker_harness
  gh-artifact-format skill rules 1-8).
- `.claude/hook/enforce_gh_english.sh` — **new (not in docker_harness)**:
  DENIES `gh issue/pr create/comment` whose title / body contains CJK
  characters. Project rule: GitHub interaction is English-only.
- `doc/process/release.md` — release workflow documentation.
- `doc/process/worktree.md` — already in [Unreleased] under Phase 1
  (commit 6e840d1).
- `.version` — `v0.0.0` baseline (commit 6e840d1).
- All 7 hooks registered in `.claude/settings.json`.

#### ADR-0007 + transcript-bound shellcheck-disable approval hook (issue #17)

Codifies the ShellCheck base-alignment discipline (`# shellcheck disable=...`
gated by wiki-link rationale + user approval) from PR #4 into an enforceable
hook plus rationale doc:

- `doc/adr/0007-exit-code-contract-scripts-default-to-set-uo.md` — ADR
  documenting the project convention that exit-code-contract scripts
  (`.claude/hook/*.sh`, `.claude/script/release-tag.sh`) default to
  `set -uo pipefail` (not `-euo`). Cites BashFAQ #105 + Google Shell
  Style Guide; lists exception criteria for `-euo` (always-act scripts
  like `test-must-use-docker.sh`).
- `CLAUDE.md` (`AGENTS.md`) — new `## Script conventions` section
  indexing ADR-0007 and the new hook for agent-facing discoverability.
- `.claude/hook/enforce_shellcheck_disable_approval.sh` — PreToolUse
  hook on `Edit|Write|MultiEdit`. Blocks (`permissionDecision: deny`)
  any newly added `# shellcheck disable=SC<code>` directive unless the
  user has explicitly approved that code in their most recent message
  via the phrase `approve SC<code>` (case-insensitive on the verb;
  batchable: `approve SC2034 SC1091`). Approval is read from the
  system-controlled session transcript path (`transcript_path` in the
  PreToolUse JSON) — it cannot be forged. Emergency bypass via
  `ECC_ALLOW_SHELLCHECK_DISABLE=1` env var.
- Internal modules (functions sourced for bats testing in isolation):
  `read_latest_user_message`, `new_shellcheck_disables`,
  `is_disable_approved`, `main`.
- `test/unit/hook/{transcript_reader,disable_diff,approval_check,enforce_shellcheck_disable_approval}_spec.bats`
  — bats specs for each module + integration test for the hook entry.
- `.claude/settings.json` — hook registered as the 2nd `PreToolUse`
  matcher block (`Edit|Write|MultiEdit`).

### Changed

- **Folder naming reverted to plural-for-collections + singular-for-concepts**
  (ADR-0005). M7-A's "all folders singular" hard rule is replaced after
  three observations forced a re-evaluation: industry convention is
  plural for collections (Linux kernel, Python, Rust, Git internals);
  sibling repo `ycpss91255-docker/docker_harness` is itself mixed; the
  exception list for upstream-mandated plurals kept growing. Renames:
  `doc/` → `doc/`, `doc/agent/` → `doc/agent/`,
  `doc/process/` → `doc/process/`, `module/` → `module/`,
  `module/tool/` → `tool/`, `script/` → `script/`,
  `script/hook/test-must-use-docker.sh` → `.claude/hook/test-must-use-docker.sh`
  (also relocated since all hooks are Claude PreToolUse, matching
  docker_harness `.claude/hook/`), `test/` → `test/`,
  `test/helper/` → `test/helper/`,
  `test/unit/module/` → `test/unit/module/`,
  `template/` → `template/`. Kept singular: `lib/`, `doc/adr/`,
  `doc/changelog/`, `doc/prd/`, `module/config/`,
  `module/submodule/` (deprecated path), `script/ci/`,
  `test/unit/`, `test/integration/`. AGENTS.md Hard rule #2
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

- `module/submodule/yazi.sh`: alias clobbered `cat` instead of installing
  `yz` (issue #1). The script wrote `command -v yazi &>/dev/null &&
  alias cat='yazi'` to `~/.bashrc` and `~/.zshrc` — looked like a
  copy-paste leftover from `batcat.sh` where `alias cat=bat` is the
  intended override. Now matches the fish config
  (`module/config/fish/conf.d/alias.fish`) which already uses
  `alias yz=yazi`. Users with the bad alias already in their rc files
  should `unalias cat` + remove the line manually (no auto-cleanup).

- `wait-pr-ci.sh` watch-start guard hung forever when launched after CI
  completion (issue #22). New `--stale-window <seconds>` flag (default
  120s) bounds the post-force-push race window — checks that completed
  more than `stale_window` seconds before `watch_start` are now trusted
  as a legitimate prior run instead of demoted to `pending`. Setting
  `--stale-window 0` restores the pre-fix always-demote behaviour.

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
- ECC plugin + marketplace (`affaan-m/everything-claude-code`) from
  `.claude/settings.json` — no longer used.

---

[Unreleased]: https://github.com/ycpss91255/initialization/compare/...HEAD
