#!/usr/bin/env bats
# test/unit/module/zoxide_spec.bats — module/zoxide.module.sh (issue #52)
#
# Q29 categories: smoke / metadata / lifecycle dry-run / no-side-fx /
# idempotency / standalone CLI / module-specific (shell-rc init, Sidecar).
#
# Mock convention: every test-local mock is invoked once directly right
# after its definition (wiring smoke + makes the indirect dispatch visible
# to ShellCheck without an SC2317 disable).

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    # Sandbox $HOME so shell-rc writes never touch the real home dir.
    export HOME="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${HOME}"
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
    # shellcheck source=../../../module/zoxide.module.sh
    source "${MODULE_DIR}/zoxide.module.sh"
}

# Make is_installed deterministically true: point BIN_LINK at a scratch
# executable (the github-release default checks `-x ${BIN_LINK}` first).
_fake_installed() {
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/bin/sh\necho "zoxide 1.0.0"\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/zoxide"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/zoxide"
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/bin/zoxide"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "zoxide module file parses (bash -n)" {
    bash -n "${MODULE_DIR}/zoxide.module.sh"
}

@test "zoxide defines all 10 lifecycle functions after load" {
    _load_module
    local _fn
    for _fn in is_installed install upgrade remove purge verify \
               detect is_recommended is_outdated doctor; do
        declare -F "${_fn}" >/dev/null || {
            printf 'missing lifecycle fn: %s\n' "${_fn}" >&2
            return 1
        }
    done
}

# ── Metadata ─────────────────────────────────────────────────────────────────

@test "zoxide module declares NAME=zoxide" {
    _load_module
    [[ "${NAME}" == "zoxide" ]]
}

@test "zoxide module CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "zoxide TAGS contains cli-essentials" {
    _load_module
    [[ " ${TAGS[*]} " == *" cli-essentials "* ]]
}

@test "zoxide DEPENDS_ON is empty (Q39: module names only)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 0 ]]
}

@test "zoxide DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "$(module_get_description en)" ]]
    [[ -n "$(module_get_description zh-TW)" ]]
}

@test "zoxide SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "zoxide RISK_LEVEL=low and REBOOT_REQUIRED=false" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
    [[ "${REBOOT_REQUIRED}" == "false" ]]
}

@test "zoxide SUPPORTS_USER_HOME=false" {
    _load_module
    [[ "${SUPPORTS_USER_HOME}" == "false" ]]
}

@test "zoxide archetype data targets ajeetdsouza/zoxide -> /opt/zoxide" {
    _load_module
    [[ "${GITHUB_REPO}" == "ajeetdsouza/zoxide" ]]
    [[ "${BIN_NAME}" == "zoxide" ]]
    [[ "${INSTALL_DIR}" == "/opt/zoxide" ]]
}

# ── Engine discovery ─────────────────────────────────────────────────────────

@test "registry discovers zoxide with tag cli-essentials" {
    # shellcheck source=../../../lib/registry.sh
    source "${LIB_DIR}/registry.sh"
    registry_load_all "${MODULE_DIR}"
    registry_has "zoxide"
    run registry_list_names --tag=cli-essentials
    assert_success
    assert_line "zoxide"
}

# ── Lifecycle dry-run ────────────────────────────────────────────────────────

@test "install in dry-run mode is a no-op with DRY-RUN log" {
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

# ── No side effects (AC-12 pattern) ──────────────────────────────────────────

@test "dry-run install writes no sidecar and leaves shell rc untouched" {
    _load_module
    printf '# my bashrc\n' > "${HOME}/.bashrc"
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/zoxide" ]]
    [[ "$(cat "${HOME}/.bashrc")" == "# my bashrc" ]]
}

@test "dry-run remove and purge keep an existing sidecar" {
    _load_module
    module_sidecar_write "zoxide" "1.0.0"
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    INIT_UBUNTU_DRY_RUN=true run purge
    assert_success
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/zoxide" ]]
}

@test "standalone-style install never touches state.json (ADR-0001 / AC-23)" {
    _load_module
    printf '{"sentinel":true}\n' > "${INIT_UBUNTU_STATE_DIR}/state.json"
    _zoxide_resolve_asset_pattern() { ZOXIDE_RESOLVED_VERSION="9.9.9"; }
    _zoxide_resolve_asset_pattern
    module_default_github_release_install() { :; }
    module_default_github_release_install
    run install
    assert_success
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == '{"sentinel":true}' ]]
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/zoxide" ]]
}

