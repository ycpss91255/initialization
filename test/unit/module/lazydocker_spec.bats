#!/usr/bin/env bats
# test/unit/module/lazydocker_spec.bats — module/lazydocker.module.sh

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
    # shellcheck source=../../../module/lazydocker.module.sh
    source "${MODULE_DIR}/lazydocker.module.sh"
}

# _standalone_module runs the module as a self-contained CLI (the same
# entry users hit when they type `bash module/lazydocker.module.sh ...`).
_standalone_module() {
    bash "${MODULE_DIR}/lazydocker.module.sh" "$@"
}

_sidecar_file() {
    printf '%s/versions/lazydocker' "${INIT_UBUNTU_STATE_DIR}"
}

# Mock helpers (top-level so indirect dispatch is visible to shellcheck).
_mock_installed()     { eval 'is_installed() { return 0; }'; }
_mock_not_installed() { eval 'is_installed() { return 1; }'; }
_mock_fetch_ok()      { eval '_lazydocker_fetch_and_install() { LAZYDOCKER_RESOLVED_VERSION="9.9.9"; MODULE_GH_RESOLVED_VERSION="9.9.9"; }'; }
_mock_fetch_fail()    { eval '_lazydocker_fetch_and_install() { return 1; }'; }
_mock_latest_2_0_0()  { eval 'get_github_pkg_latest_version() { local -n _out="${1}"; _out="2.0.0"; }'; }
_mock_docker_cli()    { eval 'docker() { return 0; }'; }
_mock_lazydocker_ok() { eval 'lazydocker() { return 0; }'; }
_mock_uname_m()       { eval "uname() { [[ \"\${1:-}\" == \"-m\" ]] && { printf '%s' \"${1}\"; return 0; }; command uname \"\$@\"; }"; }

# ── Metadata sanity ──────────────────────────────────────────────────────────

@test "lazydocker module declares NAME=lazydocker" {
    _load_module
    [[ "${NAME}" == "lazydocker" ]]
}

@test "lazydocker module CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "lazydocker module TAGS contains cli-essentials" {
    _load_module
    [[ " ${TAGS[*]} " == *" cli-essentials "* ]]
}

@test "lazydocker DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    # Must be associative — `declare -A` (possibly with -g flag).
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "$(module_get_description en)" ]]
    [[ -n "$(module_get_description zh-TW)" ]]
}

@test "lazydocker module declares docker as its only dependency (Q39: module names only)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 1 ]]
    [[ "${DEPENDS_ON[0]}" == "docker" ]]
}

@test "lazydocker module SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "lazydocker module RISK_LEVEL=low and REBOOT_REQUIRED=false" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
    [[ "${REBOOT_REQUIRED}" == "false" ]]
}

@test "lazydocker module points at jesseduffield/lazydocker" {
    _load_module
    [[ "${GITHUB_REPO}" == "jesseduffield/lazydocker" ]]
    [[ "${BIN_NAME}" == "lazydocker" ]]
}

@test "lazydocker module is discovered by the registry with tag cli-essentials" {
    _load_module
    # shellcheck source=../../../lib/registry.sh
    source "${LIB_DIR}/registry.sh"
    registry_load_all "${MODULE_DIR}"
    registry_has "lazydocker"
    local _names; _names="$(registry_list_names --tag=cli-essentials)"
    [[ " ${_names//$'\n'/ } " == *" lazydocker "* ]]
}

# ── All 10 lifecycle functions defined (AC-25, ADR-0002) ────────────────────

@test "lazydocker defines all 10 lifecycle functions" {
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

# ── is_installed: clean container ────────────────────────────────────────────

@test "is_installed returns nonzero on a fresh test container" {
    _load_module
    run is_installed
    assert_failure
}

# ── Dry-run no-ops (AC-12 pattern) ───────────────────────────────────────────

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

@test "install in dry-run mode writes no sidecar (no filesystem writes)" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ ! -e "$(_sidecar_file)" ]]
}

# ── Idempotency (AC-5 pattern) ───────────────────────────────────────────────

@test "install short-circuits when is_installed returns 0 (idempotency)" {
    _load_module
    _mock_installed
    run install
    assert_success
    assert_output --partial "already installed"
}

@test "remove is a safe no-op when not installed (idempotency)" {
    _load_module
    _mock_not_installed
    run remove
    assert_success
    assert_output --partial "nothing to do"
}

# ── Sidecar behavior (ADR-0001) ──────────────────────────────────────────────

@test "install writes the sidecar on success" {
    _load_module
    _mock_not_installed
    _mock_fetch_ok
    module_standalone_main install
    [[ -f "$(_sidecar_file)" ]]
    [[ "$(cat "$(_sidecar_file)")" == "9.9.9" ]]
}

@test "upgrade refreshes the sidecar on success" {
    _load_module
    _mock_fetch_ok
    module_standalone_main upgrade
    [[ "$(cat "$(_sidecar_file)")" == "9.9.9" ]]
}

