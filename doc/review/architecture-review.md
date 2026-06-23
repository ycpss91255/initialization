# System-Architecture Review — init_ubuntu

- **Date:** 2026-06-23
- **Tag reviewed:** v0.1.0-rc3 (`b6c88bc`, main checkout)
- **Lens:** System architecture (module system, engine, TUI, coupling/layering, ADR adherence)
- **Mode:** READ-ONLY audit. No code was modified. This document raises problems
  for the maintainer to decide on; it does not resolve them. Vocabulary follows
  CONTEXT.md (module / archetype / lifecycle / Sidecar / tier / Rich / Fallback /
  producer / broker / seam / Synced-Local / depth / shallow / leverage).

---

## Executive summary

The rc3 architecture is, on the whole, **sound and deliberately designed**. The
three subsystems each have at least one genuinely deep module and at least one
real seam that survives a deletion test:

- **Module system:** the archetype macros are the strongest seam in the
  codebase — ~6 lines of module data hide ~120 lines of lifecycle logic, and
  ADR-0027 (Sidecar at the phase-invocation layer, macros emit all 10 lifecycle
  functions) is correctly implemented with a single Sidecar write site and zero
  modules hand-writing the Sidecar.
- **Engine:** Environment's probe-under-classify layering with a genuinely pure
  classifier is the cleanest deep module in the repo; State's two internal seams
  (migrate, io) pass the deletion test and are reached through the State
  interface; the Runner's sub-shell isolation and Sidecar -> exit -> state.json
  write ordering are correct and documented.
- **TUI:** G4 (TUI sources no engine lib, forks the CLI, writes no State) is
  structurally upheld and the grep gate is real; ADR-0025 (no free-form text,
  confirmation delegated to the CLI) is fully honored; the #6 screen registry
  and #7 broker are both real seams.

The findings below are refinements, not foundations. They cluster into four
themes: (1) a small number of **two-sources-of-truth / seam-bypass** spots where
a fact or a mechanism is encoded in two places; (2) **`doctor()` reachability** —
per-module `doctor()` overrides never run under the Engine, and the templates
claim they do; (3) **three files over the 800-line ceiling** (`dispatcher.sh`
1291, `tui_backend.sh` 1344, `setup_ubuntu_tui.sh` 1535) with clean split lines
available; (4) **ADR drift in the PRD and the gum module's self-description**,
which still describe the superseded gum two-backend model.

Counts by strength: **3 Strong, 9 Worth exploring, 2 Speculative** (plus ADR-drift
notes, tracked separately below).

Top 3 architectural issues:

1. **F1 (Strong):** per-module `doctor()` overrides are unreachable from the
   Engine; `runner_doctor()` is dead code; all four templates tell authors the
   opposite. (`lib/runner.sh`, `lib/dispatcher.sh`, `template/*.template.sh`)
2. **E1 (Strong):** `lib/dispatcher.sh` (1291 lines) is a god-file by size with
   clean responsibility-cluster seams available (catalog / lifecycle / state-io),
   and a module-metadata-as-JSON renderer duplicated 3x within it.
3. **T1 (Strong):** `setup_ubuntu_tui.sh` (1535 lines, ~2x the cap) carries the
   fzf navigator loop that belongs in `lib/tui_render_fzf.sh` (the
   `tui_secrets.sh` extraction already set this precedent).

---

## Strengths to preserve

The maintainer should treat the following as load-bearing and resist eroding
them during any remediation:

- **Archetype macros are deep (module system).** `module_use_apt_archetype` /
  `_github_release_archetype` / `_config_archetype` (`lib/module_helper.sh`)
  each emit 9 lifecycle functions from one call; `detect` + `is_recommended`
  stay module-defined by design. Small interface, large hidden implementation.
- **Sidecar write-site unification (ADR-0027) is correct.** One write site
  (`_module_sidecar_after_phase`), reached from both the Runner
  (`lib/runner.sh`) and Standalone (`module_standalone_main`); zero modules
  hand-write the Sidecar. The idempotent-reinstall version-preservation edge
  case (github-release default reads the existing Sidecar when no resolution
  happened) is handled correctly.
- **Environment probe-under-classify (engine).** `_environment_classify` is a
  pure function over a JSON string — testable with a fixture, no host needed.
  This is the model the rest of the engine should aspire to.
