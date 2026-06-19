#!/usr/bin/env bats
# test/unit/tui_backend_spec.bats — lib/tui_backend.sh + setup_ubuntu_tui.sh
#
# Issue #69 (PRD §8.1 / §8.5, G4): TUI skeleton.
#   - Backend detection: prefer `dialog`, fall back to `whiptail`; both
#     missing → fatal with the §8.5 fix guidance (no auto-install).
#   - No sudo → exit 4 suggesting CLI mode.
#   - Menu data parsing: exclusively from `setup_ubuntu list --json` /
#     `detect --json` (ADR-0019 schema). Empty CATEGORYs are hidden (Q44).
#   - G4 grep gate: setup_ubuntu_tui.sh never sources engine libs.
#
# HOST-SAFETY: command probes (`_tui_has_cmd`, `_tui_has_sudo`) are
# overridden below with parameterized mocks — no real dialog/whiptail/sudo
# is touched. Menu parsing eats inline ADR-0019 fixtures, never live state.

load "${BATS_TEST_DIRNAME}/../helper/common"
# Shared TUI fixtures + scripted-widget e2e harness (also used by the AC-10
# layer-1 suite in tui_ac10_spec.bats and the layer-2 integration smoke).
load "${BATS_TEST_DIRNAME}/../helper/tui_harness"

# Source the library at file level, THEN shadow its probes. bats
# re-evaluates the whole file per test, so every test gets fresh copies.
# shellcheck source=../../lib/tui_backend.sh
source "${LIB_DIR}/tui_backend.sh"

# ── Parameterized probe mocks ────────────────────────────────────────────────
# MOCK_AVAILABLE_CMDS  space-separated command names reported as present
# MOCK_HAS_SUDO        true|false

_tui_has_cmd() {
    # gum may "appear" only after the install fork drops its marker file
    # (the prelaunch re-detect path) — gated by MOCK_GUM_MARKER so the
    # before/after states are data-driven, no in-test function redefinition.
    if [[ "${1}" == "gum" && -n "${MOCK_GUM_MARKER:-}" && -f "${MOCK_GUM_MARKER}" ]]; then
        return 0
    fi
    case " ${MOCK_AVAILABLE_CMDS:-} " in
        *" ${1} "*) return 0 ;;
    esac
    return 1
}

_tui_has_sudo() {
    [[ "${MOCK_HAS_SUDO:-true}" == "true" ]]
}

# Mockable interactivity gate for _tui_prelaunch_backend (MOCK_STDIN_TTY=
# true|false), same data-driven pattern as the command/sudo probes — keeps
# the prelaunch tests free of per-test function redefinition (SC2317).
_tui_stdin_is_tty() {
    [[ "${MOCK_STDIN_TTY:-false}" == "true" ]]
}

setup() {
    setup_test_env
    # The clip helpers (#168) count characters; pin a UTF-8 locale so the
    # test's own ${#output} / ${#_item} match the lib (CI's kcov image is
    # C/POSIX, where they would count bytes and the multibyte "…" skews length).
    export LC_ALL=C.UTF-8
    MOCK_AVAILABLE_CMDS=""
    MOCK_HAS_SUDO="true"
    MOCK_STDIN_TTY="false"
    MOCK_GUM_MARKER=""
    unset TUI_BACKEND 2>/dev/null || true
}

teardown() {
    teardown_test_env
}

# ── ADR-0019 fixtures ────────────────────────────────────────────────────────
# FIXTURE_LIST_JSON / FIXTURE_DETECT_JSON come from helper/tui_harness.bash.

# Same payload + one experimental module (Q44 future case: category
# auto-appears once non-empty, no spec change needed).
FIXTURE_LIST_JSON_WITH_EXPERIMENTAL="$(jq '.items += [{
  "name": "wild-thing", "category": "experimental", "tags": ["misc"],
  "description": "Experimental module", "version_provided": "git",
  "installed": false, "outdated": null, "manual": null,
  "depends_on": null, "supports_user_home": true,
  "supported_platforms": ["desktop"], "supported_ubuntu": ["24.04"],
  "risk_level": "high", "reboot_required": false, "homepage": null}] | .count = 5' \
  <<<"${FIXTURE_LIST_JSON}")"

# ── Backend selection (§8.5, #171: gum > whiptail; dialog dropped) ───────────

@test "tui_backend_detect prefers gum when both backends exist (#171)" {
    MOCK_AVAILABLE_CMDS="gum whiptail"
    run tui_backend_detect
    assert_success
    assert_output "gum"
}

@test "tui_backend_detect falls back to whiptail when gum missing" {
    MOCK_AVAILABLE_CMDS="whiptail"
    run tui_backend_detect
    assert_success
    assert_output "whiptail"
}

@test "tui_backend_detect prefers gum even over a present dialog (#171 dialog dropped)" {
    # dialog is no longer a detected backend: gum wins, and dialog alone
    # is invisible to detection.
    MOCK_AVAILABLE_CMDS="gum dialog"
    run tui_backend_detect
    assert_success
    assert_output "gum"
}

@test "tui_backend_detect ignores dialog (dropped from the set, #171)" {
    MOCK_AVAILABLE_CMDS="dialog"
    run tui_backend_detect
    assert_failure
}

@test "tui_backend_detect fails when both backends missing" {
    MOCK_AVAILABLE_CMDS=""
    run tui_backend_detect
    assert_failure
}

@test "tui_backend_detect honors TUI_BACKEND=gum override" {
    MOCK_AVAILABLE_CMDS="whiptail"
    TUI_BACKEND="gum" run tui_backend_detect
    assert_success
    assert_output "gum"
}