# ── Idempotency (AC-5 pattern) ───────────────────────────────────────────────

@test "install short-circuits when already installed" {
    _load_module
    _fake_installed
    run install
    assert_success
    assert_output --partial "already installed"
}

@test "install run twice both exit 0 (idempotent)" {
    _load_module
    _fake_installed
    run install
    assert_success
    run install
    assert_success
}

# ── is_installed ─────────────────────────────────────────────────────────────

@test "is_installed returns nonzero when zoxide is absent" {
    _load_module
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/no/such/zoxide"
    run is_installed
    assert_failure
}

@test "is_installed returns 0 when BIN_LINK is an executable" {
    _load_module
    _fake_installed
    run is_installed
    assert_success
}

# ── Sidecar (ADR-0001) ───────────────────────────────────────────────────────

@test "module_sidecar_write / get_version / remove roundtrip" {
    _load_module
    module_sidecar_write "zoxide" "1.2.3"
    [[ "$(module_sidecar_get_version "zoxide")" == "1.2.3" ]]
    module_sidecar_remove "zoxide"
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/zoxide" ]]
    run module_sidecar_get_version "zoxide"
    assert_failure
}

@test "module_sidecar_write is a no-op under dry-run" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true module_sidecar_write "zoxide" "1.2.3"
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/zoxide" ]]
}

@test "install writes the sidecar with the resolved version" {
    _load_module
    _zoxide_resolve_asset_pattern() { ZOXIDE_RESOLVED_VERSION="9.9.9"; }
    _zoxide_resolve_asset_pattern
    module_default_github_release_install() { :; }
    module_default_github_release_install
    run install
    assert_success
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/zoxide")" == "9.9.9" ]]
}

@test "remove deletes the sidecar" {
    _load_module
    module_sidecar_write "zoxide" "1.0.0"
    module_default_github_release_remove() { :; }
    module_default_github_release_remove
    run remove
    assert_success
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/zoxide" ]]
}

@test "purge deletes the sidecar and cleans shell rc lines" {
    _load_module
    module_sidecar_write "zoxide" "1.0.0"
    printf '# keep me\n%s\n' "eval \"\$(zoxide init bash)\"" > "${HOME}/.bashrc"
    module_default_github_release_purge() { :; }
    module_default_github_release_purge
    run purge
    assert_success
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/zoxide" ]]
    run grep -F "zoxide init" "${HOME}/.bashrc"
    assert_failure
    run grep -F "# keep me" "${HOME}/.bashrc"
    assert_success
}

# ── Shell-rc init (module-specific: cd alternative wiring) ──────────────────

@test "shell init appends zoxide init + cd alias to an existing .bashrc" {
    _load_module
    printf '# my bashrc\n' > "${HOME}/.bashrc"
    _zoxide_shell_init
    run grep -Fc "eval \"\$(zoxide init bash)\"" "${HOME}/.bashrc"
    assert_output "1"
    run grep -Fc "alias cd='z'" "${HOME}/.bashrc"
    assert_output "1"
}

@test "shell init is idempotent (no duplicate lines on second run)" {
    _load_module
    printf '# my bashrc\n' > "${HOME}/.bashrc"
    _zoxide_shell_init
    _zoxide_shell_init
    run grep -Fc "eval \"\$(zoxide init bash)\"" "${HOME}/.bashrc"
    assert_output "1"
}

@test "shell init skips shells without an rc file" {
    _load_module
    # No .bashrc / .zshrc in sandbox HOME — must not create them.
    _zoxide_shell_init
    [[ ! -e "${HOME}/.bashrc" ]]
    [[ ! -e "${HOME}/.zshrc" ]]
}

@test "shell rc cleanup removes only zoxide-managed lines" {
    _load_module
    {
        printf '# top\n'
        printf '%s\n' "eval \"\$(zoxide init bash)\""
        printf "command -v z &>/dev/null && alias cd='z'\n"
        printf '# bottom\n'
    } > "${HOME}/.bashrc"
    _zoxide_shell_rc_cleanup
    run cat "${HOME}/.bashrc"
    assert_line "# top"
    assert_line "# bottom"
    run grep -F "zoxide" "${HOME}/.bashrc"
    assert_failure
}