- **State seams pass the deletion test (engine).** `state_migrate.sh` and
  `state_io.sh` each concentrate a distinct concern (schema evolution policy;
  cross-machine portability) that would bloat `state.sh` if inlined. Migration
  is folded into `state_init` with a clean validate -> migrate -> ready chain,
  fatal on failure (ADR-0008). The corruption guard quarantines rather than
  silently rebuilding.
- **Runner isolation + write ordering (engine).** The `(...)`-fork-vs-`bash -c`
  decision is documented and correct (keeps BASH_SOURCE/FUNCNAME bound for kcov
  under `set -u`); Sidecar (in child) -> exit -> state.json (in parent) ordering
  is right; state writes degrade gracefully (`|| log_warn ... continuing`).
- **Resolver is never bypassed** for dependency-bearing lifecycle (only the
  explicit `--no-deps` opt-out skips it).
- **G4 is structurally upheld (TUI)** and the enforcement gate is real. The one
  intentional duplication (`_tui_has_sudo` re-implementing preflight logic) is
  documented with its G4 rationale.
- **#6 screen registry and #7 broker are genuine seams (TUI).** The registry
  collapses a 3-site token dispatch into one map; the broker doubles as the fzf
  `--preview` performance cache (avoids re-forking `list --json` on every cursor
  move) and the unit-test injection seam.
- **ADR-0025 fully honored (TUI):** one sanctioned input widget for non-secret
  args only; secret values stay on the tool's own no-echo tty (AC-20);
  confirmation delegated to the forked CLI via `-y`.
- **Two TUI tiers share producers (ADR-0024 intent realized):** Quick Setup,
  Manage, Secrets, Review, and msgbox are delegated by the fzf Rich tier to the
  same shared dialog screens; the tiers diverge only in navigation.

---

## Findings

Each finding: ID, area, problem (project vocabulary), friction axis, file/module
refs, remediation OPTION (described, not applied), strength.

### F1 — Per-module `doctor()` is unreachable from the Engine; templates claim it runs

- **Area:** Module system / Engine boundary
- **Problem:** `runner_doctor()` exists in `lib/runner.sh` but nothing calls it
  (its only occurrence is its own definition). The Engine `doctor` subcommand
  routes to `_dispatcher_doctor` (`lib/dispatcher.sh`), which is a state.json
  vs `is_installed` drift report and only sources each module to run
  `is_installed` — it never calls the module's `doctor()`. So the rich
  `doctor()` overrides (Sidecar-drift detection, daemon checks, metadata
  self-checks) in lazygit, notion, eza, lazydocker, claude-code-config are
  reachable **only** in Standalone mode. All four `template/*.template.sh`
  files assert the opposite: "Engine calls this from `setup_ubuntu doctor`.
  Without it, doctor falls back to is_installed."
- **Friction:** leverage + locality. An author follows the template, writes a
  `doctor()`, and it silently never runs under the Engine; the Engine therefore
  cannot detect the very Sidecar drift the overrides were written to catch.
- **Remediation OPTION:** (a) route a new `doctor <module...>` Engine subcommand
  to `runner_doctor` (the plumbing exists end-to-end), keeping the no-arg
  `doctor` as the drift report; or (b) if Engine-side module `doctor()` is
  deliberately out of scope for 0.1.0, delete `runner_doctor` and correct the
  four template comments. (b) is the lower-risk rc3 fix; (a) is the real fix.
- **Strength:** Strong (the inaccuracy lives in author-facing templates).

### F2 — state.json version diverges from the Sidecar version (two sources of truth)

- **Area:** Module system / State
- **Problem:** On install/upgrade the Runner records two version strings from
  two sources: the **Sidecar** gets `module_provided_version()` (dynamic,
  resolves the real tag); **state.json** gets the static `${VERSION_PROVIDED}`
  literal (`lib/runner.sh`). For every github-release module
  `VERSION_PROVIDED="latest"`, so the Sidecar holds e.g. `0.44.1` while
  state.json holds `latest`. `list --installed` prints the state.json value, so
  the user-facing version column shows `latest`, never the resolved tag — the
  accurate value exists in the Sidecar but the Engine's primary view ignores it.
- **Friction:** locality. This is the one real "two parallel sources of truth
  for the same fact" in the contract (directly the failure mode the project's
  own "unify formats" principle warns against).