@test "tui_backend_detect honors TUI_BACKEND=whiptail override even when gum present" {
    MOCK_AVAILABLE_CMDS="gum whiptail"
    TUI_BACKEND="whiptail" run tui_backend_detect
    assert_success
    assert_output "whiptail"
}

@test "tui_backend_init exports TUI_BACKEND on success" {
    MOCK_AVAILABLE_CMDS="whiptail"
    tui_backend_init
    [ "${TUI_BACKEND}" = "whiptail" ]
}

@test "tui_backend_init prefers gum (#171)" {
    MOCK_AVAILABLE_CMDS="gum whiptail"
    tui_backend_init
    [ "${TUI_BACKEND}" = "gum" ]
}

@test "tui_backend_init fatal prints §8.5 fix guidance when both missing" {
    MOCK_AVAILABLE_CMDS=""
    run tui_backend_init
    assert_failure 1
    assert_output --partial "sudo apt install whiptail"
    assert_output --partial "CLI mode"
}

@test "tui_backend_init does NOT auto-install anything" {
    MOCK_AVAILABLE_CMDS=""
    run tui_backend_init
    refute_output --partial "Installing"
    # The §8.5 guidance mentions apt as a *suggestion* (inside the "Fix:"
    # heredoc), never as an action: assert no line *starts* with an apt
    # invocation (probes are mocked, so any real apt call would have to
    # be literal in the lib).
    run grep -E '^[[:space:]]*(sudo )?apt(-get)? (install|update)' \
        "${LIB_DIR}/tui_backend.sh"
    assert_failure
}

# ── Sudo gate (PRD §8.5: no sudo → exit 4, suggest CLI) ─────────────────────

@test "tui_require_sudo passes when sudo available" {
    MOCK_HAS_SUDO="true"
    run tui_require_sudo
    assert_success
}

@test "tui_require_sudo returns 4 and suggests CLI mode without sudo" {
    MOCK_HAS_SUDO="false"
    run tui_require_sudo
    assert_failure 4
    assert_output --partial "CLI mode"
    assert_output --partial "setup_ubuntu"
}

# ── Menu data parsing (ADR-0019 fixture; Q44) ────────────────────────────────

@test "tui_categories lists only non-empty categories in canonical order" {
    run tui_categories "${FIXTURE_LIST_JSON}"
    assert_success
    assert_line --index 0 "base"
    assert_line --index 1 "recommended"
    assert_line --index 2 "optional"
    refute_output --partial "experimental"
}

@test "tui_categories shows experimental once it has modules (Q44)" {
    run tui_categories "${FIXTURE_LIST_JSON_WITH_EXPERIMENTAL}"
    assert_success
    assert_line --index 3 "experimental"
}

@test "tui_category_stats reports installed/total for a category" {
    run tui_category_stats "${FIXTURE_LIST_JSON}" recommended
    assert_success
    assert_output "1 2"
}

@test "tui_main_menu_entries renders §8.1 rows without empty categories" {
    run tui_main_menu_entries "${FIXTURE_LIST_JSON}"
    assert_success
    assert_line --partial "quick-setup"
    assert_line --partial "Base Tools"
    assert_line --partial "Recommended (1/2)"
    assert_line --partial "Optional"
    assert_line --partial "Manage Installed"
    assert_line --partial "Manage Secrets"
    assert_line --partial "System Info"
    refute_output --partial "experimental"
    refute_output --partial "Experimental"
}

@test "tui_main_menu_entries adds experimental row when non-empty (Q44)" {
    run tui_main_menu_entries "${FIXTURE_LIST_JSON_WITH_EXPERIMENTAL}"
    assert_success
    assert_line --partial "Experimental"
}

@test "tui_main_menu_entries ends with the Run row (§8.1 batch execution point)" {
    run tui_main_menu_entries "${FIXTURE_LIST_JSON}"
    assert_success
    assert_line --index "$(( ${#lines[@]} - 1 ))" --partial "run"
    assert_line --partial "Review & install selected modules"
}

@test "tui_main_menu_entries emits tag<TAB>label<TAB>description TSV" {
    run tui_main_menu_entries "${FIXTURE_LIST_JSON}"
    assert_success
    # Every line must have exactly 3 tab-separated fields.
    while IFS= read -r _line; do
        [ "$(awk -F'\t' '{print NF}' <<<"${_line}")" -eq 3 ]
    done <<<"${output}"
}

# ── #169 main-menu section separators ────────────────────────────────────────

@test "tui_main_menu_entries inserts separator rows between the 3 groups (#169)" {
    run tui_main_menu_entries "${FIXTURE_LIST_JSON}"
    assert_success
    # Exactly two non-selectable separator rows (sentinel tag = "-").
    local _seps
    _seps="$(awk -F'\t' '$1 == "-"' <<<"${output}" | wc -l)"
    [ "${_seps}" -eq 2 ]
    # The divider label is a run of box-drawing dashes.
    assert_line --partial "──────"
}

@test "tui_main_menu_entries keeps all real action tags in order around separators (#169)" {
    run tui_main_menu_entries "${FIXTURE_LIST_JSON}"
    assert_success
    # Drop separator rows, then assert the real tags survive in order.
    local _tags
    _tags="$(awk -F'\t' '$1 != "-" {print $1}' <<<"${output}" | paste -sd' ' -)"
    [ "${_tags}" = "quick-setup base recommended optional manage secrets sysinfo run" ]
}

