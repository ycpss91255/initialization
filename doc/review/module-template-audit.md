# Module Template / Archetype / Function System — Audit

Status: investigation for maintainer discussion. READ-ONLY audit at `main` (v0.1.0-rc3),
2026-07-04. No code changed. This document is the only artifact produced.

Scope: the foundation every module install expands from — `template/*.template.sh`,
`lib/module_helper.sh`, `lib/module_bootstrap.sh`, `module/function/`, and the test layer
that exercises them. Two questions drive the audit: (a) is test coverage complete enough,
and (b) should any architecture change. Part 4 additionally surveys for a NEW small-tool
(one-off script) template.

All citations are `file:line`.

---

## 1. System map

### 1.1 Templates (`template/*.template.sh`)

Four module templates plus a library template and a bats template:
`module-apt.template.sh`, `module-github-release.template.sh`, `module-config.template.sh`,
`module-custom.template.sh`, `lib.template.sh`, `test.template.bats`.

All four module templates share a byte-identical outer skeleton; only the `archetype-data`
block and the lifecycle section differ. Sections are fenced with
`# -- BEGIN/END: <section> --`: `shared-bootstrap`, `shared-metadata`, `archetype-data`,
`shared-lifecycle-stubs` (or `custom-lifecycle`), `shared-footer`.

- Dual-mode header (identical across all four): `template/module-apt.template.sh:40-56`.
  `MODULE_STANDALONE` is set by comparing `${BASH_SOURCE[0]}` to `$0`; a direct
  `bash module/x.module.sh` sources `module_bootstrap.sh` and calls `module_bootstrap`,
  while engine sourcing skips the block.
- Lint-hint block (identical): `template/module-apt.template.sh:47-55`. A permanently-false
  guard `[[ -n "${__module_lint_hint:-}" ]] && source ".../module_helper.sh"` gives
  `shellcheck -x` a static `source=` directive (suppressing SC2034 on metadata vars),
  wrapped in `# kcov-exclude-start/end` so the dead line is not counted.
- Dual-mode footer (identical): `template/module-apt.template.sh:146-148` — dispatches the
  CLI (`module_standalone_main "$@"`) only in standalone mode; marked "DO NOT REMOVE".
- Author-filled metadata block: `template/module-apt.template.sh:58-98` (identity, i18n
  `declare -gA` arrays, env constraints, risk, `TEST_VERIFY_CMD`).
- Per-archetype data + macro call:
  - apt — `template/module-apt.template.sh:100-106` (`module_use_apt_archetype`, :105).
  - github-release — `template/module-github-release.template.sh:101-113`
    (`module_use_github_release_archetype`, :112).
  - config — `template/module-config.template.sh:100-107`
    (`module_use_config_archetype`, :107).
  - custom — `template/module-custom.template.sh:104-110` has NO macro; the author
    hand-writes all six mutation/lifecycle functions from the working stubs at
    `:144-200` (`upgrade()` defaults to re-running install, :171;
    `verify() { module_default_verify "$@"; }`, :198).
- For apt/github/config templates, only `detect()` and `is_recommended()` are left as real
  stubs (`template/module-apt.template.sh:113-124`); `is_outdated()`/`doctor()` are shown as
  OPTIONAL commented stubs (:129-138).
- `template/lib.template.sh` — a library skeleton (NOT a module): no top-level strict mode
  (:8), functions-only/no source-time side effects (:10), file-stem-prefixed public names,
  `_`-prefixed private names (:26-42), library guard refusing direct execution (:19-24).
- `template/test.template.bats` — the mandated per-module spec skeleton: `load helper/common`
  (:21), `setup_test_env`/`teardown_test_env` (:23-31), in-process `_load_module` vs
  subprocess `_standalone_module` (:33-48), metadata sanity, clean-container `is_installed`
  false, dry-run no-op asserting `--partial "DRY-RUN"`, idempotency short-circuit, and a
  dual-mode standalone CLI block (no-args -> usage + exit 2; `--version`/`--help`/unknown).

### 1.2 `lib/module_helper.sh` — archetype macros + lifecycle emission

Three archetype macros exist (custom has none):
- `module_use_apt_archetype` — `lib/module_helper.sh:257-267`
- `module_use_github_release_archetype` — `lib/module_helper.sh:437-447`
- `module_use_config_archetype` — `lib/module_helper.sh:522-532`

