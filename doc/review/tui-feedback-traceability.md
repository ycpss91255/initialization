# TUI Founding-Feedback Traceability Audit (v0.1.0-rc3)

Scope: the round-1 + round-2 user feedback (verbatim in the review notes; source
list reproduced from the founding TUI redesign) that drove the 0.1.0 TUI
redesign. For each of the 18 distinct items: (a) is it FIXED in the code at
`v0.1.0-rc3`, and (b) is there a TEST that asserts the fixed behavior?

- Audited tree: `HEAD = 9cad3f4` (one docs-only commit past the tag).
  `git diff v0.1.0-rc3..HEAD -- lib/ setup_ubuntu_tui.sh module/ test/` is EMPTY,
  so the audited code is byte-identical to `v0.1.0-rc3` (`b6c88bc`).
- Method: read-only. Code cited as `file:line` / function; tests cited as
  `spec file` + exact `@test` name + the load-bearing assertion.
- Verdict vocabulary: FIXED+TESTED / FIXED-NOT-TESTED / PARTIAL / NOT-FIXED.
- Grounding: ADR-0024 (fzf two-pane Rich tier + whiptail Fallback parity, D1-D12),
  ADR-0025 (TUI delegates text input to CLI), ADR-0026 (per-tool base modules,
  split apt-essentials), ADR-0027 (Sidecar). CONTEXT.md domain glossary.

Two tiers share one data layer and diverge in rendering: the **Rich tier** (fzf
two-pane navigator) and the **Fallback tier** (whiptail). The user's screenshots
in the feedback are all the whiptail Fallback tier.

---

## Round 1

### Item 1 — Quick Setup shows too little; show ALL items before install

- Decision: PRD #213 pre-install show-all summary; commit #239.
- Code: `setup_ubuntu_tui.sh:783` `_tui_qs_preinstall_summary()`, wired at
  `:847` (`_tui_qs_preinstall_summary "${_list_json}" "${_sel[@]}" || return 0`),
  runs after Review and before the install fork. It forks
  `tui_cli_install_plan` (`:787`) to enumerate the FULL resolved plan (picks +
  engine-pulled deps), rendered via `tui_summary_text` ->
  `tui_review_text` (`lib/tui_backend.sh:650-660`).
- Test: `test/unit/tui_review_provenance_spec.bats`
  `@test "e2e qs summary: lists picks AND pulled deps before the fork"` (L145):
  `assert_output --partial "Pre-install Summary"`,
  `assert_output --partial "docker (your selection)"`,
  `assert_output --partial "curl (required by docker)"` — proves the pre-install
  screen lists both the pick and its engine-pulled dep.
- Verdict: FIXED+TESTED.

### Item 2 — Base tools shown as ONE line; want itemized per-tool list

- Decision: ADR-0026 per-tool base modules + list render; ADR-0024 two-pane rows.
- Code: data model — no `apt-essentials.module.sh`; per-tool base modules exist
  (`module/git.module.sh` etc.), each `CATEGORY="base"`. Render —
  `lib/tui_render_fzf.sh:253` `tui_fzf_sub_rows()` emits one `mod:<name>` row per
  module; single-bucket `base` drops straight to those leaf rows
  (`tui_fzf_cat_rows`, `:271`).
- Test: `test/unit/tui_render_fzf_spec.bats`
  `@test "cat_rows: a single-bucket category goes straight to mod: leaf rows"`
  (L170): `assert_output --partial "mod:curl"`, `refute_output --partial "sub:base"`
  — base renders as individual leaf rows, not one bundle line.
- Verdict: FIXED+TESTED.

### Item 3 — Recommended: after checking + Enter, main menu still shows (0/7)

- Decision: ADR-0024 D2 (category rows show SELECTED/total from the live
  accumulator).
- Code: `lib/tui_backend.sh:716` `tui_category_sel_stats` (jq selected count);
  main-menu label appends `(${_sel}/${_tot})` at `lib/tui_backend.sh:1164` and
  `lib/tui_render_fzf.sh:329-332`. Re-derived every loop pass:
  `setup_ubuntu_tui.sh:1313-1314` (whiptail), `:1114` (fzf).
