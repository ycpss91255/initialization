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
# Minimal `list --json` payload: base/recommended/optional populated,
# experimental EMPTY (mirrors the current catalog — Q44 case).

FIXTURE_LIST_JSON="$(cat <<'EOF'
{
  "schema_version": "1",
  "scope": "available",
  "filters": {"category": null, "tag": null},
  "items": [
    {"name": "apt-essentials", "category": "base", "tags": ["core", "apt"],
     "description": "Foundation apt packages", "version_provided": "apt-managed",
     "installed": true, "outdated": false, "manual": false,
     "depends_on": [], "supports_user_home": false,
     "supported_platforms": ["desktop", "server"], "supported_ubuntu": ["24.04"],
     "risk_level": "low", "reboot_required": false, "homepage": null},
    {"name": "docker", "category": "recommended", "tags": ["container"],
     "description": "Docker Engine", "version_provided": "apt-managed",
     "installed": true, "outdated": false, "manual": true,
     "depends_on": ["apt-essentials"], "supports_user_home": false,
     "supported_platforms": ["desktop", "server"], "supported_ubuntu": ["24.04"],
     "risk_level": "low", "reboot_required": false, "homepage": "https://docs.docker.com/"},
    {"name": "neovim", "category": "recommended", "tags": ["editor"],
     "description": "Neovim editor", "version_provided": "v0.10.2",
     "installed": false, "outdated": null, "manual": null,
     "depends_on": null, "supports_user_home": true,
     "supported_platforms": ["desktop", "server", "wsl"], "supported_ubuntu": ["24.04"],
     "risk_level": "low", "reboot_required": false, "homepage": "https://neovim.io/"},
    {"name": "eza", "category": "optional", "tags": ["cli-essentials"],
     "description": "ls alternative", "version_provided": "github-release",
     "installed": false, "outdated": null, "manual": null,
     "depends_on": null, "supports_user_home": true,
     "supported_platforms": ["desktop", "server", "wsl"], "supported_ubuntu": ["24.04"],
     "risk_level": "low", "reboot_required": false, "homepage": "https://eza.rocks/"}
  ],
  "count": 4,
  "generated_at": "2026-06-07T00:00:00+08:00"
}
EOF
)"

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

# `detect --json` fixture (lib/detect.sh shape + form_factor splice).
FIXTURE_DETECT_JSON="$(cat <<'EOF'
{"os":{"id":"ubuntu","version":"24.04","codename":"noble"},"arch":"x86_64","cpu":{"vendor":"GenuineIntel"},"gpu":{"vendor":"nvidia","model":"NVIDIA RTX 4090"},"desktop":"GNOME","session_type":"x11","virt":{"container":false,"vm":false},"wsl":false,"board":null,"form_factor":"desktop"}
EOF
)"

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