# ── detect / is_recommended / is_outdated / doctor ───────────────────────────

@test "detect succeeds on the current (x86_64/aarch64) test arch" {
    _load_module
    run detect
    assert_success
}

@test "detect fails on an unsupported architecture" {
    _load_module
    uname() { printf 'riscv64\n'; }
    [[ "$(uname -m)" == "riscv64" ]]
    run detect
    assert_failure
}

@test "is_recommended is yes when absent, no when installed" {
    _load_module
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/no/such/zoxide"
    run is_recommended
    assert_success
    _fake_installed
    run is_recommended
    assert_failure
}

@test "is_outdated returns 1 when not installed (no network probe)" {
    _load_module
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/no/such/zoxide"
    run is_outdated
    assert_failure
}

@test "is_outdated returns 0 when sidecar version differs from latest" {
    _load_module
    _fake_installed
    module_sidecar_write "zoxide" "1.0.0"
    get_github_pkg_latest_version() {
        local -n _gv_out="$1"
        _gv_out="9.9.9"
    }
    local _probe=""
    get_github_pkg_latest_version _probe "ajeetdsouza/zoxide"
    [[ "${_probe}" == "9.9.9" ]]
    run is_outdated
    assert_success
}

@test "is_outdated returns 1 when sidecar matches latest" {
    _load_module
    _fake_installed
    module_sidecar_write "zoxide" "9.9.9"
    get_github_pkg_latest_version() {
        local -n _gv_out="$1"
        _gv_out="9.9.9"
    }
    local _probe=""
    get_github_pkg_latest_version _probe "ajeetdsouza/zoxide"
    [[ "${_probe}" == "9.9.9" ]]
    run is_outdated
    assert_failure
}

@test "doctor returns 1 when zoxide is not installed" {
    _load_module
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/no/such/zoxide"
    run doctor
    assert_failure
}

@test "doctor heals a missing sidecar when zoxide is installed" {
    _load_module
    _fake_installed
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}"
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/zoxide" ]]
    run doctor
    assert_success
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/zoxide" ]]
}

# ── Standalone CLI ───────────────────────────────────────────────────────────

@test "standalone --help exits 0 and prints usage" {
    run bash "${MODULE_DIR}/zoxide.module.sh" --help
    assert_success
    assert_output --partial "Usage: bash module/zoxide.module.sh"
}

@test "standalone --version prints module name" {
    run bash "${MODULE_DIR}/zoxide.module.sh" --version
    assert_success
    assert_output --partial "zoxide"
}

@test "standalone info prints metadata" {
    run bash "${MODULE_DIR}/zoxide.module.sh" info
    assert_success
    assert_output --partial "name:        zoxide"
    assert_output --partial "category:    optional"
    assert_output --partial "cli-essentials"
}

@test "standalone status reports installed: no in a clean container" {
    run bash "${MODULE_DIR}/zoxide.module.sh" status
    assert_success
    assert_output --partial "installed:   no"
}

@test "standalone unknown argument exits 2" {
    run bash "${MODULE_DIR}/zoxide.module.sh" frobnicate
    [[ "${status}" -eq 2 ]]
}

@test "standalone install --dry-run exits 0 and writes nothing" {
    run bash "${MODULE_DIR}/zoxide.module.sh" install --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/zoxide" ]]
}

@test "AC-25: mutating phases run standalone with --dry-run, exit 0" {
    local _phase
    for _phase in install upgrade remove purge verify doctor; do
        run bash "${MODULE_DIR}/zoxide.module.sh" "${_phase}" --dry-run
        if [[ "${status}" -ne 0 ]]; then
            printf 'phase %s exited %s\noutput: %s\n' \
                "${_phase}" "${status}" "${output}" >&2
            return 1
        fi
    done
}

@test "AC-25: query phases run standalone, never 'not implemented' exit 2" {
    local _phase
    for _phase in detect is-installed is-recommended is-outdated; do
        run bash "${MODULE_DIR}/zoxide.module.sh" "${_phase}"
        if [[ "${status}" -ge 2 ]]; then
            printf 'phase %s exited %s\noutput: %s\n' \
                "${_phase}" "${status}" "${output}" >&2
            return 1
        fi
    done
}