Confirmed: each macro emits **exactly 9 functions** (verified at `lib/module_helper.sh:257-267`):
`is_installed`, `is_outdated`, `install`, `upgrade`, `remove`, `purge`, `verify`, `doctor`,
`module_provided_version`. `detect()` and `is_recommended()` are always module-defined
(never emitted; asserted at `test/unit/module_helper_spec.bats:140`). So the "10 lifecycle
functions" of the contract = these 9 emitted + the 2 module-defined stubs, minus overlap:
the full contract set is **detect, is_recommended, is_installed, is_outdated, install,
upgrade, remove, purge, verify, doctor** (ADR-0002), and `module_provided_version` is a
Sidecar version hook (not a dispatchable phase). The task's "provided_version" is that hook;
`verify` is a real emitted phase the task's guessed list omitted.

Default implementations (by archetype), all in `lib/module_helper.sh`:
- apt: `module_default_apt_is_installed` (:90-101), `_apt_install` (:103-125),
  `_apt_upgrade` (:127-137), `_apt_remove` (:139-143), `_apt_purge` (:145-156),
  `_apt_is_outdated` (:238-249).
- github-release: `_is_installed` (:282-296), shared fetch
  `_module_github_release_fetch_and_install` (:314-378), `_install` (:380-386),
  `_upgrade` (:388-393, no is_installed gate), `_remove` (:395-406, no is_installed gate),
  `_purge` (:408-416), `_is_outdated` (:423-432).
- config: `_is_installed` (:459-462), internal `_module_config_drop` (:464-482),
  `_install` (:484-490), `_upgrade` (:492-499), `_remove` (:501-505), `_purge` (:507-509,
  == remove), `_is_outdated` (:515-517, always returns 1).
- shared: `module_default_verify` (:160-167), `module_default_doctor` (:174-180, is_installed
  + `log_warn` only — the ADR-0002/0027 baseline).

Version resolution (`module_provided_version`): generic `module_default_provided_version`
(:193-195) -> `VERSION_PROVIDED`; apt (:200-209) -> `dpkg-query`; github-release (:218-226)
-> prefers `MODULE_GH_RESOLVED_VERSION` (published in the fetch at :336), preserves existing
Sidecar on a no-op re-install; config (:230-232) -> `VERSION_PROVIDED`.

Sidecar: path `module_sidecar_path` (:544-549); `module_sidecar_write` (:551-560, dry-run
no-op), `module_sidecar_remove` (:562-569), `module_sidecar_get_version` (:572-577). The
single write-site is `_module_sidecar_after_phase <phase> <name>` (:590-610), fired ONLY by
the invocation layer after a phase returns 0: Engine at `lib/runner.sh:238-241`, Standalone
at `lib/module_helper.sh:732-734`. Verified: install/upgrade -> write, remove/purge -> remove,
else no-op; dry-run short-circuits.

Override / super-call: macros define the 9 functions; a module re-declares any of them AFTER
the macro (bash late-binding), and a "super-call" invokes the `module_default_*` by name to
keep default behavior while adding to it (documented `lib/module_helper.sh:254-256, 171-173`).

### 1.3 `lib/module_bootstrap.sh` — dual-mode bootstrap

Single function `module_bootstrap` (:38-62). Branch at :40 —
`[[ "${MODULE_STANDALONE:-false}" == "true" ]] || return 0` (engine mode = immediate no-op,
because `lib/runner.sh` already sourced libs + set strict mode). Standalone path (:41-61):
`set -euo pipefail; shopt -s inherit_errexit` (:42-43), self-locates `LIB_DIR` from this
file's own `BASH_SOURCE` (:48-50), sources `logger.sh`, `general.sh`, `module_helper.sh` in
order (:57-61). Library guard refuses direct execution (:32-35).

### 1.4 `module/function/` — the "module/func" helpers (LEGACY)

