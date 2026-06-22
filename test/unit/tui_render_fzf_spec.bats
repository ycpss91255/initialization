#!/usr/bin/env bats
# test/unit/tui_render_fzf_spec.bats — fzf Rich tier (ADR-0024, issue #242)
#
# Covers the PURE data + render layer of lib/tui_render_fzf.sh (the parts that
# do not need an interactive fzf — the live navigator is covered by the AC-10
# smoke harness in a follow-up). Specifically:
#   - the --preview token renderer for all FOUR token kinds (menu / cat / sub
#     / mod), incl. a module's full detail and a branch's children + counts;
#   - main-menu category rows showing SELECTED/total (PRD D2), NOT
#     installed/total;
#   - the selection-state file accessors (add/remove/toggle/has/count/list);
#   - is_recommended pre-selection with the §15.3 platform filter (PRD D4);
#   - the sub-category structure (TAGS[0] buckets → branch vs straight-leaf);
#   - the navigator's pure row producers (menu/cat/sub rows);
#   - tier resolution + `--backend fzf|whiptail` parsing (entrypoint).
#
# HOST-SAFETY: pure functions over JSON + a tmp selstate file; the few e2e
# cases fork a recorded mock CLI only. No real fzf/whiptail, no host writes
# outside $BATS_TEST_TMPDIR.

load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/tui_harness.bash"

# shellcheck source=../../lib/tui_render_fzf.sh
source "${LIB_DIR}/tui_render_fzf.sh"

# Source the entrypoint (#6 screen registry + dispatcher live there). Its main()
# is guarded to run only when executed directly, so sourcing only defines
# functions + the TUI_SCREEN_REGISTRY. Done at file scope so the recorder
# overrides below shadow the real (TUI-drawing) leaf screens cleanly (no
# per-test function redefinition → no SC2317), exactly like the _tui_has_cmd
# override pattern. NB: deliberately NO `# shellcheck source=` directive —
# following the entrypoint inline makes shellcheck treat its trailing `exit` as
# ending THIS file and flag the rest of the spec as unreachable (SC2317). The
# source is runtime-only; SC1090/SC1091 do not fire for an unfollowed source.
source "${REPO_ROOT}/setup_ubuntu_tui.sh"

# Mockable command probe (same seam as tui_backend_spec.bats): report only the
# names in MOCK_AVAILABLE_CMDS as present, so tier-availability tests need no
# per-test function redefinition (which would trip SC2317).
# MOCK_AVAILABLE_CMDS  space-separated command names reported as present
_tui_has_cmd() {
    case " ${MOCK_AVAILABLE_CMDS:-} " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# Recorder overrides for the #6 registry leaf screens: each prints its name (and
# the list_json it was handed) so a test can assert WHICH handler the dispatcher
# invoked, without drawing a real TUI screen. Defined at file scope AFTER the
# entrypoint source, so they shadow the real _tui_screen_* (reachable via the
# registry → no SC2317). The registry already maps manage/secrets/sysinfo/help
# to these names, so no array mutation is needed.
_tui_screen_manage()      { printf 'manage:%s\n' "${1:-}"; }
_tui_screen_secrets()     { printf 'secrets\n'; }
_tui_screen_system_info() { printf 'sysinfo\n'; }
_tui_screen_help()        { printf 'help\n'; }

# Re-point a registry entry from a test (the array is defined by the sourced
# entrypoint). Isolating the write here keeps the @test bodies free of the
# bare-subscript lint that fires when the array is treated as external; the
# subscript is a variable, not a bare word.
#   _set_registry_entry <token> <handler-fn>
_set_registry_entry() {
    local _tok="$1" _fn="$2"
    TUI_SCREEN_REGISTRY["${_tok}"]="${_fn}"
}

setup() {
    setup_test_env
    export LC_ALL=C.UTF-8
    export INIT_UBUNTU_LANG=en
    SELSTATE="$(mktemp "${BATS_TEST_TMPDIR}/sel.XXXXXX")"
}

teardown() {
    teardown_test_env
}

# ── Fixture: base (1 tag), recommended (2 tags), optional (2 tags) ───────────
# recommended: docker (container, rec, desktop+server) / neovim (editor, !rec,
#   depends_on fzf) → two TAGS[0] buckets → a sub-category branch.
# base: curl only (http) → single bucket → straight to the leaf.
# optional: eza (cli-essentials) / claude-code (agent) → two buckets.
FZF_JSON="$(cat <<'EOF'
{
  "schema_version": "1",
  "items": [
    {"name": "curl", "category": "base", "tags": ["http"],
     "description": "HTTP client", "installed": true, "recommended": false,
     "depends_on": [], "supported_platforms": ["desktop", "server", "wsl"]},
    {"name": "docker", "category": "recommended", "tags": ["container"],
     "description": "Docker Engine", "installed": false, "recommended": true,
     "depends_on": ["curl"], "supported_platforms": ["desktop", "server"]},
    {"name": "neovim", "category": "recommended", "tags": ["editor"],
     "description": "Neovim editor", "installed": false, "recommended": false,
     "depends_on": ["fzf"], "supported_platforms": ["desktop", "server"]},
    {"name": "font", "category": "recommended", "tags": ["font"],
     "description": "Nerd fonts", "installed": false, "recommended": true,
     "depends_on": [], "supported_platforms": ["desktop"]},
    {"name": "eza", "category": "optional", "tags": ["cli-essentials"],
     "description": "ls alternative", "installed": false, "recommended": false,
     "depends_on": null, "supported_platforms": ["desktop", "server", "wsl"]},
    {"name": "claude-code", "category": "optional", "tags": ["agent"],
     "description": "Anthropic agent CLI", "installed": false, "recommended": false,
     "depends_on": null, "supported_platforms": ["desktop", "server", "wsl"]}
  ]
}
EOF
)"

