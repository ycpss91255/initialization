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

@test "--backend fzf|whiptail|gum are accepted; an unknown tier is rejected with exit 2" {
    # fzf selects the Rich tier; whiptail and gum select the legacy dialog loop
    # (gum stays accepted until the phase-6 gum removal — the AC-10/AC-11
    # dual-backend smoke still drives it). An unknown value is a usage error.
    run "${REPO_ROOT}/setup_ubuntu_tui.sh" --backend dialog
    assert_failure 2
    assert_output --partial "fzf|whiptail|gum"
}
