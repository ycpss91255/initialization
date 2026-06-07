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
    case " ${MOCK_AVAILABLE_CMDS:-} " in
        *" ${1} "*) return 0 ;;
    esac
    return 1
}

_tui_has_sudo() {
    [[ "${MOCK_HAS_SUDO:-true}" == "true" ]]
}

setup() {
    setup_test_env
    MOCK_AVAILABLE_CMDS=""
    MOCK_HAS_SUDO="true"
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

# ── Backend selection (§8.5) ─────────────────────────────────────────────────

@test "tui_backend_detect prefers dialog when both backends exist" {
    MOCK_AVAILABLE_CMDS="dialog whiptail"
    run tui_backend_detect
    assert_success
    assert_output "dialog"
}

@test "tui_backend_detect falls back to whiptail when dialog missing" {
    MOCK_AVAILABLE_CMDS="whiptail"
    run tui_backend_detect
    assert_success
    assert_output "whiptail"
}

@test "tui_backend_detect fails when both backends missing" {
    MOCK_AVAILABLE_CMDS=""
    run tui_backend_detect
    assert_failure
}

@test "tui_backend_init exports TUI_BACKEND on success" {
    MOCK_AVAILABLE_CMDS="whiptail"
    tui_backend_init
    [ "${TUI_BACKEND}" = "whiptail" ]
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

@test "tui_modules_in_category lists module names alphabetically" {
    run tui_modules_in_category "${FIXTURE_LIST_JSON}" recommended
    assert_success
    assert_line --index 0 "docker"
    assert_line --index 1 "neovim"
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

# Mock dialog/whiptail binary: logs argv, replays MOCK_WIDGET_OUTPUT on
# stderr (real widgets emit the choice on stderr; wrappers fd-swap it to
# stdout) and exits MOCK_WIDGET_RC.
_make_mock_widget() {
    MOCK_WIDGET_LOG="${INIT_UBUNTU_TEST_SCRATCH}/widget.log"
    TUI_BACKEND="${INIT_UBUNTU_TEST_SCRATCH}/mock_widget"
    export MOCK_WIDGET_LOG TUI_BACKEND
    cat >"${TUI_BACKEND}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${MOCK_WIDGET_LOG}"
[[ -n "\${MOCK_WIDGET_OUTPUT:-}" ]] && printf '%b' "\${MOCK_WIDGET_OUTPUT}" >&2
exit "\${MOCK_WIDGET_RC:-0}"
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

@test "render wrappers relabel Cancel per backend (Exit / Back buttons)" {
    _make_mock_widget
    TUI_CANCEL_LABEL="Exit" run tui_render_menu "T" "txt" a "A"
    run cat "${MOCK_WIDGET_LOG}"
    # Mock is neither named whiptail nor dialog → default (dialog) spelling.
    assert_output --partial "--cancel-label Exit"
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