# ── Selection-state file accessors ───────────────────────────────────────────

@test "sel: empty file → count 0, has false, list empty" {
    run tui_fzf_sel_count "${SELSTATE}"
    assert_output "0"
    run tui_fzf_sel_has "${SELSTATE}" docker
    assert_failure
    run tui_fzf_sel_list "${SELSTATE}"
    assert_output ""
}

@test "sel: add is idempotent; has + count reflect it" {
    tui_fzf_sel_add "${SELSTATE}" docker
    tui_fzf_sel_add "${SELSTATE}" docker
    run tui_fzf_sel_count "${SELSTATE}"
    assert_output "1"
    run tui_fzf_sel_has "${SELSTATE}" docker
    assert_success
}

@test "sel: remove drops the name (idempotent on absent)" {
    tui_fzf_sel_add "${SELSTATE}" docker
    tui_fzf_sel_add "${SELSTATE}" eza
    tui_fzf_sel_remove "${SELSTATE}" docker
    tui_fzf_sel_remove "${SELSTATE}" not-there
    run tui_fzf_sel_list "${SELSTATE}"
    assert_output "eza"
}

@test "sel: toggle flips membership both ways" {
    tui_fzf_sel_toggle "${SELSTATE}" docker
    run tui_fzf_sel_has "${SELSTATE}" docker
    assert_success
    tui_fzf_sel_toggle "${SELSTATE}" docker
    run tui_fzf_sel_has "${SELSTATE}" docker
    assert_failure
}

# ── Sub-category structure (TAGS[0] buckets) ─────────────────────────────────

@test "subtags: recommended has two buckets, base one" {
    run tui_fzf_subtags "${FZF_JSON}" recommended
    assert_line "container"
    assert_line "editor"
    assert_line "font"
    run tui_fzf_subtag_count "${FZF_JSON}" base
    assert_output "1"
}

@test "cat_rows: a multi-bucket category yields sub: branch rows with counts" {
    run tui_fzf_cat_rows "${FZF_JSON}" recommended "${SELSTATE}"
    assert_output --partial "sub:recommended:container"
    assert_output --partial "sub:recommended:editor"
    # No module rows at this level (it is a branch screen).
    refute_output --partial "mod:docker"
}

@test "cat_rows: a single-bucket category goes straight to mod: leaf rows" {
    run tui_fzf_cat_rows "${FZF_JSON}" base "${SELSTATE}"
    assert_output --partial "mod:curl"
    refute_output --partial "sub:base"
}

@test "sub_rows: module leaf rows carry glyph, ★ and (+N) markers" {
    tui_fzf_sel_toggle "${SELSTATE}" docker
    run tui_fzf_sub_rows "${FZF_JSON}" recommended container "${SELSTATE}"
    # docker is selected (●), recommended (★), pulls 1 dep (+1).
    assert_output --partial "mod:docker"
    assert_output --partial "● docker"
    assert_output --partial "★"
    assert_output --partial "(+1)"
}