Key finding: `module/function/general.sh` and `module/function/logger.sh` are the LEGACY
ORIGINALS of `lib/general.sh` + `lib/logger.sh` and are NOT consumed by any `*.module.sh`.
Evidence: `lib/logger.sh:4-6` ("copied from module/function/logger.sh ... Phase 7 will
delete module/function/logger.sh"); `lib/general.sh:5`. The only live consumers of
`module/function/*` are the legacy `module/setup_nvidia_driver.sh` and `script/ci/ci.sh`.
Live modules reach `log_info`/`have_sudo_access`/`backup_file`/`get_github_pkg_latest_version`
through the `lib/` copies via `module_bootstrap`.

- `module/function/logger.sh` (228 lines): color detection + `log_debug/info/warn/error/fatal`
  (:222-226; `log_fatal` exits 1).
- `module/function/general.sh` (681 lines): `exec_cmd` (:58-154), `have_sudo_access`
  (:167-192), `backup_file` (:205-222), `create_temp_file` (:242-286), `check_pkg_status`
  (:307-353), `setup_apt_mirror` (:373-451), `apt_pkg_manager` (:480-606),
  `get_github_pkg_latest_version` (:619-681, the github-release resolver).
- `module/function/test/`: ad hoc executable drivers `test_general.sh`, `test_logger.sh`
  (NOT bats; not in the CI harness).

### 1.5 Concrete modules (macro + overrides in practice)

- apt, pure macro: `module/curl.module.sh:64-67` — declares `APT_PKGS`, calls
  `module_use_apt_archetype`, overrides only `detect()`/`is_recommended()`.
- apt-shaped but hand-written (no macro): `module/docker.module.sh:6` ("we DON'T use
  module_use_apt_archetype") — full hand-written lifecycle for the keyring/sources flow.
- github-release, install/upgrade super-call to set resolved version:
  `module/fzf.module.sh:76,82-94` (leaves remove/purge to defaults, :96-98).
- github-release, KNOWN remove override: `module/lazydocker.module.sh:81-85` — adds
  `module_skip_if_not_installed && return 0` then super-calls
  `module_default_github_release_remove` (:84). The comment (:76-80) explains the shared
  default deletes unconditionally to clean Sidecar-less partial installs (e.g. fzf), so the
  skip is layered locally.
- github-release, purge super-call: `module/yazi.module.sh:117-120`
  (`module_default_github_release_purge || return $?` then `_yazi_remove_alias`); remove left
  to default so user config survives (:113-114).
- config, super-call chain: `module/claude-code-config.module.sh:82,92-121` (JSON-safe marker
  at :80).
- config, plainest: `module/git-config.module.sh:53` (`module_use_config_archetype`, no
  overrides beyond the two mandatory stubs).

---

## 2. Recorded requirements (docs + ADRs + issues)

### 2.1 Cross-document conflict (flag first)

`doc/module-spec.md:326` still encodes the OLD model: "5 mandatory + 5 optional" functions,
and uses `update()` for the upgrade phase (§4.1 tables). This contradicts:
- ADR-0002:1-11 — all 10 lifecycle functions mandatory.
- CONTEXT.md:23-26 — the 10 functions; the phase is `upgrade()`.
- `doc/guide/archetype-cookbook.md:315-319` — "`upgrade` is the lifecycle phase, `update` is
  registry rescan; don't define `update()`."

Authoritative today = ADRs + CONTEXT.md + the cookbook. `doc/module-spec.md` is stale on both
the mandatory count and the `upgrade`/`update` naming — a two-sources-of-truth problem in the
normative contract itself. (This is separate from the runtime version-divergence issue F2.)

### 2.2 `doc/module-spec.md` — contract highlights

File naming MUST `module/<name>.module.sh`, kebab-case (:7-22). File structure order MUST be
header/metadata/lifecycle/footer (:26-34). Metadata required `NAME`/`DESCRIPTION`(>= en)/
`CATEGORY`/`SUPPORTED_UBUNTU` (:104-142); optional incl. `VERSION_PROVIDED`, `DEPENDS_ON`
(no cycles -> exit 5), `CONFLICTS_WITH`, `RISK_LEVEL`, `TEST_VERIFY_CMD` (:146-318). Archetype
data fields §3.2.1 (:192-274). Idempotency: each of install/upgrade/remove/purge repeated MUST
exit 0 (:357-365). `log_fatal` forbidden in modules (:434-448). Dry-run must not mutate FS
(:450-475). Failure/cleanup: use `return` never `exit`; install failure -> state.json NOT
written, exit 6; **verify failure auto-runs `purge()` as rollback** (:483-527). Sidecar
lifecycle + invariants: `is_installed()==false <-> Sidecar absent`; state.json entry implies
Sidecar (:529-547). Dual-mode entry MUST be supported (:558-612). Mandatory per-module bats
spec + required-case table (:853-878); `doctor --validate-modules` metadata lint (:882-893).

### 2.3 Guides

`doc/guide/archetype-cookbook.md`: A/B/C/D decision tree (:14-42); "macros are convenience,
not a contract" (:41-42); super-call pattern (:69-136); pitfalls (:292-319) incl. mandatory
`declare -gA DESCRIPTION`, both modes write Sidecar / only engine writes state.json,
`upgrade` vs `update`. `doc/guide/module-authoring.md`: workflow + ~50 tests/module target
(:112-116), mock everything / never real install (:118-121), verify-vs-doctor and
state-boundary rules that "bite" (:81-98).

### 2.4 ADRs

- ADR-0001 (standalone/engine state boundary): standalone writes Sidecar + prints messages
  but NOT state.json; Sidecar write lives in helpers so both modes hit one path.
- ADR-0002 (all lifecycle mandatory): rejects 5+5; macro must define all; archetype defaults
  for verify/is_outdated/doctor; **authors MUST override `doctor` when the module has a
  runtime surface** (daemon/group/device); baseline default valid only for no-runtime-surface
  modules (:24-29).
- ADR-0009 (verify vs doctor): verify = post-install acceptance, fast, offline, no daemon/
  group assumptions; doctor = runtime health, user-invoked, superset, offline default with
  `--online`.
- ADR-0015 (verify failure == install failure): supersedes PRD warn-only; on verify failure
  the pipeline auto-calls the module's `purge()` (works because purge is mandatory +
  idempotent); state.json not written, exit 6.
- ADR-0026 (per-tool base modules): decompose apt-essentials into independent per-tool
  archetype-A modules; `depends_on` replaces the bundle; 0.1.0 blocker.
- ADR-0027 (sidecar at phase-invocation layer): the shared `_module_sidecar_after_phase`
  write-site; `module_provided_version` standardized + archetype-defaulted; macros emit all
  functions incl. is_outdated + doctor defaults; **`doctor` is now strictly read-only — it may
  warn about a missing Sidecar but no longer heals it** (:63-71); docker/font/nvidia-driver
  still lack is_outdated/doctor, tracked separately (:76-79).

### 2.5 CONTEXT.md glossary

Module / Archetype / Lifecycle (the 10) / Phase (runtime verb, 1:1 to lifecycle fn + info/
status) / Engine / Sidecar (single source of truth for installed version, written at the
phase-invocation layer via `module_provided_version`) / Synced-Local split
(`version_provided` in the `synced` sub-object) — CONTEXT.md:8-132.

### 2.6 `doc/review/architecture-review.md` — module findings

- **F1 (Strong) — per-module `doctor()` unreachable from the Engine; templates lie**
  (:111-132). CONFIRMED in this audit: `runner_doctor` is defined at `lib/runner.sh:450` and
  is called only by `test/unit/runner_spec.bats:286-288`, never by production. The Engine
  `doctor` subcommand routes to `_dispatcher_doctor` (`lib/dispatcher.sh:1052,1276`), a
  state.json-vs-reality drift report that never calls a module's `doctor()`;
  `doctor --validate-modules` (:992) only lints metadata. Rich `doctor()` overrides
  (lazydocker, claude-code-config, yazi, fzf, ...) are reachable ONLY in standalone mode. All
  four templates assert the opposite: `template/module-apt.template.sh:134` "Engine calls this
  from `setup_ubuntu doctor`. Without it, doctor falls back to is_installed."
- **F2 (Worth exploring) — state.json version diverges from Sidecar** (:134-152). On install/
  upgrade the Sidecar records `module_provided_version` (resolved, e.g. `0.44.1`) while
  state.json records the static `${VERSION_PROVIDED}` literal (e.g. `latest`). `list
  --installed` shows the state.json value, so users never see the resolved tag. This is the
  one real "two parallel sources of truth for the same fact" in the runtime contract.
- **F3 — `MODULE_GH_RESOLVED_VERSION` undocumented module->archetype protocol** (:154-167):
  a magic global each github-release resolver must set, absent from the template.
- **F4 — github-release `remove` short-circuit split across default vs override** (:169-183):
  the default has no is_installed gate; lazydocker/notion re-add it, eza/lazygit/neovim don't
  -> non-uniform remove semantics within one archetype.
- **F5 — apt remove/purge + docker purge call `sudo` unguarded** (:185-197): unlike the
  install-side `have_sudo_access` guard; on a no-sudo host the Sidecar is removed (wrapper
  runs on rc==0) while packages remain -> breaks the Sidecar invariant.

No GitHub issue tracks F1 or F2; they live only in the review doc.

### 2.7 GitHub issues stating a requirement / gap

Closed (delivered contract/archetype work): #5 (archetype cookbook), #11 (apt is_outdated
default), #7 (wire upgrade/verify/doctor subcommands), #93 (record resolved depends_on),
#175 (per-archetype real lifecycle integration harness), #176 (CI base-install must exercise
a github-release module), #177 (lib-load contract guard), #178 (real non-dry-run gap
tracking), #123 (module-spec test backfill), #47/#39 (docs + `update`/`upgrade` split).