- Test: `test/unit/tui_render_fzf_spec.bats`
  `@test "menu_rows: selecting a module bumps that category's SELECTED count"`
  (L213): toggles docker, `assert_output --partial "Recommended (1/3)"`. Also
  `test/unit/tui_backend_spec.bats` `@test "...category rows show SELECTED/total
  from the accumulator (D2)"` (L188): `assert_line --partial "Optional (2/3)"`.
- Verdict: FIXED+TESTED.

### Item 4 — Recommended: sub-categories, most-basic-first, not lumped

- Decision: sub-categorize + basic-first (#235); nested drill-down phase 3 (#258).
- Code: bucketing `lib/tui_backend.sh:707` `tui_subtags`; fzf drill-down
  `lib/tui_render_fzf.sh:271` `tui_fzf_cat_rows` (emits `sub:<cat>:<bucket>` when
  >1 bucket); basic-first ordering `lib/tui_backend.sh:782`
  `tui_checklist_entries` (rank = transitive reverse-dep count, `sort_by`
  at `:817-818`).
- Test: `test/unit/tui_backend_spec.bats`
  `@test "tui_checklist_entries (#212) orders sub-category groups basic-first"`
  (L525): asserts first tag owns the most-depended-on module, last is
  `[aaa-early]` — dependency rank beats alphabetical. Sub-category branch rows:
  `test/unit/tui_render_fzf_spec.bats`
  `@test "cat_rows: a multi-bucket category yields sub: branch rows with counts"`
  (L162): `assert_output --partial "sub:recommended:container"`.
- Verdict: FIXED+TESTED.

### Item 5 — Optional: same as Recommended (sub-categories + basic-first)

- Decision: nested drill-down phase 3 (#258).
- Code: same category-agnostic machinery as Item 4 — `tui_fzf_cat_rows`
  (`lib/tui_render_fzf.sh:271`) and `_tui_screen_category`
  (`setup_ubuntu_tui.sh:506`) branch on `subtag_count > 1` for any category;
  `tui_checklist_entries` orders basic-first regardless of category. Optional
  resolves to 2 buckets (agent + cli-essentials).
- Test: `test/unit/tui_whiptail_tier_spec.bats`
  `@test "tui_subtags: distinct TAGS[0] buckets of a category, alphabetical"`
  (L39, runs on `optional`): `assert_line --index 0 "agent"`,
  `--index 1 "cli-essentials"`; `@test "tui_subtag_count: counts the distinct
  buckets"` (L53): `optional` -> `assert_output "2"`. Basic-first ordering test
  (L525 above) runs `tui_checklist_entries ... optional ""`.
- Verdict: FIXED+TESTED. Minor: the fzf `cat_rows`-yields-`sub:`-rows test uses
  the `recommended` fixture, not `optional`; optional's bucketing/ordering are
  covered by the whiptail-tier producers (shared code path).

### Item 6 — Main-menu separator "-------": auto-skip? pressing it jumps to Quick Setup

- Decision: verify separator is non-selectable / removed and the jump-back bug is
  gone (#216).
- Code: separators were REMOVED entirely, not made skippable.
  `lib/tui_backend.sh:1176-1178` comment: "no separator rows: whiptail has no
  non-selectable row, so a divider could be landed on and was confusing — #216
  removed them; ordering conveys the grouping". `tui_main_menu_entries`
  (`:1173`) emits only real, selectable action rows. With no divider row there is
  nothing to land on, so the jump-back-to-Quick-Setup behavior is structurally
  eliminated.
- Test: `test/unit/tui_backend_spec.bats`
  `@test "tui_main_menu_entries renders all action rows in order, no separators
  (#216)"` (L221): `refute_output --partial "──────"`,
  `refute_line --regexp $'^-\t'`, and asserts the exact tag sequence
  `quick-setup base recommended optional manage secrets sysinfo help run` — every
  row is a real selectable tag; no divider exists.
- Verdict: FIXED+TESTED. (The fix is deletion of the separator, which is the
  correct resolution of both the "auto-skip?" and "jump-back" complaints.)

### Item 7 — Manage Installed: two "unknown" entries, cannot see their detail

- Decision: module detail view + unregistered clarity (PRD #211/#215; commit #238).
- Code: `setup_ubuntu_tui.sh:898-922` `_tui_screen_manage_action` adds a read-only
  `detail` action -> `_tui_screen_detail` (`:442-457`), which forks `show --json`
  and, on failure (module absent from registry), falls back to
  `tui_detail_unregistered_text` (`lib/tui_backend.sh:1119-1133`). Unregistered
  rows are marked in the list (`tui_installed_entries`, `:996`).
- Test: `test/unit/tui_detail_spec.bats`
  `@test "e2e: Manage Installed detail action on an unregistered entry shows the
  catalog note"` (L385): drives `manage -> ghost -> detail` where
  `show ghost --json` exits 2, `assert_output --partial "catalog"`. Plus
  `@test "e2e: Manage Installed detail action shows a registered module's detail"`
  (L367).
- Verdict: FIXED+TESTED.

### Item 8 — System Info screen "gum: error: unknown flag" then prints the env table

- Decision: the #248 TUI_BACKEND-unset delegated-screen bug fix.
- Code: fixed at `setup_ubuntu_tui.sh:1497-1508` (main) — defaults
  `TUI_BACKEND=whiptail` whenever nothing pinned it, for BOTH tiers (previously
  only the whiptail tier set it, so fzf-tier delegated screens ran with
  `TUI_BACKEND` unset). Companion: `_tui_fzf_run` now drives fzf via
  `${TUI_FZF_BIN:-fzf}`, a dedicated seam. gum is no longer a backend at all
  (ADR-0024; `_tui_backend_family` hardcodes `whiptail`,
  `lib/tui_backend.sh:1240`), so the "unknown flag" gum call cannot occur.
  System Info (`_tui_screen_system_info`, `:388-398`) forks `setup_ubuntu detect`
  and renders through `tui_render_msgbox`.
- Test: NONE drives the System Info screen. The #248 regression guard exercises a
  SIBLING delegated screen (Quick Setup):
  `test/integration/tui/tui_smoke_spec.bats`
  `@test "AC-10 smoke (fzf): main menu -> Quick Setup (delegated whiptail) ->
  back -> Exit"` (L142); its exp flow
  (`harness/smoke_flow_fzf.exp`) enters Quick Setup only and asserts
  `Form factor: desktop`. No exp flow enters `sysinfo`; `tui_render_fzf_spec.bats`
  STUBS `_tui_screen_system_info`, so the real screen is never invoked in tests.
- Verdict: FIXED-NOT-TESTED. Code fix is present and structurally sound for all
  delegated screens including System Info, but no test asserts System Info
  specifically renders without the gum error.

### Item 9 — Is environment auto-detected on TUI open / install?

- Decision: `environment_snapshot` / `lib/environment.sh`.
- Code: yes, at TUI open in both tiers. `setup_ubuntu_tui.sh:1193-1194` (fzf) and
  `:1297-1298` (whiptail) call `tui_broker_init` then `tui_broker_detect_json`.
  `tui_broker_init` (`lib/tui_backend.sh:504-510`) forks `tui_cli_detect_json` ->
  `setup_ubuntu detect --json` -> `_dispatcher_detect` -> `environment_snapshot`
  (`lib/environment.sh`).
- Test: `test/unit/tui_backend_spec.bats`
  `@test "tui_broker_init forks list + detect exactly once; accessors serve cache"`
  (L674): `run grep -c "detect --json" "${BROKER_COUNT}"` -> `assert_output "1"`.
  Golden equivalence: `test/unit/environment_spec.bats`
  `@test "GOLDEN: detect --json equals environment_snapshot() byte-for-byte"`
  (L453).
- Verdict: FIXED+TESTED. (Caveat: the test asserts the broker's fork directly;
  that `_tui_*_main_loop` calls the broker is exercised only by the integration
  smoke flows.)

### Item 10 — Review/Run: "font" should show WHICH pick selected it; deps per pick

- Decision: Review dependency provenance (PRD #214; commit #239).
- Code: `lib/tui_backend.sh:606-629` `tui_plan_provenance` attributes each plan
  node to `self` (a pick) or `req:<module>` (first requesting pick via transitive
  closure); rendered by `_tui_render_provenance` (`:634-645`) using i18n
  `prov_self` = "{0} (your selection)" / `prov_required_by` = "{0} (required by
  {1})". Consumed by `_tui_screen_review` (`setup_ubuntu_tui.sh:642`).
- Test: `test/unit/tui_review_provenance_spec.bats`
  `@test "e2e review: shows '(your selection)' and '(required by docker)'"`
  (L103): `assert_output --partial "docker (your selection)"`,
  `assert_output --partial "curl (required by docker)"` — a dep line names the
  pick that pulled it.
- Verdict: FIXED+TESTED.

### Item 11 — Every item has only a one-line blurb; want full detail + dependencies

- Decision: module detail view (#211), `show --json` (#236).
- Code: `lib/tui_backend.sh:1101-1112` `tui_detail_text` builds label:value lines
  (description, tags, depends_on, conflicts...) from forked `show --json`. fzf
  tier renders equivalent full detail live in the preview pane:
  `lib/tui_render_fzf.sh:412-470` `_tui_fzf_preview_module`.
- Test: `test/unit/tui_detail_spec.bats`
  `@test "tui_detail_text shows the full depends_on / conflicts / ubuntu /
  platforms labels"` (L167): `assert_output --partial "Depends on:"`; and
  `@test "tui_detail_text renders the #211 fields with arrays comma-joined"`
  (L154): `assert_output --partial "Docker Engine and CLI"` (full description) +
  `assert_output --partial "curl"` (depends_on). fzf-tier detail:
  `test/unit/tui_render_fzf_spec.bats`
  `@test "preview mod: full detail with status / recommended / deps / selection"`
  (L236): `assert_output --partial "Depends on: curl"`.
- Verdict: FIXED+TESTED.

---

## Round 2

### Item 12 — Quick Setup entry: show Ubuntu version + platform + arch + hardware (fastfetch-style)

- Decision: environment snapshot in Quick Setup.
- Code: `setup_ubuntu_tui.sh:802-812` `_tui_screen_quick_setup` Step 1/4 renders
  `tui_system_summary "${_detect_json}"` plus a form-factor line
  (`qs_step1_detected`, `qs_step1_form_factor`). BUT
  `tui_system_summary` (`lib/tui_backend.sh:1223-1232`) emits only os id+version,
  gpu model/vendor, desktop, session_type as ONE line
  (e.g. `Ubuntu 24.04 / NVIDIA RTX 4090 / GNOME / x11`). It does NOT include
  `arch`, `cpu.vendor`, or `board`, and is not a fastfetch-style multi-field table.
- Test: partial. `harness/smoke_flow_fzf.exp` asserts `Form factor: desktop`
  appears in Quick Setup (via `tui_smoke_spec.bats:142`), but NOT os version, NOT
  arch, NOT hardware. `test/unit/tui_backend_spec.bats`
  `@test "tui_system_summary renders the §8.1 one-line header"` (L989) asserts the
  output `"Ubuntu 24.04 / NVIDIA RTX 4090 / GNOME / x11"` in isolation — and
  confirms arch is absent.
- Verdict: PARTIAL. Quick Setup now shows a detected summary + form factor (more
  than the "yes, continue / override" the user saw), but the requested `arch` and
  fuller hardware breakdown are not implemented, and no test asserts os
  version/arch/hardware appear in the Quick Setup screen.

### Item 13 — Base module screen: one tool per line, full detail, kill "check view-details then Enter"; only shows apt-essentials

- Decision: ADR-0026 per-tool base modules + detail-on-separate-screen.
- Code: data model DONE — `module/apt-essentials.module.sh` does not exist;
  per-tool base modules (`git`/`vim`/`curl`/`wget`/`jq`/`htop`/`unzip`/
  `build-essential`) each `CATEGORY="base"` (headers note "Split out of the former
  apt-essentials bundle (ADR-0026)"). fzf tier DONE — `_tui_nav_leaf`
  (`setup_ubuntu_tui.sh:1043`) lists one row per module with detail in the preview
  pane (`--preview`, `:1032`; `--preview-window 'right,55%,wrap'`, `:1033`); no
  view-details row. HOWEVER the OLD "check view-details then Enter" pattern still
  ships in the whiptail Fallback tier: `setup_ubuntu_tui.sh:562-566` still appends
  `TUI_DETAIL_SENTINEL` ("檢視詳細資訊…") and `_tui_screen_category_leaf`
  (`:542-584`) opens `_tui_screen_detail_picker` on it — the exact UI in the
  user's screenshot, retained because "Neither backend can attach a per-row info
  key inside a checklist."
- Test: split — `test/unit/module/git_spec.bats`
  `@test "git module CATEGORY=base"` (L97). Migration —
  `test/unit/state_migrate_spec.bats`
  `@test "migration drops the apt-essentials bundle entry"` (L122) and
  `@test "migration adds git/vim/curl/wget/jq as manual installed entries"`
  (L130). One-per-line — `tui_render_fzf_spec.bats` L170 (above). Preview detail —
  `tui_render_fzf_spec.bats` L236 (above). NO test asserts the whiptail
  `TUI_DETAIL_SENTINEL` view-details row was removed (it was not).
- Verdict: PARTIAL. Data split + fzf two-pane one-per-line + preview-pane detail
  are FIXED+TESTED; the "check view-details then Enter" UX the user complained
  about is gone only in the Rich tier and still ships in the whiptail Fallback
  tier (the tier in the user's screenshot), by documented backend limitation.

### Item 14 — Recommended still shows (0/7) [repeat]; and should be PRE-SELECTED by default

- Decision: ADR-0024 D2 (counts) + D4 (recommended preselect).
- Code: (a) count — same as Item 3. (b) preselect — shared producer
  `lib/tui_backend.sh:753` `tui_recommended_preselect_modules`; fzf write
  `lib/tui_render_fzf.sh:207` `tui_fzf_recommended_preselect`, first-entry guarded
  at `setup_ubuntu_tui.sh:1064-1067`; whiptail seed `_tui_preselect_recommended`
  (`:489`), fired at `:508-510`.
- Test: (a) `tui_render_fzf_spec.bats` L213 (above). (b) fzf write:
  `test/unit/tui_render_fzf_spec.bats`
  `@test "recommended preselect: only is_recommended modules surviving the
  platform filter"` (L295): after `tui_fzf_recommended_preselect ... desktop`,
  `assert_line "docker"`, `assert_line "font"`, `refute_line "neovim"`. Cross-tier
  parity: `test/unit/tui_whiptail_tier_spec.bats`
  `@test "...matches the fzf preselect set (D4 parity)"` (L121).
- Verdict: FIXED+TESTED. Minor gap: the whiptail wrapper
  `_tui_preselect_recommended` (which seeds `TUI_SELECTION`) and the
  `TUI_RECO_PRESELECTED` first-entry guard have no direct unit test — covered only
  transitively via the shared producer + parity test.

### Item 15 — Main menu shows Chinese "基礎工具" but the screen shows English "base 模組"; align i18n

- Decision: verify the category label is i18n-consistent between menu and screen.
- Code: NOT aligned. The main-menu row uses the translated label
  `cat_base_label` = "基礎工具" (`lib/tui_backend.sh:1147`). But the category
  screen TITLE uses `cat_modules_title` with the RAW category token:
  `setup_ubuntu_tui.sh:529` and `:570`
  `"$(i18n_t TUI_I18N cat_modules_title "${_cat^}")"`, where
  `cat_modules_title` (zh) = "{0} 模組" and `${_cat^}` = "Base". Result in zh-TW:
  "Base 模組" — exactly the mismatched string the user reported. The fzf tier
  headers are the same: `nav_header_branch "${_cat}"` / `nav_header_modules
  "${_subtag}"` (`setup_ubuntu_tui.sh:1078`, `:1049`) interpolate the raw English
  category/bucket token. There is no category-token -> translated-label mapping
  used for screen titles.
- Test: `test/unit/tui_backend_spec.bats`
  `@test "i18n: main-menu rows render zh-TW ... (#185)"` (L1015) asserts only the
  MAIN-MENU row translates (`assert_line --partial "基礎工具"`). No test asserts
  the category SCREEN title matches the menu label.
- Verdict: NOT-FIXED. The specific alignment the user asked for is absent; the
  screen title still renders the raw English category token ("Base 模組").

### Item 16 — Optional: main -> optional -> category list -> items; Chinese category labels; explicit "1/3 2/3" page indicator (not "..."); two-pane (selection + detail)

- Decision: ADR-0024 two-pane navigator + nested drill-down (#258).
- Code:
  - Two-pane + drill-down: DONE. `_tui_nav_category` (`setup_ubuntu_tui.sh:1062`)
    emits `sub:` branch rows when >1 bucket; leaf via `_tui_nav_leaf` (`:1043`)
    with a live preview pane (`--preview`, `--preview-window`).
  - Chinese category (sub-category bucket) labels: NOT DONE. Buckets come from
    `TAGS[0]` and are shown RAW: fzf `tui_fzf_cat_rows`
    (`lib/tui_render_fzf.sh:271`) prints `... ${_sub} ...` (e.g. "agent",
    "cli-essentials"); whiptail `subcat_row` = "{0}  ({1}/{2})" with {0} = raw
    `${_sub}` (`setup_ubuntu_tui.sh:96-97`, `:524`). No translation table for
    bucket names.
  - Explicit "1/3 2/3" page indicator: NOT DONE. There is no page indicator
    anywhere; the fzf navigator uses fzf's native scroll + match counter (no page
    concept), and the whiptail menu scrolls natively. `grep` finds no
    page-indicator code in either tier.
- Test: two-pane / drill-down covered — `test/unit/tui_render_fzf_spec.bats`
  `@test "cat_rows: a multi-bucket category yields sub: branch rows with counts"`
  (L162), `@test "preview cat: branch summary lists children with counts"` (L254),
  `@test "preview sub: bucket summary lists its modules with glyphs"` (L263). NO
  test for a "1/3" page indicator; NO test for Chinese sub-category labels (the
  "(1/3)" strings in tests are SELECTED/total counts, not page indicators).
- Verdict: PARTIAL. Two-pane navigator + category drill-down are FIXED+TESTED, but
  the two specific asks — translatable (Chinese) sub-category labels and the
  explicit "1/3 2/3" page indicator — are NOT implemented.

### Item 17 — Manage Secrets: token/gpg show no keys; must split into THREE sub-menus (token/gpg/ssh)

- Decision: secrets 3 sub-menus phase 3 (#258); empty-list "none" render.
- Code: `lib/tui_secrets.sh:312-334` `_tui_screen_secrets` is a three-way
  Token/GPG/SSH picker dispatching each kind to its own sub-screen
  (`_tui_screen_secrets_token` `:232`, `_gpg` `:256`, `_ssh` `:279`). Empty list
  renders localized "none" for all three kinds via `_tui_secrets_kind_list`
  (`:211-223`, `i18n_t TUI_I18N secrets_none` at `:219`).
- Test: `test/unit/tui_secrets_menu_spec.bats`
  `@test "secrets picker: the three kinds dispatch through the screen registry"`
  (L155): `assert_line --partial "[secrets-token]=_tui_screen_secrets_token"`
  (and gpg, ssh). Empty render — `test/unit/tui_secrets_e2e_spec.bats`
  `@test "in-proc kind-list: empty token list renders the localized 'none'"`
  (L375): `assert_output "secrets_none"`; and `@test "...empty ssh list renders
  'none' (awk path, lib 200)"` (L381).
- Verdict: FIXED+TESTED. Minor gap: no gpg-specific empty-list assertion (the
  gpg empty path uses the same shared function tested for token + ssh).

### Item 18 — System Info: full hardware (fastfetch-like); 1-3s wait normal?; override doesn't show OLD detected value; Run screen "由 ? 連帶安裝"

Four sub-points; audited separately.

- 18a Full hardware / fastfetch-like: `_tui_screen_system_info`
  (`setup_ubuntu_tui.sh:391`) forks `setup_ubuntu detect` (text), whose table
  includes `arch`, `cpu.vendor`, `gpu.vendor`, `gpu.model`, `board`,
  `form_factor`, virt/wsl. So hardware fields ARE shown, but it is the raw
  `detect` table, not a fuller fastfetch-style breakdown (no CPU model, RAM, or
  disk). PARTIAL; and no test drives this screen.
  - Tooling note (issue #325): the reference system-info tool is now
    `fastfetch` (the archived neofetch is retired). The planned tmux status-bar
    system-info popup should bind to `fastfetch`, not neofetch, once implemented.
- 18b 1-3s wait: NOT eliminated. System Info re-forks `setup_ubuntu detect`
  fresh on every entry (`:391`) — running the full probe (lspci /
  systemd-detect-virt) again — instead of reusing the cached
  `tui_broker_detect_json` snapshot the TUI already forked at open
  (`:1193-1194` / `:1297-1298`). The broker cache holds JSON; System Info wants
  text and re-probes. NOT-FIXED; untested.
- 18c Override does not show the OLD/detected value: the override prompt text
  `override_question` (`setup_ubuntu_tui.sh:77-78`) = "是否在本工作階段覆寫偵測到
  的平台 (硬體型態)?" does NOT name the detected `form_factor`, and neither does
  the form-factor selection menu (`select_form_factor`, `:81-82`).
  `sysinfo_override_line` (`:73-74`) only shows a value when an override is
  ALREADY set (it shows the override, not the detected value). The detected
  form_factor is visible only in the detect table one msgbox earlier, never
  restated in the override dialog. NOT-FIXED (as specifically asked); untested.
- 18d Run screen "由 ? 連帶安裝" — the "?": this is the dependency-provenance
  feature (Item 10). `tui_plan_provenance` (`lib/tui_backend.sh:622-625`) now
  attributes each dep to its requesting pick ("required by docker"); the "?" is
  the `// "?"` fallback used only when a node is genuinely unattributable, and the
  former `apt-essentials` bundle that produced the screenshot's "?" no longer
  exists (ADR-0026). RESOLVED via Item 10 (FIXED+TESTED in the normal case).
- Verdict: PARTIAL. The "?" is resolved and hardware fields are shown, but the
  1-3s wait (18b) and the override-shows-old-value ask (18c) are NOT-FIXED, and
  no test covers the System Info screen, the wait, or the override value.

---

## Summary table

| Item | Topic | Verdict |
|------|-------|---------|
| 1  | Quick Setup pre-install show-all | FIXED+TESTED |
| 2  | Base tools itemized per-tool | FIXED+TESTED |
| 3  | Recommended count reflects selection | FIXED+TESTED |
| 4  | Recommended sub-categories + basic-first | FIXED+TESTED |
| 5  | Optional sub-categories + basic-first | FIXED+TESTED |
| 6  | Main-menu separator skip + jump-back | FIXED+TESTED |
| 7  | Manage Installed "unknown" detail | FIXED+TESTED |
| 8  | System Info gum-error (#248) | FIXED-NOT-TESTED |
| 9  | Environment auto-detected on TUI open | FIXED+TESTED |
| 10 | Review dependency provenance | FIXED+TESTED |
| 11 | Full detail + dependencies per item | FIXED+TESTED |
| 12 | Quick Setup fastfetch-style env | PARTIAL |
| 13 | apt-essentials split + one-per-line + detail UX | PARTIAL |
| 14 | Recommended count repeat + D4 preselect | FIXED+TESTED |
| 15 | i18n label alignment (基礎工具 vs Base 模組) | NOT-FIXED |
| 16 | Optional nav: two-pane + Chinese labels + 1/3 indicator | PARTIAL |
| 17 | Secrets three sub-menus + "none" | FIXED+TESTED |
| 18 | System Info hardware / wait / override-old / "?" | PARTIAL |

Counts:

- FIXED+TESTED: 12 (items 1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 14, 17)
- FIXED-NOT-TESTED: 1 (item 8)
- PARTIAL: 4 (items 12, 13, 16, 18)
- NOT-FIXED: 1 (item 15)

Total: 18.

## FIXED-NOT-TESTED (need a test)

- Item 8 — System Info gum-error fix. The `TUI_BACKEND=whiptail` default
  (`setup_ubuntu_tui.sh:1497-1508`) fixes it, and gum is dropped entirely, but no
  test drives `_tui_screen_system_info`; the only #248 regression flow enters
  Quick Setup. Add an exp flow (or in-proc test) that enters `sysinfo` and asserts
  the env table renders with no gum error.

## PARTIAL / NOT-FIXED (need work or a grill)

- Item 12 (PARTIAL) — Quick Setup shows os/gpu/desktop/session + form_factor but
  NOT `arch` or fuller hardware; no test asserts the fields in the QS screen.
- Item 13 (PARTIAL) — the "check view-details then Enter" UX the user complained
  about persists in the whiptail Fallback tier (`TUI_DETAIL_SENTINEL`,
  `setup_ubuntu_tui.sh:562-566`); fixed only in the Rich (fzf) tier.
- Item 15 (NOT-FIXED) — the category screen title is `cat_modules_title
  "${_cat^}"` = "Base 模組" (raw English token), not the translated menu label
  "基礎工具". No screen-title/menu-label alignment; no test.
- Item 16 (PARTIAL) — two-pane + drill-down done, but (i) sub-category bucket
  labels are shown raw (agent/cli-essentials), NOT translated to Chinese, and
  (ii) the explicit "1/3 2/3" page indicator is not implemented anywhere (fzf uses
  native scroll).
- Item 18 (PARTIAL) — the 1-3s wait is NOT eliminated (System Info re-forks
  `detect` instead of reusing the cached broker snapshot); the override prompt
  does NOT restate the OLD detected form_factor; neither is tested.

## Open questions

1. Item 13 / Item 16 / whiptail parity: several complaints (view-details flow,
   Chinese sub-category labels, page indicator) are fixed only in the Rich (fzf)
   tier or not at all, while the user's screenshots are the whiptail Fallback
   tier. Is Fallback-tier parity a v0.1.0 acceptance requirement, or is "Rich tier
   satisfies it" the accepted answer given ADR-0024's stated tier asymmetry?
2. Item 15: is category-token -> translated-label a deliberate deferral (file
   names / labels deferred to 0.2.0), or a genuine miss? It is a one-line i18n
   lookup and the user explicitly flagged it.
3. Item 18b: should System Info reuse `tui_broker_detect_json` (render the text
   table from the cached JSON) to remove the re-probe wait, or is re-detection on
   the System Info screen intentional (fresh reading)?
4. Item 18c / Item 12: is a fuller fastfetch-style hardware panel (CPU model, RAM,
   disk) in scope for 0.1.0, or is the current `detect` field set the accepted
   surface? The override-shows-old-value ask (18c) is small (interpolate the
   detected form_factor into `override_question`).