@test "sub_rows: an unselected module shows the ○ glyph" {
    run tui_fzf_sub_rows "${FZF_JSON}" recommended editor "${SELSTATE}"
    assert_output --partial "○ neovim"
}

@test "mod_label: a null description renders blank, not the literal 'null'" {
    # ADR-0019 promises description as a string, but a malformed/forked payload
    # can carry description=null. jq string interpolation of null prints the
    # literal word "null" — the label must fall back to "" (matches the
    # preview renderer's `// $none` guard) so the row never shows "name  null".
    local _json='{"items":[{"name":"docker","description":null,"recommended":false,"depends_on":[]}]}'
    run _tui_fzf_mod_label "${_json}" docker "${SELSTATE}"
    assert_success
    refute_output --partial "null"
    assert_output "○ docker  "
}

# ── Main-menu rows: SELECTED/total per category (PRD D2) ──────────────────────

@test "menu_rows: category rows show SELECTED/total, not installed/total" {
    # curl (base) is INSTALLED but NOT selected → base must read (0/1), proving
    # the count is selection-based (PRD D2), not install-based.
    run tui_fzf_menu_rows "${FZF_JSON}" "${SELSTATE}"
    assert_output --partial "menu:base"
    assert_line --partial "Base Tools (0/1)"
}

@test "menu_rows: selecting a module bumps that category's SELECTED count" {
    tui_fzf_sel_toggle "${SELSTATE}" docker
    run tui_fzf_menu_rows "${FZF_JSON}" "${SELSTATE}"
    # recommended has 3 modules; docker selected → (1/3).
    assert_output --partial "Recommended (1/3)"
}

@test "menu_rows: the run row carries the live selection count" {
    tui_fzf_sel_toggle "${SELSTATE}" docker
    tui_fzf_sel_toggle "${SELSTATE}" eza
    run tui_fzf_menu_rows "${FZF_JSON}" "${SELSTATE}"
    assert_output --partial "menu:run"
    assert_output --partial "Install selected (2)"
}

@test "category_sel_stats: '<selected> <total>' for a category" {
    tui_fzf_sel_toggle "${SELSTATE}" docker
    run tui_fzf_category_sel_stats "${FZF_JSON}" recommended "${SELSTATE}"
    assert_output "1 3"
}

# ── The --preview renderer: four token kinds ─────────────────────────────────

@test "preview mod: full detail with status / recommended / deps / selection" {
    tui_fzf_sel_toggle "${SELSTATE}" docker
    run tui_fzf_preview "mod:docker" "${FZF_JSON}" "${SELSTATE}"
    assert_output --partial "docker"
    assert_output --partial "Docker Engine"
    assert_output --partial "not installed"
    assert_output --partial "recommended for this platform"
    assert_output --partial "SELECTED"
    assert_output --partial "Depends on: curl"
    assert_output --partial "Will pull 1 dependency"
}

@test "preview mod: a module with no deps says 'No additional dependency'" {
    run tui_fzf_preview "mod:eza" "${FZF_JSON}" "${SELSTATE}"
    assert_output --partial "No additional dependency"
    assert_output --partial "not selected"
}

@test "preview cat: branch summary lists children with counts" {
    tui_fzf_sel_toggle "${SELSTATE}" docker
    run tui_fzf_preview "cat:recommended" "${FZF_JSON}" "${SELSTATE}"
    # Header counts the whole category (1 of 3 selected).
    assert_output --partial "3 item(s), 1 selected"
    assert_output --partial "container"
    assert_output --partial "editor"
}

@test "preview sub: bucket summary lists its modules with glyphs" {
    run tui_fzf_preview "sub:recommended:editor" "${FZF_JSON}" "${SELSTATE}"
    assert_output --partial "1 module(s), 0 selected"
    assert_output --partial "○ neovim"
}

@test "preview menu: a category id previews its children" {
    run tui_fzf_preview "menu:recommended" "${FZF_JSON}" "${SELSTATE}"
    assert_output --partial "item(s)"
    assert_output --partial "container"
}