Open (live requirements): **#242** (`ready-for-agent`) — PRD 0.1.0 TUI redesign + per-tool
base modules (the ADR-0026 requirement); **#278** (`ready-for-human`) — ssh-config config-drop
secrets separation. No open issue tracks F1 (doctor unreachable) or F2 (version divergence).

---

## 3. Test coverage of the template/archetype/function layer

### 3.1 Spec inventory

- `test/unit/module_helper_spec.bats` (91 @tests) — the helper unit surface (i18n, guards,
  macro wiring, per-archetype defaults, Sidecar, provided_version, is_outdated, doctor,
  standalone CLI, engine aggregators).
- `test/unit/template_smoke_spec.bats` (17 @tests) — template conformance loop over all four
  archetypes: materializes each `template/module-*.template.sh`, drives the full standalone
  CLI + dry-run no-side-effect.
- `test/unit/template_consistency_spec.bats` (12 @tests) — drift guard: shared-section
  byte-identity, correct macro per template, custom defines all six, no `update()`.
- `test/unit/module_bootstrap_spec.bats` (11 @tests) — dual-mode bootstrap.
- `test/unit/libload_guard_spec.bats` (9 @tests) — real `setup_ubuntu.sh` entrypoint contract
  (macros + lifecycle helpers inherited by module sub-shell).