- **Remediation OPTION:** have the Runner capture `module_provided_version` once
  and feed both the Sidecar and `state_record_install`/`_upgrade`, instead of
  passing the static `${VERSION_PROVIDED}`. The value must be plumbed out of the
  sub-shell fork; cleanest is to read the just-written Sidecar in the parent.
- **Strength:** Worth exploring.

### F3 — `MODULE_GH_RESOLVED_VERSION` is an undocumented module-to-archetype protocol

- **Area:** Module system / archetype seam
- **Problem:** github-release `module_provided_version` reads
  `MODULE_GH_RESOLVED_VERSION` (`lib/module_helper.sh`), set by each module's own
  resolver (lazygit, notion, lazydocker). A module author cloning lazygit must
  know to set this magic global or the Sidecar records `latest`. It is a
  semi-private protocol not mentioned in the github-release template — borderline
  leaky abstraction (a module must know an archetype-internal convention).
- **Friction:** depth / discoverability.
- **Remediation OPTION:** one-line mention in `template/module-github-release.template.sh`
  documenting the var, or have the archetype expose a `module_set_resolved_version`
  setter so the convention is a named seam rather than a bare global.
- **Strength:** Worth exploring.

### F4 — github-release `remove` short-circuit is split across default vs per-module override

- **Area:** Module system / archetype
- **Problem:** `module_default_github_release_remove` (`lib/module_helper.sh`)
  deliberately has no `is_installed` gate (so it cleans Sidecar-less partial
  installs). lazydocker (`module/lazydocker.module.sh`) and notion re-add the
  gate via override; eza/lazygit/neovim inherit the ungated default. The
  "should remove short-circuit on a clean box?" decision is thus made in two
  layers with opposite defaults, discoverable only by reading each module body.
- **Friction:** depth (a shallow spot) — remove semantics are non-uniform across
  one archetype, though no current bug.
- **Remediation OPTION:** an opt-in data flag
  (`GITHUB_RELEASE_REMOVE_SKIP_IF_ABSENT=true`) read inside the archetype
  default, keeping the decision data-driven instead of re-implemented per module.
- **Strength:** Worth exploring.

### F5 — apt `remove`/`purge` and docker `purge` call `sudo` unguarded

- **Area:** Module system / archetype error handling
- **Problem:** `module_default_apt_install` guards `have_sudo_access`, but
  `module_default_apt_remove`/`_purge` (`lib/module_helper.sh`) and docker's
  hand-written `purge` (`module/docker.module.sh`) call `sudo apt-get` directly
  with `|| true`. On a no-sudo host these prompt or fail silently, leaving the
  Sidecar removed (the wrapper runs on rc==0) while packages remain.
- **Friction:** error handling / Sidecar-invariant integrity on an edge host.
- **Remediation OPTION:** mirror the install-side `have_sudo_access` guard in the
  remove/purge defaults (warn + return 1 when sudo absent).
- **Strength:** Speculative (single-maintainer sudo-capable target makes this
  near-theoretical).

### E1 — `lib/dispatcher.sh` (1291 lines) is a god-file with clean split lines

- **Area:** Engine / Dispatcher
- **Problem:** 1291 lines, ~61% over the 800 ceiling. Cohesive-by-subcommand but
  carrying distinct responsibility clusters: catalog views (list/show/search +
  their JSON renderers, the densest non-routing logic), lifecycle orchestration
  (install/remove/purge/upgrade/verify), state-I/O frontend
  (export/import/status), environment frontend (detect), and doctor/config. The
  module-metadata-as-JSON rendering appears 3x (`list --json`, `show --json`,
  `import` diff) with a `jq -cn '$ARGS.positional'` array-building pattern
  repeated 10+ times.
- **Friction:** locality + leverage (a change to one verb requires navigating a
  1291-line file; the duplicated JSON renderer drifts).
- **Remediation OPTION:** split along clusters into `dispatcher_catalog.sh`
  (list/show/search + JSON renderers, ~300 lines, most self-contained),
  `dispatcher_lifecycle.sh`, `dispatcher_stateio.sh`, with core `dispatcher.sh`
  keeping routing + global flags + detect/doctor/config; extract one
  "render module metadata as JSON" helper shared by list and show.
- **Strength:** Strong.

### E2 — Dispatcher reads state.json raw and re-sources modules, bypassing the State interface and the Runner