@test "tui_main_menu_entries: separator sits after group 1 (optional) and before manage (#169)" {
    run tui_main_menu_entries "${FIXTURE_LIST_JSON}"
    assert_success
    # Find indices: the row after "optional" is a separator, and the row
    # before "manage" is a separator.
    local _i=0 _opt=-1 _manage=-1 _run=-1
    while IFS=$'\t' read -r _tag _rest; do
        case "${_tag}" in
            optional) _opt=${_i} ;;
            manage) _manage=${_i} ;;
            run) _run=${_i} ;;
        esac
        _i=$(( _i + 1 ))
    done <<<"${output}"
    # group1 sep right after optional
    [ "$(awk -F'\t' -v n="$(( _opt + 1 ))" 'NR==n+1{print $1}' <<<"${output}")" = "-" ]
    # group2 sep right before manage
    [ "$(awk -F'\t' -v n="${_manage}" 'NR==n{print $1}' <<<"${output}")" = "-" ]
    # run is still last
    [ "${_run}" -eq "$(( ${#lines[@]} - 1 ))" ]
}

@test "_tui_main_loop guards against dispatching the separator sentinel (#169)" {
    # The dispatch must treat the sentinel tag as a no-op. Assert the guard
    # exists in the source (the loop re-loops without calling _tui_dispatch).
    run grep -nE 'TUI_MENU_SEPARATOR|"-"\)' "${REPO_ROOT}/setup_ubuntu_tui.sh"
    assert_success
}

@test "tui_modules_in_category lists module names alphabetically" {
    run tui_modules_in_category "${FIXTURE_LIST_JSON}" recommended
    assert_success
    assert_line --index 0 "docker"
    assert_line --index 1 "neovim"
}

# ── #168 checklist width clip (overflow fix) ─────────────────────────────────
# A category whose modules carry over-long descriptions, used to prove the
# rendered "[tag] description" item is clipped to the TUI_WIDTH budget.
FIXTURE_LIST_JSON_LONG_DESC="$(jq '.items += [{
  "name": "claude-code", "category": "optional", "tags": ["agent"],
  "description": "Anthropic Claude Code CLI agent (official native installer, self-updating)",
  "version_provided": "npm", "installed": false, "outdated": null,
  "manual": null, "depends_on": null, "supports_user_home": true,
  "supported_platforms": ["desktop"], "supported_ubuntu": ["24.04"],
  "risk_level": "low", "reboot_required": false, "homepage": null}]' \
  <<<"${FIXTURE_LIST_JSON}")"

@test "_tui_clip leaves a short string untouched" {
    run _tui_clip "short" 20
    assert_success
    assert_output "short"
}

@test "_tui_clip returns a string exactly at the budget untouched" {
    run _tui_clip "1234567890" 10
    assert_success
    assert_output "1234567890"
}

@test "_tui_clip truncates an over-long string with a single ellipsis" {
    run _tui_clip "abcdefghij" 5
    assert_success
    assert_output "abcd…"
    [ "${#output}" -eq 5 ]
}

@test "tui_checklist_entries emits the FULL description, unclipped (#183)" {
    # #183: the producer no longer clips — the #168 budget moved into the
    # whiptail adapter. gum reads this output directly and renders full text,
    # so the producer MUST emit the whole "[tag] description" and no ellipsis.
    TUI_WIDTH=72 run tui_checklist_entries "${FIXTURE_LIST_JSON_LONG_DESC}" optional ""
    assert_success
    assert_line --partial "[agent] Anthropic Claude Code CLI agent (official native installer, self-updating)"
    refute_output --partial "…"
}

@test "_tui_clip_checklist_args clips each item to the box budget, tag/status intact (#183)" {
    # The clip now lives in the whiptail adapter via this helper. Longest tag
    # here is "claude-code" (11) → budget 72 - 11 - 8 = 53. The helper emits
    # one field per line (tag, item, status); the item is clipped, the tag and
    # status pass through verbatim.
    local _long="[agent] Anthropic Claude Code CLI agent (official native installer, self-updating)"
    TUI_WIDTH=72 run _tui_clip_checklist_args claude-code "${_long}" off eza "[cli] ls" on
    assert_success
    # tag + status survive verbatim.
    assert_line --index 0 "claude-code"
    assert_line --index 2 "off"
    assert_line --index 3 "eza"
    assert_line --index 5 "on"
    # the long item is clipped to the 53-char budget with a trailing ellipsis.
    local _clipped="${lines[1]}"
    [ "${#_clipped}" -le 53 ]
    assert_line --index 1 --partial "…"
    # the short item is left untouched.
    assert_line --index 4 "[cli] ls"
}

@test "tui_render_checklist (whiptail) clips items before they reach the binary (#168 stays fixed)" {
    _make_mock_widget
    local _long="[agent] Anthropic Claude Code CLI agent (official native installer, self-updating)"
    # The whiptail-family adapter must clip — the logged argv shows the
    # ellipsis (item truncated to the box budget) and never the full string.
    MOCK_WIDGET_OUTPUT='' TUI_WIDTH=72 run tui_render_checklist "Optional" "Pick" \
        claude-code "${_long}" off
    assert_success
    run cat "${MOCK_WIDGET_LOG}"
    assert_output --partial "…"
    refute_output --partial "self-updating)"
}

@test "tui_render_checklist (gum) passes the FULL item, unclipped (#183)" {
    _make_mock_gum
    local _long="[agent] Anthropic Claude Code CLI agent (official native installer, self-updating)"
    # gum manages its own width: the adapter must hand gum the full item, so
    # the logged argv contains the whole description and no adapter ellipsis.
    MOCK_GUM_OUTPUT="${_long}"$'\n' TUI_WIDTH=72 run tui_render_checklist "Optional" "Pick" \
        claude-code "${_long}" off
    assert_success
    assert_output "claude-code"
    run cat "${MOCK_GUM_LOG}"
    assert_output --partial "self-updating)"
    refute_output --partial "…"
}

# ── Checkbox accumulator (#70, Q43 / §8.2) ───────────────────────────────────