- `test/integration/lifecycle/engine_lifecycle_spec.bats` (8 @tests) — the ONLY real
  non-dry-run engine->runner->macro->lifecycle path: gum (B) full, ssh-config (C) full,
  claude-code-config (D) full, tmux (A) REDUCED (wiring only, no apt/sudo on alpine).
- `test/unit/module/*.bats` (39 specs) — per-module ad hoc; they STUB the archetype defaults
  (e.g. `module_default_apt_remove(){ return 0; }`), so they test wiring, not the bodies.
- `test/unit/registry_spec.bats`, `gen_module_index_spec.bats:115`,
  `generate_module_filters_spec.bats:86` — iterate every real module, but metadata/index only.

### 3.2 Coverage matrix (archetype x lifecycle fn)

TESTED = direct behavior assertion; PARTIAL = happy-path or one edge; GAP = default body never
executed (stubbed or unreached). MH=`module_helper_spec.bats`, TS=`template_smoke_spec.bats`,
EL=`engine_lifecycle_spec.bats`.

| fn / arch | apt (A) | github-release (B) | config (C) | custom (D) |
|---|---|---|---|---|
| is_installed | PARTIAL (empty-PKGS MH:174; positive dpkg loop only via per-module stubs) | TESTED (MH:654/660/669) | TESTED (MH:193/200) | module-defined (TS:155) |
| is_outdated | TESTED (MH:620/633/646) | TESTED (MH:362/369/378/388) | TESTED (MH:400 always-1) | not-impl exit 2 (TS:163) |
| install | PARTIAL (dry-run MH:156; real apt-get/PPA/no-sudo UNTESTED; EL:232 REDUCED) | TESTED (real EL:90; idempotent EL:119; dry-run TS:130) | TESTED (MH:182; EL:176 template+chmod) | TESTED (real EL:203) |
| upgrade | PARTIAL (fallback MH:610; real apt upgrade + no-sudo UNTESTED) | TESTED (Sidecar bump EL:135; dry-run TS:134) | TESTED (MH:694) | TESTED (EL:203) |
| remove | **GAP** (`_apt_remove` :139-143 never run; stubbed; dry-run only TS:138) | TESTED (real EL:154) | TESTED (MH:678; dry-run MH:686) | TESTED (EL:203) |
| purge | **GAP** (`_apt_purge` :145-156 never run) | **GAP** (`_gh_purge` CONFIG_PATHS loop never run) | **GAP** (`_config_purge` :507-509 never directly invoked) | dry-run only (TS:142) |
| verify | TESTED (shared MH:579-601) | TESTED (EL:107) | TESTED (EL:191) | TESTED (EL:219) |
| doctor | TESTED-shallow (shared MH:407/413; TS:183) | TESTED-shallow (TS:183) | TESTED-shallow (TS:183) | not-impl exit 2 (TS:183) |
| provided_version | TESTED (MH:306/315) | TESTED (MH:324/332/344) | TESTED (MH:353) | TESTED (MH:299) |
| detect / is_recommended | module-defined; no archetype-layer coverage (per-module only) | same | same | same |