- **Area:** Engine / coupling
- **Problem (two leaks):**
  (A) `_dispatcher_list_installed` (`lib/dispatcher.sh`) reads the state file via
  `state_get_path` + `cat` and synthesizes the empty `{"version":...,"installed":{}}`
  skeleton itself — reaching past the State interface to the raw document and
  re-encoding the top-level shape outside `state.sh`.
  (B) `_dispatcher_doctor`, `_dispatcher_module_description`, and
  `_dispatcher_list_catalog_json` each fork-source modules with their own
  `bash --noprofile --norc -c "source ...; <fn>"` incantation. The Runner owns
  "source a module in an isolated sub-shell," but doctor/list/show re-implement
  it — four slightly different isolation harnesses now exist (Runner +
  dispatcher x3). Note `_dispatcher_doctor` uses the exact `bash -c` form the
  Runner explicitly rejects in its own comments (BASH_SOURCE/FUNCNAME unbound
  under `set -u` + kcov), a latent coverage/`set -u` hazard.
- **Friction:** consistency + testability (doctor's drift logic has no seam to
  inject a fake "is this installed on the host"; testing needs a real host).
- **Remediation OPTION:** add a `state_dump_json` accessor returning the document
  (or skeleton when absent) for (A); extract one `module_in_subshell` /
  `runner_probe <module> <fn>` seam that the Runner, doctor, list-json, and show
  all call for (B). The second also makes doctor's drift logic testable.
- **Strength:** Worth exploring.

### E3 — State Synced/Local shape is read directly by `state_io.sh` (read-side leak)

- **Area:** Engine / State seam
- **Problem:** writes are disciplined — every writer goes through the `state.sh`
  `record_*` functions, and `state_io` uses the public `state_set_synced` for
  writes. But for reads, `_state_io_modules_array` and `state_io_import_plan`
  (`lib/state_io.sh`) pull `.installed[name].synced` out of the raw file with jq.
  So the on-disk path "synced lives at `.installed[name].synced`" is encoded in
  two files; an on-disk schema change must land in both in lockstep.
- **Friction:** locality (the Synced/Local invariant is partly outside the State
  module that owns it).
- **Remediation OPTION:** a `state_each_synced` / `state_export_synced [names...]`
  accessor yielding `{name, synced}` pairs, consumed by `_state_io_modules_array`.
- **Strength:** Worth exploring.

### E4 — Environment's hand-rolled JSON extractors rely on writer/reader co-discipline

- **Area:** Engine / Environment
- **Problem:** `_environment_extract_str`/`_extract_bool` (`lib/environment.sh`)
  match on literal substring anchors (`'"virt":'`, `'"wsl":'`). They work today
  only because the writer emits keys in a fixed order, the anchors are not
  substrings of one another, and values carry no escaped quotes — the file
  deliberately avoids jq because Environment runs *before* the jq preflight. The
  `gpu.model` field (straight from `lspci`) is the most likely to carry odd
  characters. This is a closed-world invariant held by co-discipline, not
  structure, and is not asserted by a test. Separately, `_environment_probe_os`
  sources `/etc/os-release` into the current shell and only restores three of the
  variables it sets (`NAME`/`PRETTY_NAME`/etc. leak), contained today only
  because callers run it in `$(...)`.
- **Friction:** testability + a latent footgun.
- **Remediation OPTION:** add a fixture-based test feeding adversarial
  `gpu.model` strings through snapshot -> field; source `/etc/os-release` inside
  a subshell and echo the needed fields out (the cleaner `_runner_snapshot_os`
  pattern already exists in `lib/runner.sh`).
- **Strength:** Worth exploring (no live bug found; the no-jq design goal is
  intentional, so the remediation is a test + the os-release subshell, not a jq
  rewrite).

### T1 — `setup_ubuntu_tui.sh` (1535 lines) carries the fzf navigator loop that belongs in the render lib

- **Area:** TUI / Rich tier
- **Problem:** 1535 lines, ~2x the cap. Distinct responsibilities: bootstrap +
  i18n table, whiptail-tier screen flows, the fzf Rich-tier navigator loop, the
  #6 registry, dispatch + whiptail main loop, and `main()` arg parsing. The fzf
  navigator (`_tui_fzf_run` through `_tui_fzf_main_loop`, ~210 lines) is the only
  fzf-tier orchestration not already in `lib/tui_render_fzf.sh`, where the
  producers live.