@test "tui_checklist_entries emits name/label/status TSV grouped by TAGS[0]" {
    run tui_checklist_entries "${FIXTURE_LIST_JSON}" optional ""
    assert_success
    # Groups sorted alphabetically (agent < cli-essentials), then by name
    # inside the group; every module defaults to "off".
    assert_line --index 0 "$(printf 'claude-code\t[agent] Anthropic agent CLI\toff')"
    assert_line --index 1 "$(printf 'eza\t[cli-essentials] ls alternative\toff')"
    assert_line --index 2 "$(printf 'zoxide\t[cli-essentials] cd alternative\toff')"
}

@test "tui_checklist_entries marks accumulated selections on (Q43 reopen)" {
    run tui_checklist_entries "${FIXTURE_LIST_JSON}" optional "eza zoxide"
    assert_success
    assert_line --partial "$(printf 'eza\t[cli-essentials] ls alternative\ton')"
    assert_line --partial "$(printf 'zoxide\t[cli-essentials] cd alternative\ton')"
    assert_line --partial "$(printf 'claude-code\t[agent] Anthropic agent CLI\toff')"
}

@test "tui_checklist_entries collapses dep chains to a will-pull hint (Q-A3)" {
    run tui_checklist_entries "${FIXTURE_LIST_JSON}" recommended ""
    assert_success
    # docker carries depends_on=["apt-essentials"]: one collapsed hint,
    # never the expanded chain. neovim (depends_on=null) gets no hint.
    assert_line --partial "$(printf 'docker\t[container] Docker Engine (will pull 1 deps)\toff')"
    refute_output --partial "apt-essentials"
    assert_line --partial "$(printf 'neovim\t[editor] Neovim editor\toff')"
}

@test "tui_selection_replace_page accumulates pages across categories (Q43 OK)" {
    tui_selection_replace_page "${FIXTURE_LIST_JSON}" optional eza zoxide
    tui_selection_replace_page "${FIXTURE_LIST_JSON}" recommended neovim
    run tui_selection_list
    assert_success
    assert_line --index 0 "eza"
    assert_line --index 1 "neovim"
    assert_line --index 2 "zoxide"
    [ "$(tui_selection_count)" -eq 3 ]
}

@test "tui_selection_replace_page replaces only its own category page" {
    tui_selection_replace_page "${FIXTURE_LIST_JSON}" optional eza zoxide
    tui_selection_replace_page "${FIXTURE_LIST_JSON}" recommended neovim
    # Reopen Optional, uncheck eza, keep zoxide → OK replaces the page;
    # the Recommended accumulation is untouched.
    tui_selection_replace_page "${FIXTURE_LIST_JSON}" optional zoxide
    run tui_selection_list
    assert_success
    assert_line --index 0 "neovim"
    assert_line --index 1 "zoxide"
    refute_output --partial "eza"
}

@test "tui_selection_replace_page with no names clears the page (uncheck all)" {
    tui_selection_replace_page "${FIXTURE_LIST_JSON}" optional eza
    tui_selection_replace_page "${FIXTURE_LIST_JSON}" optional
    [ "$(tui_selection_count)" -eq 0 ]
}

# ── Run → CLI command generation (#70, AC-10 first layer / G4) ───────────────

@test "tui_install_args builds the forked CLI argv (one arg per line)" {
    run tui_install_args "" eza neovim
    assert_success
    assert_line --index 0 "install"
    assert_line --index 1 "eza"
    assert_line --index 2 "neovim"
    assert_line --index 3 "-y"
}

@test "tui_install_args wires the session platform override as --profile" {
    run tui_install_args "server" eza
    assert_success
    assert_line --index 0 "install"
    assert_line --index 1 "--profile=server"
    assert_line --index 2 "eza"
    assert_line --index 3 "-y"
}

@test "accumulated selections become one CLI command string (AC-10 layer 1)" {
    # Full Q43 slice: check pages → Run → generated command. The TUI fork
    # path is `"${TUI_CLI}" <argv...>`; assert the exact flattened string.
    tui_selection_replace_page "${FIXTURE_LIST_JSON}" optional zoxide eza
    tui_selection_replace_page "${FIXTURE_LIST_JSON}" recommended neovim
    local -a _sel=() _argv=()
    mapfile -t _sel < <(tui_selection_list)
    mapfile -t _argv < <(tui_install_args "" "${_sel[@]}")
    [ "${_argv[*]}" = "install eza neovim zoxide -y" ]
}

# ── Review & Install plan (dry-run fork; §8.1 Run / arch Q-A3) ───────────────

# Recording mock CLI: appends its argv to $MOCK_CLI_LOG and replays the
# dispatcher's DRY-RUN output (resolver order: deps first).
_make_mock_cli() {
    MOCK_CLI_LOG="${INIT_UBUNTU_TEST_SCRATCH}/cli.log"
    TUI_CLI="${INIT_UBUNTU_TEST_SCRATCH}/mock_setup_ubuntu"
    export MOCK_CLI_LOG TUI_CLI
    cat >"${TUI_CLI}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${MOCK_CLI_LOG}"
printf '[dispatcher] DRY-RUN: would install in this order:\n'
printf '  - fzf\n  - lazygit\n  - neovim\n  - eza\n'
EOF
    chmod +x "${TUI_CLI}"
}

@test "tui_cli_install_plan forks install --dry-run and parses the order" {
    _make_mock_cli
    run tui_cli_install_plan eza neovim
    assert_success
    assert_line --index 0 "fzf"
    assert_line --index 1 "lazygit"
    assert_line --index 2 "neovim"
    assert_line --index 3 "eza"
    # G4: the plan came from a fork of the CLI, with the exact argv.
    run cat "${MOCK_CLI_LOG}"
    assert_output "install --dry-run eza neovim"
}