Edge cases: dry-run guard TESTED broadly (MH:73/80, TS:130-146, TS:261 no leak); Sidecar
write/remove TESTED (MH:265-295, MH:422-462, EL:102/169); provided_version resolution fully
TESTED; not-installed remove idempotency for github-release only via EL:154; partial-install
cleanup asserted structurally (EL:154 + code comment) but the explicit "dirs present, Sidecar
absent" state is NOT separately tested.

### 3.3 Conformance / template testing

- No single registry-driven "every real module satisfies the contract" meta-test. Real-module
  lifecycle coverage is 39 ad hoc specs. The closest conformance harnesses are the
  TEMPLATE-level `template_smoke_spec.bats` (4 archetypes) + the entrypoint
  `libload_guard_spec.bats` (1 fixture module) + metadata-only iteration in registry/index/
  filter specs.
- Templates ARE tested: `template_smoke_spec.bats` materializes each template and drives the
  full standalone CLI + dry-run no-side-effect; `template_consistency_spec.bats` lints
  structure. Real (non-dry-run) template-shaped mutation is only covered indirectly through
  the three real modules in `engine_lifecycle_spec.bats`.

### 3.4 Untested macro-emitted branches (`lib/module_helper.sh`)

1. `module_default_apt_remove` :139-143 — body never executed (stubbed; integration apt is
   REDUCED at EL:232).
2. `module_default_apt_purge` :145-156 — entirely untested, incl. `APT_PPA --remove`
   (:148-150) and `CONFIG_PATHS` rm loop (:151-155).
3. `module_default_apt_install` — PPA branch (:107-116), no-sudo branch (:118-121), real
   `apt-get install` (:123-124) — unreached (only dry-run + empty-array).
4. `module_default_apt_upgrade` — no-sudo (:134) + real `--only-upgrade` (:135-136) untested.
5. `_module_github_release_fetch_and_install` — download-failed (:357-361) and non-gzip error
   (:362-366) branches never hit.
6. `module_default_github_release_purge` — CONFIG_PATHS rm loop (:411-415) untested.
7. `module_default_config_purge` :507-509 — never directly invoked.
8. `_module_config_drop` marker-only-stub else-branch :473-476 — untested.
9. `module_standalone_main` not-implemented dispatch — doctor/verify/upgrade not-impl paths +
   generic default (:719-721) untested (only `is-outdated` MH:549).
10. `module_emit_post_install` empty-message branch :756 — untested.

Note (false-confidence): `runner_doctor` IS covered by `test/unit/runner_spec.bats:286`, but
the function it tests is dead code from the Engine's perspective (never called in production).
A green test on an unreachable function.

### 3.5 Coverage-measurement caveats

- The AC-17 merged 80% kcov gate is UNIT-bats-only (memory `project-coverage-shards-unit-only`).
  The only real, non-dry-run exercise of the archetype mutation bodies
  (`engine_lifecycle_spec.bats`) is NOT in the kcov shards, so those `module_helper.sh` lines
  count as UNCOVERED in the gate even though integration runs them. To move the gate you must
  add UNIT tests that drive the default bodies directly (stub `apt-get`/`sudo`, call
  `module_default_apt_remove`/`_purge`). The apt remove/purge GAPs therefore both fail to run
  AND fail to count.
- `kcov --merge` exclude-region (memory `project-kcov-merge-exclude-region`): multi-line
  `declare -gA` tables read as instrumented-but-uncovered; in this layer the effect is small
  (per-module DESCRIPTION arrays), but headroom is thin (~80.5% vs 80% gate), so the untested
  apt bodies are a latent drag tolerated only because they are short.

---

## 4. Architecture observations

Applying the deletion test (would removing it lose real behavior?) and the leaky-abstraction
test:

- **Deep and sound (keep):** the three archetype macros are the deepest seam in the repo — ~6
  lines of module data hide ~120 lines of lifecycle (`lib/module_helper.sh:257-267` fronting
  the `module_default_*` bodies). Zero modules hand-write the Sidecar; the single write-site
  `_module_sidecar_after_phase` (:590-610) is correct and well-factored. The dual-mode
  bootstrap (`module_bootstrap.sh:38-62`) collapsed a 17-line per-module header to a 4-line
  stub. The template conformance + consistency specs are genuine deep tests, not smoke.