@test "preview menu: sysinfo / secrets / manage / run get summaries" {
    run tui_fzf_preview "menu:sysinfo" "${FZF_JSON}" "${SELSTATE}"
    assert_output --partial "Environment detection"
    run tui_fzf_preview "menu:secrets" "${FZF_JSON}" "${SELSTATE}"
    assert_output --partial "Token / GPG / SSH"
    # manage: 1 module installed (curl) in the fixture.
    run tui_fzf_preview "menu:manage" "${FZF_JSON}" "${SELSTATE}"
    assert_output --partial "1 installed"
    tui_fzf_sel_toggle "${SELSTATE}" docker
    run tui_fzf_preview "menu:run" "${FZF_JSON}" "${SELSTATE}"
    assert_output --partial "1 module(s)"
}

@test "preview: an unknown token echoes itself (no crash)" {
    run tui_fzf_preview "garbage" "${FZF_JSON}" "${SELSTATE}"
    assert_output "garbage"
}

# ── is_recommended pre-selection (PRD D4 + §15.3 platform filter) ─────────────

@test "recommended preselect: only is_recommended modules surviving the platform filter" {
    # desktop: docker (rec, desktop+server) + font (rec, desktop) survive;
    # neovim is NOT recommended → excluded.
    tui_fzf_recommended_preselect "${FZF_JSON}" "${SELSTATE}" desktop
    run tui_fzf_sel_list "${SELSTATE}"
    assert_line "docker"
    assert_line "font"
    refute_line "neovim"
}

@test "recommended preselect: a platform-gated module drops off another platform" {
    # server: font (desktop only) is filtered OUT; docker stays.
    tui_fzf_recommended_preselect "${FZF_JSON}" "${SELSTATE}" server
    run tui_fzf_sel_list "${SELSTATE}"
    assert_line "docker"
    refute_line "font"
}

# ── Tier availability probe ──────────────────────────────────────────────────

@test "tui_fzf_available: rc follows _tui_has_cmd fzf" {
    MOCK_AVAILABLE_CMDS="fzf whiptail" run tui_fzf_available
    assert_success
    MOCK_AVAILABLE_CMDS="whiptail" run tui_fzf_available
    assert_failure
}

# ── --preview / --toggle re-invocation modes (entrypoint, ADR-0024) ──────────
# fzf re-invokes the script as `--preview <token>` / `--toggle <name>`; both
# short-circuit the launch path (no sudo gate, no tier resolution).

_make_preview_cli() {
    PREVIEW_DIR="${BATS_TEST_TMPDIR}/preview"
    mkdir -p "${PREVIEW_DIR}"
    printf '%s\n' "${FZF_JSON}" >"${PREVIEW_DIR}/list.json"
    cat >"${PREVIEW_DIR}/setup_ubuntu" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "list --json") cat "${PREVIEW_DIR}/list.json" ;;
esac
EOF
    chmod +x "${PREVIEW_DIR}/setup_ubuntu"
}

@test "entrypoint --preview forks list --json and renders the token" {
    _make_preview_cli
    run env "TUI_CLI=${PREVIEW_DIR}/setup_ubuntu" \
        "${REPO_ROOT}/setup_ubuntu_tui.sh" --preview mod:docker "${SELSTATE}"
    assert_success
    assert_output --partial "Docker Engine"
}

@test "entrypoint --preview reads the broker cache instead of forking the CLI" {
    # Perf (#7): the broker caches list --json to a file and exports its path
    # (TUI_BROKER_LIST_CACHE), so the preview re-invocation does NOT re-fork the
    # CLI per cursor move. Prove it by pointing TUI_CLI at a mock that FAILS on
    # list --json: the preview must still render, which is only possible if it
    # read the cache file.
    _make_preview_cli
    local _cache="${BATS_TEST_TMPDIR}/list-cache.json"
    cp "${PREVIEW_DIR}/list.json" "${_cache}"
    cat >"${PREVIEW_DIR}/setup_ubuntu_fail" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
    chmod +x "${PREVIEW_DIR}/setup_ubuntu_fail"
    run env "TUI_CLI=${PREVIEW_DIR}/setup_ubuntu_fail" "TUI_BROKER_LIST_CACHE=${_cache}" \
        "${REPO_ROOT}/setup_ubuntu_tui.sh" --preview mod:docker "${SELSTATE}"
    assert_success
    assert_output --partial "Docker Engine"
}