@test "install does not write the sidecar when the fetch fails" {
    _load_module
    _mock_not_installed
    _mock_fetch_fail
    run module_standalone_main install
    assert_failure
    [[ ! -e "$(_sidecar_file)" ]]
}

@test "remove deletes the sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "$(_sidecar_file)"
    _mock_installed
    eval 'module_default_github_release_remove() { return 0; }'
    module_standalone_main remove
    [[ ! -e "$(_sidecar_file)" ]]
}

@test "purge deletes the sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "$(_sidecar_file)"
    eval 'module_default_github_release_purge() { return 0; }'
    module_standalone_main purge
    [[ ! -e "$(_sidecar_file)" ]]
}

@test "standalone lifecycle never touches state.json (AC-23 pattern)" {
    _load_module
    _mock_not_installed
    _mock_fetch_ok
    module_standalone_main install
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

# ── is_outdated / doctor ─────────────────────────────────────────────────────

@test "is_outdated returns nonzero when not installed (no network call)" {
    _load_module
    _mock_not_installed
    run is_outdated
    assert_failure
}

@test "is_outdated returns 0 when sidecar version differs from latest" {
    _load_module
    _mock_installed
    _mock_latest_2_0_0
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "$(_sidecar_file)"
    run is_outdated
    assert_success
}

@test "is_outdated returns nonzero when sidecar matches latest" {
    _load_module
    _mock_installed
    _mock_latest_2_0_0
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '2.0.0\n' > "$(_sidecar_file)"
    run is_outdated
    assert_failure
}

@test "doctor fails with a hint when lazydocker is not installed" {
    _load_module
    _mock_not_installed
    run doctor
    assert_failure
    assert_output --partial "not installed"
}

@test "doctor warns when docker CLI is missing" {
    _load_module
    _mock_installed
    _mock_lazydocker_ok
    run doctor
    if command -v docker >/dev/null 2>&1; then
        assert_success
    else
        assert_failure
        assert_output --partial "docker"
    fi
}

# ── Recommendation logic ─────────────────────────────────────────────────────

@test "is_recommended returns nonzero when already installed" {
    _load_module
    _mock_installed
    run is_recommended
    assert_failure
}

@test "is_recommended returns 0 when docker present and lazydocker absent" {
    _load_module
    _mock_not_installed
    _mock_docker_cli
    run is_recommended
    assert_success
}

@test "is_recommended returns nonzero when docker is absent" {
    _load_module
    _mock_not_installed
    if command -v docker >/dev/null 2>&1; then
        skip "docker binary present in test image"
    fi
    run is_recommended
    assert_failure
}

# ── detect / arch mapping ────────────────────────────────────────────────────

@test "detect succeeds on a supported Linux architecture" {
    _load_module
    run detect
    assert_success
}

@test "_lazydocker_asset_arch maps x86_64 -> x86_64" {
    _load_module
    _mock_uname_m "x86_64"
    [[ "$(_lazydocker_asset_arch)" == "x86_64" ]]
}

@test "_lazydocker_asset_arch maps aarch64 -> arm64" {
    _load_module
    _mock_uname_m "aarch64"
    [[ "$(_lazydocker_asset_arch)" == "arm64" ]]
}

@test "_lazydocker_asset_arch rejects unknown architectures" {
    _load_module
    _mock_uname_m "s390x"
    run _lazydocker_asset_arch
    assert_failure
}

# ── Dual-mode standalone CLI (AC-25) ─────────────────────────────────────────

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

@test "standalone: all 10 lifecycle phases never exit 2 'not implemented' (AC-25)" {
    local _phase
    for _phase in detect is-recommended is-installed install upgrade \
                  remove purge verify is-outdated doctor; do
        run _standalone_module "${_phase}" --dry-run
        if [[ "${status}" -eq 2 ]]; then
            printf 'phase %s exited 2 (not implemented?): %s\n' \
                "${_phase}" "${output}" >&2
            return 1
        fi
    done
}

@test "standalone: dry-run phases leave the state dir untouched (no side effects)" {
    local _phase
    for _phase in install upgrade remove purge verify; do
        run _standalone_module "${_phase}" --dry-run
        assert_success
    done
    [[ ! -e "$(_sidecar_file)" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "standalone: info prints metadata including tags + dependency" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        lazydocker"
    assert_output --partial "cli-essentials"
    assert_output --partial "docker"
}

@test "standalone: status reports installed=no on a clean container" {
    run _standalone_module status
    assert_success
    assert_output --partial "installed:   no"
}

@test "standalone: --version prints NAME + VERSION_PROVIDED" {
    run _standalone_module --version
    assert_success
    assert_output --partial "lazydocker"
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

@test "standalone: --lang=zh-TW info prints the zh-TW description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "Docker"
}
