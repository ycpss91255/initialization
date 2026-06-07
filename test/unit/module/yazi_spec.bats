#!/usr/bin/env bats
# test/unit/module/yazi_spec.bats — module/yazi.module.sh (issue #60)
#
# Covers (Q29): smoke / metadata / lifecycle dry-run / no-side-fx /
# idempotency / Sidecar (ADR-0001) / standalone CLI (AC-25) / registry
# discovery / legacy #1 alias regression (alias must target yazi, not cat).

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    # Sandbox HOME so alias writes never touch the container user's rc files.
    TEST_HOME="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${TEST_HOME}"
    export TEST_HOME
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
    # shellcheck source=../../../module/yazi.module.sh
    source "${MODULE_DIR}/yazi.module.sh"
}

# ── Smoke: contract shape ────────────────────────────────────────────────────

@test "yazi module defines all 10 lifecycle functions" {
    _load_module
    local _fn
    for _fn in detect is_recommended is_installed install upgrade \
               remove purge verify is_outdated doctor; do
        declare -F "${_fn}" >/dev/null || {
            printf "missing lifecycle fn: %s\n" "${_fn}" >&2
            return 1
        }
    done
}

# ── Metadata sanity (PRD §9.1 / issue #60) ──────────────────────────────────

@test "yazi module declares NAME=yazi" {
    _load_module
    [[ "${NAME}" == "yazi" ]]
}

@test "yazi module CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "yazi module TAGS[0]=filemgr" {
    _load_module
    [[ "${TAGS[0]}" == "filemgr" ]]
}

@test "yazi module DEPENDS_ON is empty (Q39: module names only)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 0 ]]
}

@test "yazi DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "$(module_get_description en)" ]]
    [[ -n "$(module_get_description zh-TW)" ]]
}

@test "yazi POST_INSTALL_MESSAGE has en + zh-TW entries" {
    _load_module
    [[ -n "$(module_get_post_install_message en)" ]]
    [[ -n "$(module_get_post_install_message zh-TW)" ]]
}

@test "yazi module SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "yazi module SUPPORTED_PLATFORMS is non-empty" {
    _load_module
    [[ "${#SUPPORTED_PLATFORMS[@]}" -gt 0 ]]
}

@test "yazi module HOMEPAGE points at sxyazi/yazi" {
    _load_module
    [[ "${HOMEPAGE}" == *"github.com/sxyazi/yazi"* ]]
}

@test "yazi module VERSION_PROVIDED=latest" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "latest" ]]
}

@test "yazi module RISK_LEVEL=low" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
}

@test "yazi module REBOOT_REQUIRED=false" {
    _load_module
    [[ "${REBOOT_REQUIRED}" == "false" ]]
}

@test "yazi module INSTALL_TARGET_DEFAULT=sudo" {
    _load_module
    [[ "${INSTALL_TARGET_DEFAULT}" == "sudo" ]]
}

@test "yazi module SUPPORTS_USER_HOME is a boolean" {
    _load_module
    [[ "${SUPPORTS_USER_HOME}" == "true" || "${SUPPORTS_USER_HOME}" == "false" ]]
}

@test "yazi archetype data points at sxyazi/yazi zip asset" {
    _load_module
    [[ "${GITHUB_REPO}" == "sxyazi/yazi" ]]
    [[ "${BIN_NAME}" == "yazi" ]]
    [[ "${GITHUB_ASSET_PATTERN}" == *".zip" ]]
}

@test "yazi module CONFLICTS_WITH is empty" {
    _load_module
    [[ "${#CONFLICTS_WITH[@]}" -eq 0 ]]
}

# Point every mutable path at the per-test scratch dir, neutralize sudo,
# and stub the zip fetch so install()/upgrade() run for real (alias +
# Sidecar) without downloading anything.
_sandbox_module() {
    HOME="${TEST_HOME}"
    INSTALL_DIR="${INIT_UBUNTU_TEST_SCRATCH}/opt/yazi"
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/bin/yazi"
    USE_SUDO=false
    _yazi_fetch_and_install() {
        mkdir -p "${INSTALL_DIR}" "${BIN_LINK%/*}"
        printf '#!/bin/sh\necho "Yazi 25.5.31 (test stub)"\n' > "${INSTALL_DIR}/yazi"
        chmod +x "${INSTALL_DIR}/yazi"
        ln -sfn "${INSTALL_DIR}/yazi" "${BIN_LINK}"
    }
}

_sidecar_path() {
    printf '%s/versions/yazi' "${INIT_UBUNTU_STATE_DIR}"
}

# ── is_installed ─────────────────────────────────────────────────────────────

@test "is_installed returns nonzero on a fresh test container" {
    _load_module
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/no/such/yazi"
    run is_installed
    assert_failure
}

@test "is_installed returns 0 when BIN_LINK is an executable" {
    _load_module
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/bin/yazi"
    mkdir -p "${BIN_LINK%/*}"
    printf '#!/bin/sh\n' > "${BIN_LINK}"
    chmod +x "${BIN_LINK}"
    run is_installed
    assert_success
}