- **Friction:** depth (entrypoint too deep) + locality (the loop that drives the
  fzf binary lives oddly in the entrypoint, away from its render producers).
- **Remediation OPTION:** move the fzf navigator loop into
  `lib/tui_render_fzf.sh` so it owns the full Rich tier (loop + render), mirroring
  how `lib/tui_secrets.sh` owns its full screen set (a precedent set for exactly
  this reason). The `--preview`/`--toggle` re-invocation modes stay in the
  entrypoint (CLI dispatch). Drops the entrypoint to ~1320.
- **Strength:** Strong.

### T2 — Sel-stats and main-menu rows are produced per-tier (tier drift risk)

- **Area:** TUI / shared data layer
- **Problem:** the selection-count jq is duplicated: `tui_category_sel_stats` /
  `tui_subcategory_sel_stats` (`lib/tui_backend.sh`) vs
  `tui_fzf_category_sel_stats` / `_tui_fzf_subtag_stats`
  (`lib/tui_render_fzf.sh`) — same `contains` counting jq in 4 blocks across 2
  files (the code admits the coupling in comments: "Mirrors ... so both tiers
  agree"). Separately, `tui_main_menu_entries` (`lib/tui_backend.sh`) and
  `tui_fzf_menu_rows` (`lib/tui_render_fzf.sh`) independently re-list the same
  menu rows. The two tiers are meant to share producers and diverge only in
  navigation (ADR-0024); these are the spots where a schema or counting-semantics
  change must land in both tiers or they silently desync.
- **Friction:** drift between tiers.
- **Remediation OPTION:** one `tui_sel_stats <json> <category> [<subtag>] <selected>`
  producer in the data layer that both tiers project; one `tui_menu_model`
  producer both tiers project (whiptail adds the desc column, fzf prefixes
  `menu:`).
- **Strength:** Worth exploring.

### T3 — Whiptail render adapters live in the shared data-layer file

- **Area:** TUI / layering
- **Problem:** the whiptail render adapters and dispatchers sit at the bottom of
  `lib/tui_backend.sh` (the shared data layer), not in a render file. They are
  the Fallback *render tier*, not shared data. They live there because the
  `_tui_backend_family` indirection was built when gum was a second family;
  today it always returns `"whiptail"` (vestigial single-value dispatch).
- **Friction:** locality (a render tier mislocated in the data layer); mild.
- **Remediation OPTION:** extract the whiptail adapters into
  `lib/tui_render_whiptail.sh` to mirror `lib/tui_render_fzf.sh`, leaving
  `tui_backend.sh` as purely the shared data layer; retire the vestigial
  `_tui_backend_family`. Drops ~110 lines off the data-layer file.
- **Strength:** Worth exploring.

### T4 — `transitive()` reverse-dependency jq closure and `.tags[0] // "other"` bucketing are duplicated

- **Area:** TUI / schema coupling
- **Problem:** the `transitive($n)` reverse-dependency jq `def` appears twice in
  `lib/tui_backend.sh` (provenance + checklist sort) — identical ~9-line closure;
  a fix must land in both. The `.tags[0] // "other"` bucketing convention
  (no-tag -> "other") is repeated ~5x in `tui_backend.sh` + 2x in
  `tui_render_fzf.sh`; the most fragile schema dependency, since changing the
  default means editing 7 jq fragments.
- **Friction:** drift / testability.
- **Remediation OPTION:** factor the `transitive()` closure into one shared jq
  snippet/producer; route the inline `.tags[0] // "other"` copies through the
  existing `tui_subtags` / `tui_modules_in_subcategory` producers that already
  centralize the rule.
- **Strength:** Worth exploring.

### T5 — Duplicated `--backend` argument-parsing arms

- **Area:** TUI / entrypoint
- **Problem:** `main()` in `setup_ubuntu_tui.sh` has a fully duplicated
  `fzf|whiptail / gum / *` case block for `--backend X` vs `--backend=X`
  (~36 near-identical lines).
- **Friction:** locality.
- **Remediation OPTION:** a `_tui_parse_backend_value` helper used by both arms.
- **Strength:** Speculative.

---

## ADR-drift notes (note, do not fix)

The code at rc3 leads the docs in several places. Code is correct against the
standing ADRs; the following docs are stale and should be reconciled before tag.

- **D1 (significant) — PRD §8 TUI wireframe describes the superseded gum
  two-backend model.** `doc/prd/init-ubuntu.prd.md` §8.5 (the backend-detection
  section) still documents "ADR-0023: gum 優先, whiptail fallback, dialog 已移除",
  the `command -v gum` detection ladder, the `read -rp "Install gum...?"` prompt,
  and "後端集合固定為 gum + whiptail ... 4 個 contract widget". This directly
  contradicts ADR-0024 (fzf Rich tier two-pane navigator + whiptail Fallback,
  gum dropped as a backend) and ADR-0025 (no input widget, confirmation delegated
  to the CLI). The PRD does reference fzf elsewhere (21 hits), so §8 is partially
  but not fully migrated. **AC-10** in the same PRD still reads "TUI (gum 與
  whiptail 兩種後端, ADR-0023)" and references `smoke_flow_gum.exp`. This is the
  primary product spec describing an interaction model that no longer ships.
  Options: rewrite PRD §8 + AC-10 against ADR-0024/0025, or mark §8 explicitly
  superseded (as the `doc/design/*.md` files already are).

