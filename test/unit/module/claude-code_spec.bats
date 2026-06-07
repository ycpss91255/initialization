#!/usr/bin/env bats
# test/unit/module/claude-code_spec.bats — module/claude-code.module.sh
#
# Per Q29: smoke / metadata / lifecycle dry-run / no-side-fx / idempotency /
# standalone CLI / module-specific (custom archetype D: official native
# installer, self-updating tool, sidecar lifecycle ADR-0001).

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
}

teardown() {
    teardown_test_env
}

_load_module() {
    # shellcheck source=../../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../../lib/general.sh
    source "${LIB_DIR}/general.sh"
    # shellcheck source=../../../lib/module_helper.sh
    source "${LIB_DIR}/module_helper.sh"
    # shellcheck source=../../../module/claude-code.module.sh
    source "${MODULE_DIR}/claude-code.module.sh"
}

# _standalone_module runs the module as a self-contained CLI (the same
# entry users hit when they type `bash module/claude-code.module.sh ...`).
_standalone_module() {
    bash "${MODULE_DIR}/claude-code.module.sh" "$@"
}

# ── Controllable mocks ───────────────────────────────────────────────────────
# Each shadowed function is defined exactly once and parameterized via
# MOCK_* variables, so every definition stays reachable for the linter
# (avoids SC2317 without disable directives).

# is_installed mock: MOCK_IS_INSTALLED_RC (0 = installed, 1 = not).
_mock_is_installed() {
    is_installed() { return "${MOCK_IS_INSTALLED_RC:-0}"; }
}

# Native installer mock: MOCK_INSTALLER_RC (0 = success).
_mock_installer() {
    _claude_code_run_installer() { return "${MOCK_INSTALLER_RC:-0}"; }
}

# Self-updater mock: MOCK_SELF_UPDATE_RC (0 = success).
_mock_self_update() {
    _claude_code_self_update() { return "${MOCK_SELF_UPDATE_RC:-0}"; }
}

# Version probe mock: MOCK_CLAUDE_VERSION (default 9.9.9).
_mock_version() {
    _claude_code_version() { printf '%s' "${MOCK_CLAUDE_VERSION:-9.9.9}"; }
}

# Drop a fake `claude` launcher at CLAUDE_BIN that answers --version and
# records every argv line into ${INIT_UBUNTU_TEST_SCRATCH}/claude-calls.
_make_fake_claude_bin() {
    CLAUDE_BIN="${INIT_UBUNTU_TEST_SCRATCH}/bin/claude"
    mkdir -p "${CLAUDE_BIN%/*}"
    cat > "${CLAUDE_BIN}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${INIT_UBUNTU_TEST_SCRATCH}/claude-calls"
[[ "\${1:-}" == "--version" ]] && printf '9.9.9 (Claude Code)\n'
exit 0
EOF
    chmod +x "${CLAUDE_BIN}"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "claude-code module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/claude-code.module.sh"
    assert_success
}

@test "claude-code module sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "claude-code module defines all 10 lifecycle functions" {
    _load_module
    local _fn
    for _fn in detect is_recommended is_installed install upgrade \
               remove purge verify is_outdated doctor; do
        declare -F "${_fn}" >/dev/null || {
            printf 'missing lifecycle function: %s\n' "${_fn}" >&2
            return 1
        }
    done
}

# ── Metadata sanity ──────────────────────────────────────────────────────────

@test "claude-code module declares NAME=claude-code" {
    _load_module
    [[ "${NAME}" == "claude-code" ]]
}

@test "claude-code module CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "claude-code module TAGS contains agent" {
    _load_module
    [[ " ${TAGS[*]} " == *" agent "* ]]
}

@test "claude-code module DEPENDS_ON is empty (Q39: module names only)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 0 ]]
}

@test "claude-code DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "claude-code module_get_description returns language-specific text" {
    _load_module
    [[ "$(module_get_description en)" == *"Claude Code"* ]]
    [[ -n "$(module_get_description zh-TW)" ]]
    # Unknown language falls back to en.
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "claude-code SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "claude-code module RISK_LEVEL=low" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
}

@test "claude-code module VERSION_PROVIDED=latest" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "latest" ]]
}

@test "claude-code HOMEPAGE is an https URL" {
    _load_module
    [[ "${HOMEPAGE}" == https://* ]]
}

@test "claude-code installs to user home without sudo (native installer)" {
    _load_module
    [[ "${SUPPORTS_USER_HOME}" == "true" ]]
    [[ "${INSTALL_TARGET_DEFAULT}" == "user-home" ]]
}

@test "claude-code installer URL is the official claude.ai install script" {
    _load_module
    [[ "${CLAUDE_CODE_INSTALLER_URL}" == "https://claude.ai/install.sh" ]]
}

@test "claude-code POST_INSTALL_MESSAGE mentions sign-in and auto-update" {
    _load_module
    [[ "$(module_get_post_install_message en)" == *"claude"* ]]
    [[ -n "$(module_get_post_install_message zh-TW)" ]]
}

# ── Lifecycle dry-run (AC-12 pattern) ────────────────────────────────────────

@test "install in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "upgrade in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run upgrade
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "remove in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "purge in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run purge
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "verify in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run verify
    assert_success
    assert_output --partial "DRY-RUN"
}

# ── No side effects under dry-run ────────────────────────────────────────────

@test "dry-run install writes nothing under the state dir" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/claude-code" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "dry-run remove leaves an existing sidecar in place" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/claude-code"
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/claude-code" ]]
}