# ── detect ───────────────────────────────────────────────────────────────────

@test "detect returns 0 on x86_64" {
    _load_module
    uname() { printf 'x86_64\n'; }
    run detect
    assert_success
}

@test "detect returns nonzero on aarch64 (no prebuilt gnu zip wired)" {
    _load_module
    uname() { printf 'aarch64\n'; }
    run detect
    assert_failure
}

# ── Dry-run is a no-op for every Action Phase ────────────────────────────────

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

@test "dry-run install performs zero filesystem writes (AC-12 pattern)" {
    _load_module
    _sandbox_module
    printf '# pristine\n' > "${TEST_HOME}/.bashrc"
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ "$(cat "${TEST_HOME}/.bashrc")" == "# pristine" ]]
    [[ ! -e "$(_sidecar_path)" ]]
    [[ ! -e "${INSTALL_DIR}" ]]
}

@test "dry-run purge leaves rc files and Sidecar in place" {
    _load_module
    _sandbox_module
    printf '# rc\n' > "${TEST_HOME}/.bashrc"
    install
    INIT_UBUNTU_DRY_RUN=true run purge
    assert_success
    [[ -f "$(_sidecar_path)" ]]
    grep -qF "alias yz='yazi'" "${TEST_HOME}/.bashrc"
}

# ── Idempotency (AC-5 pattern) ───────────────────────────────────────────────

@test "install short-circuits when is_installed returns 0 (idempotency)" {
    _load_module
    _sandbox_module
    is_installed() { return 0; }
    run install
    assert_success
    assert_output --partial "already installed"
}

@test "install twice in a row both exit 0 and do not duplicate the alias" {
    _load_module
    _sandbox_module
    printf '# rc\n' > "${TEST_HOME}/.bashrc"
    install
    install
    [[ "$(grep -cF "alias yz='yazi'" "${TEST_HOME}/.bashrc")" -eq 1 ]]
}

@test "upgrade after install does not duplicate the alias" {
    _load_module
    _sandbox_module
    printf '# rc\n' > "${TEST_HOME}/.bashrc"
    install
    upgrade
    [[ "$(grep -cF "alias yz='yazi'" "${TEST_HOME}/.bashrc")" -eq 1 ]]
}

@test "remove is idempotent: second run still exits 0" {
    _load_module
    _sandbox_module
    install
    remove
    run remove
    assert_success
}

@test "purge is idempotent: second run still exits 0" {
    _load_module
    _sandbox_module
    install
    purge
    run purge
    assert_success
}

# ── Alias drop (legacy module/submodule/yazi.sh; #1 copy-paste regression) ───

@test "install appends yz alias to an existing ~/.bashrc" {
    _load_module
    _sandbox_module
    printf '# rc\n' > "${TEST_HOME}/.bashrc"
    run install
    assert_success
    grep -qF "alias yz='yazi'" "${TEST_HOME}/.bashrc"
}

@test "install appends yz alias to an existing ~/.zshrc too" {
    _load_module
    _sandbox_module
    printf '# rc\n' > "${TEST_HOME}/.zshrc"
    run install
    assert_success
    grep -qF "alias yz='yazi'" "${TEST_HOME}/.zshrc"
}

@test "alias is guarded by command -v yazi (no broken alias without binary)" {
    _load_module
    _sandbox_module
    printf '# rc\n' > "${TEST_HOME}/.bashrc"
    install
    grep -qE "command -v yazi.*alias yz='yazi'" "${TEST_HOME}/.bashrc"
}

@test "regression #1: alias targets yazi itself, never cat" {
    _load_module
    _sandbox_module
    printf '# rc\n' > "${TEST_HOME}/.bashrc"
    install
    run grep -F "alias cat=" "${TEST_HOME}/.bashrc"
    assert_failure
}

@test "install succeeds when no rc file exists (alias step skipped)" {
    _load_module
    _sandbox_module
    run install
    assert_success
}

@test "remove keeps the alias (config preserved); purge strips it" {
    _load_module
    _sandbox_module
    printf '# rc\n' > "${TEST_HOME}/.bashrc"
    install
    remove
    grep -qF "alias yz='yazi'" "${TEST_HOME}/.bashrc"
    purge
    run ! grep -qF "alias yz='yazi'" "${TEST_HOME}/.bashrc"
}

@test "purge strips the alias from ~/.zshrc as well" {
    _load_module
    _sandbox_module
    printf '# rc\n' > "${TEST_HOME}/.zshrc"
    install
    purge
    run ! grep -qF "alias yz='yazi'" "${TEST_HOME}/.zshrc"
}