@test "tui_cli_install_plan fails cleanly when the fork is not a dry-run" {
    _make_mock_cli
    printf '#!/usr/bin/env bash\nprintf "garbage\\n"\n' >"${TUI_CLI}"
    run tui_cli_install_plan eza
    assert_failure
    assert_output --partial "ERROR"
}

@test "tui_plan_deps reduces the plan to pulled-in deps (will pull N deps)" {
    local _plan=$'fzf\nlazygit\nneovim\neza'
    run tui_plan_deps "${_plan}" eza neovim
    assert_success
    assert_line --index 0 "fzf"
    assert_line --index 1 "lazygit"
    refute_output --partial "eza"
    refute_output --partial "neovim"
}

@test "tui_plan_deps is empty when the selection pulls nothing extra" {
    run tui_plan_deps $'eza\nzoxide' eza zoxide
    assert_success
    assert_output ""
}

# ── Checklist render wrapper (mock backend binary) ───────────────────────────

# Mock whiptail-family binary: logs argv, replays MOCK_WIDGET_OUTPUT on
# stderr (real widgets emit the choice on stderr; wrappers fd-swap it to
# stdout) and exits MOCK_WIDGET_RC. Named `whiptail` so the adapter
# dispatcher (_tui_<widget>_<backend>, keyed on the basename) routes it
# through the whiptail family.
_make_mock_widget() {
    MOCK_WIDGET_LOG="${INIT_UBUNTU_TEST_SCRATCH}/widget.log"
    TUI_BACKEND="${INIT_UBUNTU_TEST_SCRATCH}/whiptail"
    export MOCK_WIDGET_LOG TUI_BACKEND
    cat >"${TUI_BACKEND}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${MOCK_WIDGET_LOG}"
[[ -n "\${MOCK_WIDGET_OUTPUT:-}" ]] && printf '%b' "\${MOCK_WIDGET_OUTPUT}" >&2
exit "\${MOCK_WIDGET_RC:-0}"
EOF
    chmod +x "${TUI_BACKEND}"
}

# Mock `gum` binary: logs every invocation (subcommand + args, one line) to
# MOCK_GUM_LOG, replays MOCK_GUM_OUTPUT on STDOUT (gum emits choices on
# stdout, unlike dialog/whiptail's stderr+fd-swap), exits MOCK_GUM_RC.
_make_mock_gum() {
    MOCK_GUM_LOG="${INIT_UBUNTU_TEST_SCRATCH}/gum.log"
    TUI_BACKEND="${INIT_UBUNTU_TEST_SCRATCH}/gum"
    export MOCK_GUM_LOG TUI_BACKEND
    cat >"${TUI_BACKEND}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${MOCK_GUM_LOG}"
[[ -n "\${MOCK_GUM_OUTPUT:-}" ]] && printf '%b' "\${MOCK_GUM_OUTPUT}"
exit "\${MOCK_GUM_RC:-0}"
EOF
    chmod +x "${TUI_BACKEND}"
}

@test "tui_render_checklist passes --separate-output and returns one tag per line" {
    _make_mock_widget
    export MOCK_WIDGET_OUTPUT='eza\nzoxide\n'
    run tui_render_checklist "Optional" "Pick" eza "[x] eza" off zoxide "[x] zoxide" off
    assert_success
    assert_line --index 0 "eza"
    assert_line --index 1 "zoxide"
    run cat "${MOCK_WIDGET_LOG}"
    assert_output --partial "--separate-output"
    assert_output --partial "--checklist"
}

@test "tui_render_checklist propagates Back / ESC as nonzero rc" {
    _make_mock_widget
    export MOCK_WIDGET_RC=1
    run tui_render_checklist "Optional" "Pick" eza "[x] eza" off
    assert_failure
}

# ── gum adapters (#171: gum > whiptail; mock `gum` on PATH) ──────────────────
# gum has no hidden value: `gum choose` echoes the chosen *item* label, so the
# menu adapter maps that label back to its tag BY INDEX (duplicate-label safe).

@test "gum menu: gum choose over items, maps chosen label back to its tag by index" {
    _make_mock_gum
    # Three rows; user picks the 2nd item ("Recommended"). Adapter must emit
    # the matching tag "recommended" (not the item label). Inline env (not a
    # standalone export) keeps the mock-read var out of SC2030/2031 territory.
    MOCK_GUM_OUTPUT='Recommended\n' run tui_render_menu "Main" "Pick one" \
        quick-setup "Quick Setup" recommended "Recommended" run "Run"
    assert_success
    assert_output "recommended"
    # gum was invoked as `gum choose` over the ITEM labels, not the tags.
    run cat "${MOCK_GUM_LOG}"
    assert_output --partial "choose"
    assert_output --partial "Recommended"
}

@test "gum menu: duplicate item labels resolve to the FIRST matching tag by index" {
    _make_mock_gum
    # Two rows share the label "Browse". gum echoes only the label; the
    # adapter maps the chosen label to a tag by its first index match, so a
    # picked "Browse" lands on tag "a" (the first occurrence) — never crashes
    # or mis-maps on the duplicate.
    MOCK_GUM_OUTPUT='Browse\n' run tui_render_menu "M" "t" a "Browse" b "Browse"
    assert_success
    assert_output "a"
}

@test "gum checklist: gum choose --no-limit, checked items -> tags one per line" {
    _make_mock_gum
    # User checks "ls alternative" + "cd alternative"; adapter maps each back
    # to its tag (eza, zoxide), one per line (--separate-output contract).
    MOCK_GUM_OUTPUT='ls alternative\ncd alternative\n' \
        run tui_render_checklist "Optional" "Pick" \
        eza "ls alternative" off zoxide "cd alternative" off claude "agent CLI" off
    assert_success
    assert_line --index 0 "eza"
    assert_line --index 1 "zoxide"
    run cat "${MOCK_GUM_LOG}"
    assert_output --partial "choose"
    assert_output --partial "--no-limit"
}

