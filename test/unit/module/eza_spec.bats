#!/usr/bin/env bats
# shellcheck disable=SC2317  # mocks defined inside @test blocks (e.g. `is_installed() { return 0; }`) are dispatched indirectly via the module under test or `run` — https://www.shellcheck.net/wiki/SC2317
# test/unit/module/eza_spec.bats — module/eza.module.sh (issue #51)
#
# Covers (Q29): smoke / metadata / lifecycle dry-run / no-side-fx /
# idempotency / Sidecar (ADR-0001) / standalone CLI (AC-25).

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
    # shellcheck source=../../../module/eza.module.sh
    source "${MODULE_DIR}/eza.module.sh"
}

# Point every mutable path at the per-test scratch dir, neutralize sudo,
# and stub the network fetch so install()/upgrade() run for real (alias +
# Sidecar) without downloading anything.
_sandbox_module() {
    HOME="${TEST_HOME}"
    INSTALL_DIR="${INIT_UBUNTU_TEST_SCRATCH}/opt/eza"
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/bin/eza"
    USE_SUDO=false
    _module_github_release_fetch_and_install() {
        mkdir -p "${INSTALL_DIR}" "${BIN_LINK%/*}"
        printf '#!/bin/sh\necho "eza - test stub"\n' > "${INSTALL_DIR}/eza"
        chmod +x "${INSTALL_DIR}/eza"
        ln -sfn "${INSTALL_DIR}/eza" "${BIN_LINK}"
    }
}

_standalone_module() {
    bash "${MODULE_DIR}/eza.module.sh" "$@"
}

_sidecar_path() {
    printf '%s/versions/eza' "${INIT_UBUNTU_STATE_DIR}"
}

# ── Smoke: contract shape ────────────────────────────────────────────────────

@test "eza module defines all 10 lifecycle functions" {
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

# ── Metadata sanity ──────────────────────────────────────────────────────────

@test "eza module declares NAME=eza" {
    _load_module
    [[ "${NAME}" == "eza" ]]
}

@test "eza module CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "eza module TAGS[0]=cli-essentials" {
    _load_module
    [[ "${TAGS[0]}" == "cli-essentials" ]]
}

@test "eza module DEPENDS_ON is empty (Q39: module names only)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 0 ]]
}

@test "eza DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "$(module_get_description en)" ]]
    [[ -n "$(module_get_description zh-TW)" ]]
}

@test "eza module SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "eza archetype data points at eza-community/eza" {
    _load_module
    [[ "${GITHUB_REPO}" == "eza-community/eza" ]]
    [[ "${BIN_NAME}" == "eza" ]]
    [[ -n "${GITHUB_ASSET_PATTERN}" ]]
}

@test "eza module RISK_LEVEL=low" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
}

# ── is_installed ─────────────────────────────────────────────────────────────

@test "is_installed returns nonzero on a fresh test container" {
    _load_module
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/no/such/eza"
    run is_installed
    assert_failure
}