- **D2 (minor) — gum module self-description still calls gum "the preferred
  modern TUI backend".** `module/gum.module.sh` header comment (line 4) and
  `DESCRIPTION[en]` (line 48) both say "(preferred modern TUI backend)", and
  `doc/module/INDEX.md` repeats it. Per ADR-0024 gum is **dropped as a backend**
  and survives only as an installable tool. The module's continued existence is
  correct (ADR-0024 explicitly keeps gum installable); only the "preferred TUI
  backend" wording is stale and user-visible via `setup_ubuntu show gum`.
  Option: reword to describe gum as a general shell-script styling tool.

- **D3 (acceptable, already flagged) — `doc/design/tui-architecture.md` and
  `tui-uiux.md` are explicitly marked "Superseded in part by ADR-0024"** and
  describe the gum-era modal model. They carry their own staleness banner, so
  this is acknowledged, not silent drift — but a reader could still mistake them
  for current spec. Option: leave as historical, or move under a `doc/design/legacy/`
  path to make the status unmissable.

- **D4 (cosmetic) — lingering `dialog` references in test docs.**
  `doc/TESTING.md` lists `dialog + whiptail` as a TUI backend test dependency
  and the test-tools image; `dialog` was dropped (ADR-0023, retained-dropped in
  ADR-0024). If the test-tools image no longer ships `dialog`, the doc overstates
  the dependency. Option: verify against `dockerfile/Dockerfile.test-tools` and
  trim.

No code was found that **contradicts** a standing ADR — the drift is doc-lags-code,
not code-violates-ADR. The G4 grep gate, ADR-0024 tier split, ADR-0025 input
delegation, ADR-0026 per-tool modules (apt-essentials removed, git/vim/curl/wget/jq
modules present), and ADR-0027 Sidecar-at-invoker are all upheld in the code.

---

## Open questions for the maintainer

1. **Is Engine-side module `doctor()` in scope for 0.1.0?** (F1) The answer
   decides whether `runner_doctor` gets wired to a new `doctor <module>`
   subcommand or deleted, and how the four templates are corrected. This is the
   one finding that touches author-facing contract text.

2. **Which version string is canonical for the user-facing view — Sidecar
   (resolved tag) or state.json (`VERSION_PROVIDED` literal)?** (F2) `list
   --installed` currently shows `latest` for every github-release module. Is that
   intended, or should the Engine surface the resolved tag the Sidecar already
   holds?

3. **Is the per-tier production of sel-stats / menu rows (T2) and the four
   module-sourcing harnesses (E2-B) acceptable for 0.1.0,** or should they be
   unified before tag? They are the spots where tier drift / isolation drift is
   structurally possible but not currently broken.

4. **Should the three over-800-line files (`dispatcher.sh`, `tui_backend.sh`,
   `setup_ubuntu_tui.sh`) be split before 0.1.0,** or is the 800-line guideline a
   soft target deferred to 0.2.0? Clean split lines exist for all three (E1, T1,
   T3); the question is timing, not feasibility.

5. **PRD §8 / AC-10 reconciliation (D1) before the 0.1.0 tag:** rewrite against
   ADR-0024/0025, or mark superseded? The first tag is meant to ship the
   redesigned TUI, and the primary spec still describes the old one.