@test "gum checklist: nothing checked yields empty stdout, success" {
    _make_mock_gum
    MOCK_GUM_OUTPUT='' run tui_render_checklist "Optional" "Pick" eza "ls alternative" off
    assert_success
    assert_output ""
}

@test "gum checklist: Esc/Ctrl-C (rc 130) propagates as nonzero, not swallowed" {
    _make_mock_gum
    MOCK_GUM_RC=130 run tui_render_checklist "Optional" "Pick" eza "ls alternative" off
    assert_failure
    [ "${status}" -ne 0 ]
}

@test "gum yesno: maps to gum confirm, rc 0 = yes" {
    _make_mock_gum
    MOCK_GUM_RC=0 run tui_render_yesno "Confirm" "Proceed?"
    assert_success
    run cat "${MOCK_GUM_LOG}"
    assert_output --partial "confirm"
}

@test "gum yesno: gum confirm rc 1 = no (cancel), not swallowed" {
    _make_mock_gum
    MOCK_GUM_RC=1 run tui_render_yesno "Confirm" "Proceed?"
    assert_failure
}

@test "gum msgbox: renders text via gum style/format and returns success" {
    _make_mock_gum
    run tui_render_msgbox "Info" "hello world"
    assert_success
    run cat "${MOCK_GUM_LOG}"
    # gum uses style or format for the box; either is acceptable.
    assert_output --regexp "style|format"
}

@test "gum menu: does not double-apply _tui_clip (gum manages its own width)" {
    _make_mock_gum
    # A very long item passes through to gum unclipped (no ellipsis injected
    # by the adapter — gum owns wrapping).
    local _long="This is an extremely long menu item label that would overflow a 72 column whiptail box several times over"
    MOCK_GUM_OUTPUT="${_long}"$'\n' run tui_render_menu "M" "t" only "${_long}"
    assert_success
    assert_output "only"
    run cat "${MOCK_GUM_LOG}"
    refute_output --partial "…"
}

@test "render wrappers relabel Cancel per backend (Exit / Back buttons)" {
    _make_mock_widget
    TUI_CANCEL_LABEL="Exit" run tui_render_menu "T" "txt" a "A"
    run cat "${MOCK_WIDGET_LOG}"
    # Mock binary is named whiptail (whiptail-family adapter) → --cancel-button.
    assert_output --partial "--cancel-button Exit"
}

# ── System summary (detect --json fixture; §8.1 header) ──────────────────────

@test "tui_system_summary renders the §8.1 one-line header" {
    run tui_system_summary "${FIXTURE_DETECT_JSON}"
    assert_success
    assert_output "Ubuntu 24.04 / NVIDIA RTX 4090 / GNOME / x11"
}

@test "tui_system_summary skips null fields (server, no GPU model)" {
    local _server_json='{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"x86_64","cpu":{"vendor":"GenuineIntel"},"gpu":{"vendor":null,"model":null},"desktop":null,"session_type":"tty","virt":{"container":false,"vm":false},"wsl":false,"board":null,"form_factor":"server"}'
    run tui_system_summary "${_server_json}"
    assert_success
    assert_output "Ubuntu 24.04 / tty"
}

# ── i18n (#185): backend's OWN labels localize under INIT_UBUNTU_LANG=zh-TW ──
# tui_backend.sh sources lib/i18n.sh itself, so i18n_t + TUI_BACKEND_I18N are
# available here. Pass-through caller text (module descriptions, ADR-0019
# payload fields) stays as-is — only the lib's own authored labels translate.

@test "i18n: main-menu rows render English by default (en byte-identical)" {
    INIT_UBUNTU_LANG=en run tui_main_menu_entries "${FIXTURE_LIST_JSON}"
    assert_success
    assert_line --partial "Quick Setup"
    assert_line --partial "Base Tools"
    assert_line --partial "Manage Installed"
}

@test "i18n: main-menu rows render zh-TW under INIT_UBUNTU_LANG=zh-TW (#185)" {
    INIT_UBUNTU_LANG=zh-TW run tui_main_menu_entries "${FIXTURE_LIST_JSON}"
    assert_success
    assert_line --partial "快速安裝"        # Quick Setup
    assert_line --partial "基礎工具"        # Base Tools
    assert_line --partial "管理已安裝項目"  # Manage Installed
    # The recommended count interpolation survives translation.
    assert_line --partial "推薦 (1/2)"
}

@test "i18n: platform choices localize the label but keep the tag (#185)" {
    INIT_UBUNTU_LANG=zh-TW run tui_platform_choices
    assert_success
    # tag column is a stable machine value; only the label translates.
    assert_line --partial "$(printf 'desktop\t桌機 / 筆電')"
    assert_line --partial "$(printf 'server\t無頭伺服器')"
}

@test "i18n: destructive confirm body translates the authored chrome (#185)" {
    INIT_UBUNTU_LANG=zh-TW run tui_manage_confirm_text purge neovim $'neovim'
    assert_success
    assert_output --partial "即將對 'neovim' 執行 PURGE"
    assert_output --partial "清除也會刪除該模組的設定檔"
}

# ── G4 structural gate: TUI never sources engine libs / writes state ─────────

@test "G4 gate: setup_ubuntu_tui.sh sources no engine lib" {
    run grep -nE 'source.*lib/(registry|runner|resolver|state)' \
        "${REPO_ROOT}/setup_ubuntu_tui.sh"
    assert_failure
}

@test "G4 gate: lib/tui_backend.sh sources no engine lib" {
    run grep -nE 'source.*lib/(registry|runner|resolver|state)' \
        "${LIB_DIR}/tui_backend.sh"
    assert_failure
}