@test "is_installed returns 0 when BIN_LINK is an executable" {
    _load_module
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/bin/eza"
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

@test "detect returns nonzero on aarch64 (no prebuilt gnu tarball wired)" {
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
    [[ "$(grep -cF "alias ls='eza'" "${TEST_HOME}/.bashrc")" -eq 1 ]]
}

@test "remove is idempotent: second run still exits 0" {
    _load_module
    _sandbox_module
    install
    remove
    run remove
    assert_success
}

# ── Alias drop (legacy module/submodule/eza.sh behavior) ─────────────────────

@test "install appends ls alias to an existing ~/.bashrc" {
    _load_module
    _sandbox_module
    printf '# rc\n' > "${TEST_HOME}/.bashrc"
    run install
    assert_success
    grep -qF "alias ls='eza'" "${TEST_HOME}/.bashrc"
}

@test "install appends ls alias to an existing ~/.zshrc too" {
    _load_module
    _sandbox_module
    printf '# rc\n' > "${TEST_HOME}/.zshrc"
    run install
    assert_success
    grep -qF "alias ls='eza'" "${TEST_HOME}/.zshrc"
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
    grep -qF "alias ls='eza'" "${TEST_HOME}/.bashrc"
    purge
    run ! grep -qF "alias ls='eza'" "${TEST_HOME}/.bashrc"
}

# ── Sidecar (ADR-0001) ───────────────────────────────────────────────────────

@test "install writes the Sidecar under \${INIT_UBUNTU_STATE_DIR}/versions/" {
    _load_module
    _sandbox_module
    run module_standalone_main install
    assert_success
    [[ -f "$(_sidecar_path)" ]]
}

@test "upgrade (re)writes the Sidecar" {
    _load_module
    _sandbox_module
    run module_standalone_main upgrade
    assert_success
    [[ -f "$(_sidecar_path)" ]]
}

@test "remove deletes the Sidecar" {
    _load_module
    _sandbox_module
    module_standalone_main install
    [[ -f "$(_sidecar_path)" ]]
    module_standalone_main remove
    [[ ! -e "$(_sidecar_path)" ]]
}

@test "purge deletes the Sidecar" {
    _load_module
    _sandbox_module
    module_standalone_main install
    module_standalone_main purge
    [[ ! -e "$(_sidecar_path)" ]]
}

@test "install never touches state.json (AC-23 pattern, ADR-0001)" {
    _load_module
    _sandbox_module
    printf '{"version":"0.1.0","installed":{}}\n' > "${INIT_UBUNTU_STATE_DIR}/state.json"
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == '{"version":"0.1.0","installed":{}}' ]]
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

@test "doctor returns nonzero when eza is not installed" {
    _load_module
    is_installed() { return 1; }
    run doctor
    assert_failure
}

@test "doctor passes and warns (read-only) when the Sidecar is missing" {
    # Sidecar is now written at the phase-invocation layer (refines ADR-0001),
    # so doctor is read-only: it warns about a missing Sidecar but does NOT
    # heal it (re-run install/upgrade to heal).
    _load_module
    is_installed() { return 0; }
    eza() { printf 'eza - A modern replacement for ls\nv0.18.0\n'; }
    [[ ! -e "$(_sidecar_path)" ]]
    run doctor
    assert_success
    assert_output --partial "Sidecar missing"
    [[ ! -e "$(_sidecar_path)" ]]
}

# ── Standalone CLI (dual-mode footer) ────────────────────────────────────────

@test "standalone: with no args prints usage + exits 2" {
    run _standalone_module
    assert_failure 2
    assert_output --partial "Usage:"
}

@test "standalone: install --dry-run prints DRY-RUN + exits 0" {
    run _standalone_module install --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "standalone: --version prints NAME + VERSION_PROVIDED" {
    run _standalone_module --version
    assert_success
    assert_output --partial "eza"
}

@test "standalone: --help shows phases" {
    run _standalone_module --help
    assert_success
    assert_output --partial "install"
    assert_output --partial "remove"
    assert_output --partial "purge"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module nope
    assert_failure 2
}

@test "standalone: info prints metadata (name / category / tags)" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        eza"
    assert_output --partial "category:    optional"
    assert_output --partial "cli-essentials"
}

@test "standalone: status reports installed=no on a fresh container" {
    HOME="${TEST_HOME}" run _standalone_module status
    assert_success
    assert_output --partial "installed:   no"
}

@test "standalone: all 10 lifecycle phases run without 'not implemented' exit 2 (AC-25)" {
    local _phase _rc
    for _phase in install upgrade remove purge verify doctor detect \
                  is-installed is-recommended is-outdated; do
        _rc=0
        HOME="${TEST_HOME}" run _standalone_module "${_phase}" --dry-run
        _rc="${status}"
        if [[ "${_rc}" -eq 2 ]] || [[ "${output}" == *"not implemented"* ]]; then
            printf "phase %s hit not-implemented (rc=%s)\noutput: %s\n" \
                "${_phase}" "${_rc}" "${output}" >&2
            return 1
        fi
    done
}

@test "standalone: dry-run install leaves state.json untouched (AC-23)" {
    printf '{"version":"0.1.0","installed":{}}\n' > "${INIT_UBUNTU_STATE_DIR}/state.json"
    run _standalone_module install --dry-run
    assert_success
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == '{"version":"0.1.0","installed":{}}' ]]
}