@test "purge keeps unrelated rc lines intact" {
    _load_module
    _sandbox_module
    printf '# keep me\nexport FOO=bar\n' > "${TEST_HOME}/.bashrc"
    install
    purge
    grep -qF "# keep me" "${TEST_HOME}/.bashrc"
    grep -qF "export FOO=bar" "${TEST_HOME}/.bashrc"
}

# ── Sidecar (ADR-0001) ───────────────────────────────────────────────────────

@test "install writes the Sidecar under \${INIT_UBUNTU_STATE_DIR}/versions/" {
    _load_module
    _sandbox_module
    run install
    assert_success
    [[ -f "$(_sidecar_path)" ]]
}

@test "install records the binary-reported version in the Sidecar" {
    _load_module
    _sandbox_module
    install
    [[ "$(cat "$(_sidecar_path)")" == "25.5.31" ]]
}

@test "upgrade (re)writes the Sidecar" {
    _load_module
    _sandbox_module
    run upgrade
    assert_success
    [[ -f "$(_sidecar_path)" ]]
}

@test "remove deletes the Sidecar" {
    _load_module
    _sandbox_module
    install
    [[ -f "$(_sidecar_path)" ]]
    remove
    [[ ! -e "$(_sidecar_path)" ]]
}

@test "purge deletes the Sidecar" {
    _load_module
    _sandbox_module
    install
    purge
    [[ ! -e "$(_sidecar_path)" ]]
}

@test "install never touches state.json (AC-23 pattern, ADR-0001)" {
    _load_module
    _sandbox_module
    printf '{"version":"0.1.0","installed":{}}\n' > "${INIT_UBUNTU_STATE_DIR}/state.json"
    install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == '{"version":"0.1.0","installed":{}}' ]]
}

# ── Zip fetch (upstream ships a ZIP, not a tarball) ──────────────────────────

@test "fetch rejects a download that is not a zip archive" {
    _load_module
    # real _yazi_fetch_and_install, but sandboxed paths + stubbed network
    HOME="${TEST_HOME}"
    INSTALL_DIR="${INIT_UBUNTU_TEST_SCRATCH}/opt/yazi"
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/bin/yazi"
    USE_SUDO=false
    curl() {
        # write garbage to the -o target
        local _out=""
        while [[ $# -gt 0 ]]; do
            [[ "${1}" == "-o" ]] && { _out="${2}"; shift; }
            shift
        done
        printf 'this is not a zip\n' > "${_out}"
    }
    get_github_pkg_latest_version() { local -n _o="${1}"; _o="25.5.31"; }
    run _yazi_fetch_and_install
    assert_failure
    assert_output --partial "not a zip"
    [[ ! -e "${INSTALL_DIR}" ]]
}

@test "fetch fails fast with a clear message when unzip is unavailable" {
    _load_module
    HOME="${TEST_HOME}"
    INSTALL_DIR="${INIT_UBUNTU_TEST_SCRATCH}/opt/yazi"
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/bin/yazi"
    USE_SUDO=false
    command() {
        if [[ "${1:-}" == "-v" && "${2:-}" == "unzip" ]]; then return 1; fi
        builtin command "$@"
    }
    run _yazi_fetch_and_install
    assert_failure
    assert_output --partial "unzip"
}

# ── is_recommended ───────────────────────────────────────────────────────────

@test "is_recommended returns nonzero when already installed" {
    _load_module
    is_installed() { return 0; }
    run is_recommended
    assert_failure
}

@test "is_recommended returns 0 when not installed" {
    _load_module
    is_installed() { return 1; }
    run is_recommended
    assert_success
}

# ── is_outdated ──────────────────────────────────────────────────────────────

@test "is_outdated returns nonzero when no Sidecar exists (no network hit)" {
    _load_module
    get_github_pkg_latest_version() {
        printf 'network must not be queried without a Sidecar\n' >&2
        return 1
    }
    run is_outdated
    assert_failure
    refute_output --partial "network must not be queried"
}

@test "is_outdated returns 0 when Sidecar version differs from latest" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '0.1.0\n' > "$(_sidecar_path)"
    get_github_pkg_latest_version() {
        local -n _out="${1}"
        _out="99.0.0"
    }
    run is_outdated
    assert_success
}

@test "is_outdated returns nonzero when Sidecar matches latest" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '99.0.0\n' > "$(_sidecar_path)"
    get_github_pkg_latest_version() {
        local -n _out="${1}"
        _out="99.0.0"
    }
    run is_outdated
    assert_failure
}

# ── doctor ───────────────────────────────────────────────────────────────────

@test "doctor returns nonzero when yazi is not installed" {
    _load_module
    is_installed() { return 1; }
    run doctor
    assert_failure
}

@test "doctor passes and heals a missing Sidecar when yazi runs" {
    _load_module
    is_installed() { return 0; }
    yazi() { printf 'Yazi 25.5.31 (f5a1cf0 2025-05-31)\n'; }
    [[ ! -e "$(_sidecar_path)" ]]
    run doctor
    assert_success
    [[ -f "$(_sidecar_path)" ]]
}