- **Contract contradicts recorded requirement (highest concern): `doctor()` unreachable from
  the Engine.** ADR-0002:24-29 and ADR-0009 REQUIRE authors to override `doctor` for
  runtime-surface modules, and the templates promise the Engine calls it
  (`module-apt.template.sh:134`) — but no production path does (`runner_doctor` uncalled;
  Engine `doctor` = `_dispatcher_doctor` drift report). So the mandated, hand-written
  `doctor()` overrides run only in standalone mode. This is a leak between the documented
  contract and the actual dispatch, and the templates actively misinform authors. Two options
  in the review (:124-131): wire `runner_doctor` to a `doctor <module>` subcommand (real fix),
  or delete `runner_doctor` + correct four template comments (honest downgrade).

- **Two sources of truth for version (F2):** Sidecar holds the resolved tag, state.json holds
  the static `VERSION_PROVIDED` literal; `list --installed` shows the wrong one. This directly
  violates the project's own "never maintain two parallel sources of truth" principle. Fix:
  capture `module_provided_version` once and feed both.

- **Non-uniform github-release `remove` (F4) + unguarded sudo on apt remove/purge (F5):** the
  archetype does not fully own remove semantics — modules re-add the is_installed gate ad hoc,
  and the no-sudo path can break the Sidecar invariant. Both are shallow spots where the
  default is not quite the whole abstraction.

- **`MODULE_GH_RESOLVED_VERSION` (F3):** an undocumented module->archetype global protocol; a
  borderline leaky abstraction absent from the github-release template.

- **Stale normative doc:** `doc/module-spec.md:326` still says "5 mandatory + 5 optional" and
  `update()`; every other authority says 10-mandatory + `upgrade`. The single source-of-truth
  doc disagrees with the ADRs it is supposed to encode.

- **Legacy duplication (`module/function/`):** `module/function/{general,logger}.sh` are dead
  originals of the `lib/` copies (`lib/logger.sh:4-6`), consumed only by one legacy module +
  ci.sh. Slated for deletion (Phase 7) but still present — a real duplicated pair.

Overall: the archetype/macro/bootstrap core is deep and well-tested at the pure-logic and
template-conformance level. The weaknesses are at the edges (apt real-mutation bodies untested;
purge defaults untested across all archetypes; no module-iterating conformance meta-test) and
in three contract-vs-code mismatches (doctor-unreachable, version-two-sources, stale spec).

---

## 5. Small-tool template proposal (DISCUSSION draft — nothing created)

### 5.1 Survey findings (`tool/`, `small-tools/`)

16 scripts surveyed. Uniform gaps vs repo conventions:
- No `--help`/usage on ANY script.
- No structured logging via the lib except `tool/setup_wayland.sh:6-8` (sources
  `function/logger.sh`); everyone else uses raw `echo`/ANSI `printf` banners.
- Strict-mode inconsistent: 10 of 16 have NO `set` line at all (ADR-0007 says always-act
  scripts should be `set -euo pipefail`). Missing `set -u` has already produced live bugs:
  undefined `FONT_NAMES` (`tool/remove/remove_font.sh:35`), always-true literal guards
  (`small-tools/install.sh:11,15,19,23`), typos (`remove_docker.sh:12`).
- Host installs present, violating the hard rule: `tool/dual_system_time_sync.sh:8`
  (`apt-get install ntpdate`), `small-tools/install.sh` (`apt`/`pip`),
  `small-tools/tools/eza.sh:2,9`, `small-tools/remove.sh`.
- Zero tests. `doc/TESTING.md:215` and `doc/review/test-pyramid-review.md:25` confirm
  `tool/` + `small-tools/` are intentionally excluded from coverage.

### 5.2 Decided legacy triage policy (context — do NOT re-litigate)

From `doc/prd/init-ubuntu.prd.md`: §6.5 (:290-306) — the whole `tool/` dir is a holding area,
not modularized in v0.1, per-file fate deferred to v0.2+; named genuine one-offs
(`dual_system_time_sync`, `trash-maintenance`, `ros1/*`, `remove/*`) stay scripts. §6.6
(:308-313) — `small-tools/` deprecates by 0.2.0, removed by 0.4.0 (AC-27). Promotion signal =
a GitHub issue; issue-backed reusable tools become `module/<name>.module.sh` (full contract,
tested). The proposed small-tool template is ONLY for genuinely one-off scripts that should
NOT become modules.

### 5.3 Proposed minimal skeleton (for discussion)

Header + strict mode (always-act default, ADR-0007 :84-88):