@test "G4 gate: TUI entrypoint exists and is executable" {
    [ -x "${REPO_ROOT}/setup_ubuntu_tui.sh" ]
}

# ── Entrypoint smoke (no backend / sudo needed for help) ────────────────────

@test "setup_ubuntu_tui.sh --help prints usage and exits 0" {
    run "${REPO_ROOT}/setup_ubuntu_tui.sh" --help
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "setup_ubuntu_tui"
}

@test "setup_ubuntu_tui.sh rejects unknown flags with exit 2" {
    run "${REPO_ROOT}/setup_ubuntu_tui.sh" --bogus
    assert_failure 2
}

# ── --backend flag (#171: testability lever; skips detection + install prompt) ─
# These drive the REAL entrypoint with a sealed PATH farm so detection / the
# install prompt can be observed without a live gum/whiptail.

# Build a sealed env where ONLY whiptail (mock) exists — neither gum nor a
# real backend leaks in. The mock backends/CLI immediately exit so the main
# loop unwinds after the first widget call; we only assert pre-launch wiring.
_make_flag_env() {
    FLAG_DIR="${INIT_UBUNTU_TEST_SCRATCH}/flagenv"
    rm -rf "${FLAG_DIR}"; mkdir -p "${FLAG_DIR}/bin" "${FLAG_DIR}/home"
    FLAG_BIN="${FLAG_DIR}/bin"; FLAG_LOG="${FLAG_DIR}/probe.log"
    export FLAG_BIN FLAG_LOG
    tui_harness_farm "${FLAG_BIN}"
    tui_harness_mock_cli "${FLAG_BIN}" "${FLAG_DIR}" "${FLAG_DIR}/cli.log"
    # sudo: present + passwordless so tui_require_sudo passes in the sealed env.
    cat >"${FLAG_BIN}/sudo" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "-n" ]] && exit 0
exec "${@:1}"
EOF
    chmod +x "${FLAG_BIN}/sudo"
    # A widget mock that records which backend basename was invoked then exits
    # nonzero (Cancel) so the main loop returns immediately.
    for _w in whiptail gum; do
        cat >"${FLAG_BIN}/${_w}" <<EOF
#!/usr/bin/env bash
printf 'BACKEND=%s ARGS=%s\n' "${_w}" "\$*" >>"${FLAG_LOG}"
exit 1
EOF
        chmod +x "${FLAG_BIN}/${_w}"
    done
}

@test "--backend whiptail forces TUI_BACKEND, skips detection (gum present)" {
    _make_flag_env
    run env "PATH=${FLAG_BIN}" "HOME=${FLAG_DIR}/home" \
        "TUI_CLI=${FLAG_BIN}/setup_ubuntu" \
        "${REPO_ROOT}/setup_ubuntu_tui.sh" --backend whiptail
    # Main loop unwinds on the first Cancel; the forced backend was whiptail
    # even though gum was on PATH (detection skipped).
    run cat "${FLAG_LOG}"
    assert_output --partial "BACKEND=whiptail"
    refute_output --partial "BACKEND=gum"
}

@test "--backend gum forces TUI_BACKEND even when whiptail would win detection" {
    _make_flag_env
    run env "PATH=${FLAG_BIN}" "HOME=${FLAG_DIR}/home" \
        "TUI_CLI=${FLAG_BIN}/setup_ubuntu" \
        "${REPO_ROOT}/setup_ubuntu_tui.sh" --backend gum
    run cat "${FLAG_LOG}"
    assert_output --partial "BACKEND=gum"
}

@test "--backend with an invalid value exits 2 with usage" {
    run "${REPO_ROOT}/setup_ubuntu_tui.sh" --backend dialog
    assert_failure 2
    assert_output --partial "Usage:"
}

@test "--backend with no value exits 2 with usage" {
    run "${REPO_ROOT}/setup_ubuntu_tui.sh" --backend
    assert_failure 2
}

# ── Pre-launch install-prompt flow (#171) ────────────────────────────────────
# gum absent + interactive → plain stdin `read` prompt (default Yes); on yes
# fork `setup_ubuntu install gum`, re-detect. The helper `_tui_prelaunch_backend`
# isolates this so it is unit-testable without a tty: it reads the answer from
# stdin, honors the `[[ -t 0 ]]` interactivity gate via a mockable
# `_tui_stdin_is_tty`, and prints the resolved backend.

@test "prelaunch: gum present -> use gum, no prompt" {
    MOCK_AVAILABLE_CMDS="gum whiptail"
    run _tui_prelaunch_backend </dev/null
    assert_success
    assert_output "gum"
}

@test "prelaunch: gum absent + non-interactive -> whiptail silently, no prompt" {
    MOCK_AVAILABLE_CMDS="whiptail"
    MOCK_STDIN_TTY="false" run _tui_prelaunch_backend </dev/null
    assert_success
    assert_output "whiptail"
    refute_output --partial "Install gum"
}

@test "prelaunch: gum absent + interactive + answer no -> whiptail" {
    MOCK_AVAILABLE_CMDS="whiptail"
    MOCK_STDIN_TTY="true" run _tui_prelaunch_backend <<<"n"
    assert_success
    assert_output --partial "whiptail"
    assert_output --partial "Install gum"
}