@test "entrypoint --toggle strips the mod: token and mutates the selstate live" {
    # fzf's space bind passes the row TOKEN ({1} = mod:<name>), so --toggle
    # must strip the prefix to the bare module name (not store "mod:docker").
    _make_preview_cli
    run env "TUI_CLI=${PREVIEW_DIR}/setup_ubuntu" \
        "${REPO_ROOT}/setup_ubuntu_tui.sh" --toggle mod:docker "${SELSTATE}"
    assert_success
    run cat "${SELSTATE}"
    assert_output "docker"
    # Toggling again clears it.
    run env "TUI_CLI=${PREVIEW_DIR}/setup_ubuntu" \
        "${REPO_ROOT}/setup_ubuntu_tui.sh" --toggle mod:docker "${SELSTATE}"
    run cat "${SELSTATE}"
    assert_output ""
}

@test "entrypoint --toggle ignores a non-mod token (branch rows are not togglable)" {
    _make_preview_cli
    run env "TUI_CLI=${PREVIEW_DIR}/setup_ubuntu" \
        "${REPO_ROOT}/setup_ubuntu_tui.sh" --toggle sub:recommended:editor "${SELSTATE}"
    assert_success
    run cat "${SELSTATE}"
    assert_output ""
}

# ── --backend tier parsing (ADR-0024) ────────────────────────────────────────

@test "--backend fzf|whiptail are accepted; an unknown tier is rejected with exit 2" {
    # fzf selects the Rich tier; whiptail selects the Fallback dialog tier.
    # gum is no longer a backend (ADR-0024). An unknown value is a usage error.
    run "${REPO_ROOT}/setup_ubuntu_tui.sh" --backend dialog
    assert_failure 2
    assert_output --partial "fzf|whiptail"
}

# ── Screen registry dispatch (#6, single token->screen source of truth) ──────
# The registry + _tui_invoke_screen replace the duplicated token->screen `case`
# arms across the three dispatch sites (fzf _tui_nav_main, whiptail
# _tui_main_loop's _tui_dispatch, and _tui_dispatch). The entrypoint is sourced
# at file scope and the leaf screens are shadowed by recorder stubs (above), so
# dispatch is verified without launching the real (TUI-drawing) screens.

@test "registry: a menu: token resolves to the right handler (strips menu:)" {
    run _tui_invoke_screen "menu:manage" '{"items":[]}'
    assert_success
    assert_output 'manage:{"items":[]}'

    run _tui_invoke_screen "menu:secrets" '{"items":[]}'
    assert_output "secrets"
    run _tui_invoke_screen "menu:sysinfo" '{"items":[]}'
    assert_output "sysinfo"
    run _tui_invoke_screen "menu:help" '{"items":[]}'
    assert_output "help"
}

@test "registry: a bare tag (no menu: prefix) resolves identically" {
    # The whiptail tier passes bare tags ('manage'); the fzf tier 'menu:manage'.
    run _tui_invoke_screen "manage" '{"items":[]}'
    assert_success
    assert_output --partial "manage:"
}

@test "registry: an unknown token is a safe no-op (rc 0, no output)" {
    # Category / run / quick-setup tokens are handled by the caller, NOT the
    # registry — _tui_invoke_screen must ignore them without crashing.
    run _tui_invoke_screen "menu:run" '{"items":[]}'
    assert_success
    assert_output ""
    run _tui_invoke_screen "menu:base" '{"items":[]}'
    assert_success
    assert_output ""
    run _tui_invoke_screen "totally-unknown" '{"items":[]}'
    assert_success
    assert_output ""
}

@test "registry: a registered token with a missing handler fn errors (rc 1)" {
    # Register a token whose handler function does NOT exist — the dispatcher
    # must surface a clear error (rc 1), not silently swallow a
    # registered-but-undefined screen. _set_registry_entry isolates the array
    # write in a helper so the @test body stays lint-clean.
    _set_registry_entry manage _tui_no_such_handler
    run _tui_invoke_screen "menu:manage" '{"items":[]}'
    assert_failure
    assert_output --partial "missing"
}

@test "registry: _tui_dispatch routes leaf tokens through the registry" {
    # _tui_dispatch (whiptail tier) handles quick-setup/category/run itself and
    # delegates the rest to the registry dispatcher.
    run _tui_dispatch secrets '{"items":[]}' '{}'
    assert_success
    assert_output "secrets"
}