```
#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# Optional: reuse the repo logger instead of raw echo (pattern: tool/setup_wayland.sh:6-8)
# source "${SCRIPT_DIR}/../lib/logger.sh"   # provides log_info/log_warn/log_error/log_fatal

usage() {
  cat <<'EOF'
Usage: <tool-name>.sh [--dry-run] [--help]
  One-line purpose. One-off maintenance script (NOT a module).
EOF
}

main() {
  local dry_run="false"
  while (($#)); do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --dry-run) dry_run="true" ;;
      *) printf 'unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
  # idempotent, grep-guarded edits only (pattern: setup_wayland.sh:28,42,56)
  # NO host package install (hard rule). If you need packages, write a module.
}

main "$@"
```

Design choices, each grounded:
- `set -euo pipefail` because these are always-act scripts (ADR-0007 :84-88); fixes the 10
  scripts with no strict mode.
- Optional `source lib/logger.sh` rather than mandatory — a one-off may legitimately stay
  dependency-free; but if it logs, it should use `log_*` (`lib/logger.sh:172-176`) not raw
  ANSI. Note `log_fatal` exits 1, so use it deliberately.
- `usage()` + `--help` (exit 0) + unknown-arg (exit 2) mirrors the module standalone CLI
  contract the bats template already asserts (`test.template.bats:122-151`) — keeps exit-code
  semantics uniform with the rest of the repo.
- Explicit no-host-install comment enforces the hard rule (`AGENTS.md:40`) and encodes the
  promotion boundary: needing packages == promote to a module.
- Idempotency via grep-guarded edits, not blind `mv`/`cp` (avoids the
  `copy_neovim_local_config.sh:20` destroy-backup bug).

### 5.4 Proposed small-tool bats test template (for discussion)

Currently NO test exists for any `tool/`/`small-tools/` script, and they are deliberately
excluded from coverage — so a test template must decide whether these newly-templated tools
opt INTO the harness. Minimal shape mirroring `template/test.template.bats`:

```
#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../helper/common"

setup()    { setup_test_env; }
teardown() { teardown_test_env; }

@test "<tool>: --help prints usage and exits 0" {
  run bash "${REPO_ROOT}/tool/<tool>.sh" --help
  assert_success
  assert_output --partial "Usage:"
}

@test "<tool>: unknown arg exits 2" {
  run bash "${REPO_ROOT}/tool/<tool>.sh" --nope
  assert_failure 2
}

@test "<tool>: --dry-run performs no filesystem mutation" {
  run bash "${REPO_ROOT}/tool/<tool>.sh" --dry-run
  assert_success
  # assert target file/state unchanged
}
```

This gives one-off tools the same three cheap guarantees modules already prove (help/exit-2/
dry-run) without pulling them into the full 10-function lifecycle contract. Open question below
on whether these should count toward coverage.

---

## 6. Open questions for the maintainer

1. **doctor-unreachable (F1):** wire `runner_doctor` into a real `doctor <module>` Engine
   subcommand, or delete it and correct the four template comments? The ADR-0002/0009 mandate
   to override `doctor` is currently only honored in standalone mode.
2. **version two-sources (F2):** which is canonical for `list --installed` — the resolved
   Sidecar tag or the static `VERSION_PROVIDED`? Should state.json record
   `module_provided_version` instead?
3. **module-spec.md staleness:** update §4.1 to "10 mandatory" and `upgrade` (drop `update()`
   / 5+5) so the single source-of-truth doc matches ADR-0002 / CONTEXT.md / the cookbook?
4. **apt archetype real-body coverage:** add UNIT tests (stubbed `apt-get`/`sudo`) for
   `module_default_apt_remove`/`_purge`/`_install`/`_upgrade` so they both execute and count
   toward the gate? Currently GAP + uncounted.
5. **purge defaults:** every archetype's `purge` default is untested (only dry-run) — worth a
   targeted unit for each?
6. **conformance meta-test:** add a registry-driven "every real module exposes the 10-function
   contract" test, or keep 39 ad hoc specs + the template conformance loop?
7. **github-release remove uniformity (F4) + unguarded sudo (F5):** push the is_installed gate
   and the `have_sudo_access` guard into the archetype default (data-flagged), or leave per
   module?
8. **`module/function/` legacy pair:** execute the Phase-7 deletion now, or keep until the one
   legacy consumer (`setup_nvidia_driver.sh`) is retired?
9. **small-tool template scope:** adopt the §5 skeleton for genuine one-offs? Should the bats
   test template opt these tools INTO coverage, or keep `tool/`/`small-tools/` excluded per
   `doc/TESTING.md:215`?