@test "prelaunch: interactive + answer yes -> forks install gum, re-detects to gum" {
    # The install fork is mocked: it 'creates' gum (drops the marker file) so
    # the post-fork _tui_has_cmd gum re-check succeeds (MOCK_GUM_MARKER seam).
    _make_mock_cli   # sets TUI_CLI + MOCK_CLI_LOG
    local _marker="${INIT_UBUNTU_TEST_SCRATCH}/gum_installed"
    # Mock CLI: `install gum` writes the marker.
    cat >"${TUI_CLI}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${MOCK_CLI_LOG}"
[[ "\$*" == "install gum" ]] && : >"${_marker}"
EOF
    chmod +x "${TUI_CLI}"
    MOCK_AVAILABLE_CMDS="whiptail"
    MOCK_STDIN_TTY="true" MOCK_GUM_MARKER="${_marker}" \
        run _tui_prelaunch_backend <<<"y"
    assert_success
    assert_output --partial "gum"
    # The fork really happened with the G4 argv.
    run cat "${MOCK_CLI_LOG}"
    assert_output --partial "install gum"
}

@test "prelaunch: interactive + yes but install fails -> warn + whiptail" {
    _make_mock_cli
    # install gum 'fails' (never creates gum); probe stays whiptail-only.
    cat >"${TUI_CLI}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${MOCK_CLI_LOG}"
exit 1
EOF
    chmod +x "${TUI_CLI}"
    MOCK_AVAILABLE_CMDS="whiptail"
    MOCK_STDIN_TTY="true" run _tui_prelaunch_backend <<<"y"
    assert_success
    assert_output --partial "whiptail"
}

# ── Real CLI list --json fork (issue #165 regression guard, G4 / ADR-0019) ───
# The AC-10 layer-1 + Q43 e2e suites mock TUI_CLI, so they never exercised the
# real `setup_ubuntu list --json`. This hardening test forks the REAL engine
# entrypoint through the same _tui_cli_json validator the TUI uses at startup,
# proving the catalog payload is valid JSON the TUI can parse (this is exactly
# what failed at v0.1.0-rc2 with the stubbed emitter).

@test "tui_cli_list_json forks the REAL setup_ubuntu and returns valid catalog JSON" {
    TUI_CLI="${REPO_ROOT}/setup_ubuntu.sh"
    export TUI_CLI
    run tui_cli_list_json
    assert_success
    # _tui_cli_json already jq -e validated; re-confirm shape the TUI consumes.
    echo "${output}" | jq -e '.items | type == "array"' > /dev/null
    echo "${output}" | jq -e '.items[0] | has("name") and has("category") and has("tags")' > /dev/null
}

@test "real setup_ubuntu list --json keeps warnings off stdout (TUI parse safety)" {
    # stderr is discarded by _tui_cli_json; assert stdout alone is pure JSON.
    run "${REPO_ROOT}/setup_ubuntu.sh" list --json
    assert_success
    refute_output --partial "[dispatcher]"
    echo "${output}" | jq -e . > /dev/null
}

# ── Q43 end-to-end: scripted backend + recorded CLI forks (#70, AC-10) ───────
# tui_e2e_make_harness / tui_e2e_run (helper/tui_harness.bash) drive the
# REAL setup_ubuntu_tui.sh process with a scripted widget + recording mock
# `setup_ubuntu` on a sealed PATH. This asserts AC-10 layer 1 end to end:
# checkbox pages accumulate in TUI memory, < Run > → Review → Proceed forks
# ONE CLI install command (G4 — the same path the CLI takes, which is what
# makes AC-11 structural), and < Exit > leaves zero files behind.
# The dual-backend (dialog vs whiptail) AC-10 suite lives in
# test/unit/tui_ac10_spec.bats.

@test "e2e: checked pages accumulate and Run/Proceed forks one install command" {
    tui_e2e_make_harness
    cat >"${E2E_RESPONSES}" <<'EOF'
0|optional
0|eza\nzoxide\n
0|recommended
0|neovim\n
0|run
0|proceed
EOF
    tui_e2e_run
    assert_success
    # The Proceed fork IS the CLI pipeline (G4 / AC-11 structural).
    assert_output --partial "CLI pipeline output"
    run grep -c "^install " "${E2E_CLI_LOG}"
    assert_output "2"   # one --dry-run (Review plan) + one real fork
    run tail -n1 "${E2E_CLI_LOG}"
    assert_output "install eza neovim zoxide -y"
}

@test "e2e: Back on a checklist page discards only that page (Q43)" {
    tui_e2e_make_harness
    cat >"${E2E_RESPONSES}" <<'EOF'
0|optional
0|eza\n
0|recommended
1|
0|run
0|proceed
EOF
    tui_e2e_run
    assert_success
    run tail -n1 "${E2E_CLI_LOG}"
    assert_output "install eza -y"
}

@test "e2e: Run with nothing selected reports 'nothing selected', no fork" {
    tui_e2e_make_harness
    cat >"${E2E_RESPONSES}" <<'EOF'
0|run
0|
1|
EOF
    tui_e2e_run
    assert_success
    run cat "${E2E_WIDGET_LOG}"
    assert_output --partial "nothing selected"
    run grep -c "^install" "${E2E_CLI_LOG}"
    assert_failure   # grep -c prints 0 + rc 1: install was never forked
}

@test "e2e: Review Back returns to the main menu keeping selections" {
    tui_e2e_make_harness
    cat >"${E2E_RESPONSES}" <<'EOF'
0|optional
0|eza\n
0|run
1|
0|run
0|proceed
EOF
    tui_e2e_run
    assert_success
    run tail -n1 "${E2E_CLI_LOG}"
    assert_output "install eza -y"
}

@test "e2e: Exit drops in-memory selections with zero file writes (fs snapshot)" {
    tui_e2e_make_harness
    cat >"${E2E_RESPONSES}" <<'EOF'
0|optional
0|eza\nzoxide\n
1|
EOF
    tui_e2e_run
    assert_success
    # Selections lived ONLY in TUI process memory: nothing under $HOME...
    run find "${E2E_HOME}" -mindepth 1
    assert_output ""
    # ...and no install was ever forked.
    run grep -c "^install" "${E2E_CLI_LOG}"
    assert_failure
}