@test "standalone dry-run install creates no files in a scratch HOME" {
    local _home="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${_home}"
    HOME="${_home}" XDG_STATE_HOME="${_home}/.local/state" \
        run _standalone_module install --dry-run
    assert_success
    local _leftover
    _leftover="$(find "${_home}" -mindepth 1 2>/dev/null)"
    [[ -z "${_leftover}" ]]
}

# ── Sidecar lifecycle (ADR-0001) ─────────────────────────────────────────────

@test "install writes the sidecar with the probed version" {
    _load_module
    _mock_installer
    _mock_version
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    install
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/claude-code" ]]
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/claude-code")" == "9.9.9" ]]
}

@test "install never touches state.json (ADR-0001 / AC-23 pattern)" {
    _load_module
    printf '{"schema_version":"0.1.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    _mock_installer
    _mock_version
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "failed installer leaves no sidecar behind (ADR-0015)" {
    _load_module
    MOCK_INSTALLER_RC=1
    _mock_installer
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run install
    assert_failure
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/claude-code" ]]
}

@test "upgrade refreshes the sidecar version" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/claude-code"
    _mock_self_update
    _mock_version
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    upgrade
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/claude-code")" == "9.9.9" ]]
}

@test "remove deletes the sidecar" {
    _load_module
    CLAUDE_BIN="${INIT_UBUNTU_TEST_SCRATCH}/bin/claude"
    CLAUDE_DATA_DIR="${INIT_UBUNTU_TEST_SCRATCH}/share/claude"
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/claude-code"
    remove
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/claude-code" ]]
}

@test "purge deletes the sidecar" {
    _load_module
    CLAUDE_BIN="${INIT_UBUNTU_TEST_SCRATCH}/bin/claude"
    CLAUDE_DATA_DIR="${INIT_UBUNTU_TEST_SCRATCH}/share/claude"
    CONFIG_PATHS=("${INIT_UBUNTU_TEST_SCRATCH}/dot-claude")
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/claude-code"
    purge
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/claude-code" ]]
}

# ── Real remove/purge against a scratch prefix (no sudo) ────────────────────

@test "remove deletes the launcher and data dir but keeps user config" {
    _load_module
    CLAUDE_BIN="${INIT_UBUNTU_TEST_SCRATCH}/bin/claude"
    CLAUDE_DATA_DIR="${INIT_UBUNTU_TEST_SCRATCH}/share/claude"
    CONFIG_PATHS=("${INIT_UBUNTU_TEST_SCRATCH}/dot-claude")
    mkdir -p "${CLAUDE_BIN%/*}" "${CLAUDE_DATA_DIR}" "${CONFIG_PATHS[0]}"
    printf 'bin\n' > "${CLAUDE_BIN}"
    remove
    [[ ! -e "${CLAUDE_BIN}" ]]
    [[ ! -e "${CLAUDE_DATA_DIR}" ]]
    [[ -d "${CONFIG_PATHS[0]}" ]]
}

@test "remove is idempotent — second run still exits 0" {
    _load_module
    CLAUDE_BIN="${INIT_UBUNTU_TEST_SCRATCH}/bin/claude"
    CLAUDE_DATA_DIR="${INIT_UBUNTU_TEST_SCRATCH}/share/claude"
    run remove
    assert_success
    run remove
    assert_success
}

@test "purge clears CONFIG_PATHS in addition to the binary" {
    _load_module
    CLAUDE_BIN="${INIT_UBUNTU_TEST_SCRATCH}/bin/claude"
    CLAUDE_DATA_DIR="${INIT_UBUNTU_TEST_SCRATCH}/share/claude"
    CONFIG_PATHS=(
        "${INIT_UBUNTU_TEST_SCRATCH}/dot-claude"
        "${INIT_UBUNTU_TEST_SCRATCH}/dot-claude.json"
    )
    mkdir -p "${CLAUDE_DATA_DIR}" "${CONFIG_PATHS[0]}"
    printf '{}\n' > "${CONFIG_PATHS[1]}"
    purge
    [[ ! -e "${CLAUDE_DATA_DIR}" ]]
    [[ ! -e "${CONFIG_PATHS[0]}" ]]
    [[ ! -e "${CONFIG_PATHS[1]}" ]]
}

@test "purge is idempotent — second run still exits 0" {
    _load_module
    CLAUDE_BIN="${INIT_UBUNTU_TEST_SCRATCH}/bin/claude"
    CLAUDE_DATA_DIR="${INIT_UBUNTU_TEST_SCRATCH}/share/claude"
    CONFIG_PATHS=("${INIT_UBUNTU_TEST_SCRATCH}/dot-claude")
    run purge
    assert_success
    run purge
    assert_success
}

# ── Idempotency (AC-5 pattern) ───────────────────────────────────────────────

@test "install short-circuits when is_installed returns 0 (idempotency)" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    run install
    assert_success
    assert_output --partial "already installed"
}

@test "install twice with installer mocked exits 0 both times" {
    _load_module
    _mock_installer
    _mock_version
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run install
    assert_success
    # Second run: the launcher is now present.
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    run install
    assert_success
}
