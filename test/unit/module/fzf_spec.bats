#!/usr/bin/env bats
# shellcheck disable=SC2317  # mocks defined inside @test blocks (e.g. `is_installed() { return 0; }`) are dispatched indirectly via the module under test or `run` — https://www.shellcheck.net/wiki/SC2317
# test/unit/module/fzf_spec.bats — module/fzf.module.sh
#
# Per Q29: smoke / metadata / lifecycle dry-run / no-side-fx / idempotency /
# standalone CLI / module-specific (arch mapping, sidecar lifecycle ADR-0001).

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
    # shellcheck source=../../../module/fzf.module.sh
    source "${MODULE_DIR}/fzf.module.sh"
}

# _standalone_module runs the module as a self-contained CLI (the same
# entry users hit when they type `bash module/fzf.module.sh ...`).
_standalone_module() {
    bash "${MODULE_DIR}/fzf.module.sh" "$@"
}

# Stub a successful release fetch: records the resolved version without
# touching the network or the filesystem.
_mock_fetch_ok() {
    # Mirror production: the fetch helper publishes the resolved tag via
    # MODULE_GH_RESOLVED_VERSION, which the phase-invocation wrapper reads to
    # write the Sidecar. eval so the assignment isn't flagged SC2034.
    eval '_fzf_fetch_and_install() { MODULE_GH_RESOLVED_VERSION="9.9.9"; return 0; }'
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "fzf module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/fzf.module.sh"
    assert_success
}

@test "fzf module sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "fzf module defines all 10 lifecycle functions" {
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

@test "fzf module declares NAME=fzf" {
    _load_module
    [[ "${NAME}" == "fzf" ]]
}

@test "fzf module CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "fzf module TAGS contains cli-essentials" {
    _load_module
    [[ " ${TAGS[*]} " == *" cli-essentials "* ]]
}

@test "fzf module declares curl as a dependency" {
    _load_module
    [[ " ${DEPENDS_ON[*]} " == *" curl "* ]]
}

@test "fzf DEPENDS_ON entries are module names only (Q39)" {
    _load_module
    local _dep
    for _dep in "${DEPENDS_ON[@]}"; do
        [[ -f "${MODULE_DIR}/${_dep}.module.sh" ]] || {
            printf 'DEPENDS_ON entry is not a module name: %s\n' "${_dep}" >&2
            return 1
        }
    done
}

@test "fzf DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "fzf module_get_description returns language-specific text" {
    _load_module
    [[ "$(module_get_description en)" == *"fuzzy finder"* ]]
    [[ -n "$(module_get_description zh-TW)" ]]
    # Unknown language falls back to en.
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "fzf SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "fzf module RISK_LEVEL=low" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
}

@test "fzf module VERSION_PROVIDED=latest" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "latest" ]]
}

@test "fzf HOMEPAGE points at upstream junegunn/fzf" {
    _load_module
    [[ "${HOMEPAGE}" == *"junegunn/fzf"* ]]
}

@test "fzf archetype data targets junegunn/fzf release binary" {
    _load_module
    [[ "${GITHUB_REPO}" == "junegunn/fzf" ]]
    [[ "${BIN_NAME}" == "fzf" ]]
    [[ -n "${INSTALL_DIR}" ]]
    [[ -n "${BIN_LINK}" ]]
}

# ── Arch mapping (module-specific) ───────────────────────────────────────────

@test "_fzf_arch maps x86_64 to amd64" {
    _load_module
    uname() { printf 'x86_64'; }
    run _fzf_arch
    assert_success
    assert_output "amd64"
}

@test "_fzf_arch maps aarch64 to arm64" {
    _load_module
    uname() { printf 'aarch64'; }
    run _fzf_arch
    assert_success
    assert_output "arm64"
}

@test "_fzf_arch maps armv7l to armv7" {
    _load_module
    uname() { printf 'armv7l'; }
    run _fzf_arch
    assert_success
    assert_output "armv7"
}

@test "_fzf_arch fails on unsupported architecture" {
    _load_module
    uname() { printf 's390x'; }
    run _fzf_arch
    assert_failure
}

@test "detect succeeds on a supported architecture" {
    _load_module
    uname() { printf 'x86_64'; }
    run detect
    assert_success
}

@test "detect fails on an unsupported architecture" {
    _load_module
    uname() { printf 'mips'; }
    run detect
    assert_failure
}

# ── is_installed ─────────────────────────────────────────────────────────────

@test "is_installed returns nonzero on a fresh test container" {
    _load_module
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/no-such-fzf"
    BIN_NAME="definitely-not-a-real-binary-fzf"
    run is_installed
    assert_failure
}

@test "is_installed returns zero when BIN_LINK is an executable" {
    _load_module
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/fzf"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${BIN_LINK}"
    chmod +x "${BIN_LINK}"
    run is_installed
    assert_success
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
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/fzf" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "dry-run remove leaves an existing sidecar in place" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/fzf"
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/fzf" ]]
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

@test "install writes the sidecar with the resolved version" {
    _load_module
    _mock_fetch_ok
    is_installed() { return 1; }
    module_standalone_main install
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/fzf" ]]
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/fzf")" == "9.9.9" ]]
}

@test "install never touches state.json (ADR-0001 / AC-23 pattern)" {
    _load_module
    printf '{"schema_version":"0.1.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    _mock_fetch_ok
    is_installed() { return 1; }
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "failed fetch leaves no sidecar behind (ADR-0015)" {
    _load_module
    _fzf_fetch_and_install() { return 1; }
    is_installed() { return 1; }
    run module_standalone_main install
    assert_failure
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/fzf" ]]
}

@test "upgrade refreshes the sidecar version" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/fzf"
    _mock_fetch_ok
    module_standalone_main upgrade
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/fzf")" == "9.9.9" ]]
}

@test "remove deletes the sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/fzf"
    module_default_github_release_remove() { return 0; }
    module_standalone_main remove
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/fzf" ]]
}

@test "purge deletes the sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/fzf"
    module_default_github_release_purge() { return 0; }
    module_standalone_main purge
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/fzf" ]]
}

# ── Real remove/purge against a scratch prefix (no sudo) ────────────────────

@test "remove deletes INSTALL_DIR and BIN_LINK when USE_SUDO=false" {
    _load_module
    USE_SUDO=false
    INSTALL_DIR="${INIT_UBUNTU_TEST_SCRATCH}/opt/fzf"
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/bin/fzf"
    mkdir -p "${INSTALL_DIR}" "${BIN_LINK%/*}"
    printf 'bin\n' > "${INSTALL_DIR}/fzf"
    ln -s "${INSTALL_DIR}/fzf" "${BIN_LINK}"
    remove
    [[ ! -e "${INSTALL_DIR}" ]]
    [[ ! -e "${BIN_LINK}" ]]
}

@test "remove is idempotent — second run still exits 0" {
    _load_module
    USE_SUDO=false
    INSTALL_DIR="${INIT_UBUNTU_TEST_SCRATCH}/opt/fzf"
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/bin/fzf"
    run remove
    assert_success
    run remove
    assert_success
}

@test "purge clears CONFIG_PATHS in addition to the binary" {
    _load_module
    USE_SUDO=false
    INSTALL_DIR="${INIT_UBUNTU_TEST_SCRATCH}/opt/fzf"
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/bin/fzf"
    CONFIG_PATHS=("${INIT_UBUNTU_TEST_SCRATCH}/dot-fzf")
    mkdir -p "${INSTALL_DIR}" "${CONFIG_PATHS[0]}"
    purge
    [[ ! -e "${INSTALL_DIR}" ]]
    [[ ! -e "${CONFIG_PATHS[0]}" ]]
}

# ── Idempotency (AC-5 pattern) ───────────────────────────────────────────────

@test "install short-circuits when is_installed returns 0 (idempotency)" {
    _load_module
    is_installed() { return 0; }
    run install
    assert_success
    assert_output --partial "already installed"
}

@test "install twice with fetch mocked exits 0 both times" {
    _load_module
    _mock_fetch_ok
    is_installed() { return 1; }
    run install
    assert_success
    # Second run: simulate the binary now being present.
    is_installed() { return 0; }
    run install
    assert_success
}

# ── verify / doctor / is_outdated ────────────────────────────────────────────

@test "verify fails when not installed" {
    _load_module
    is_installed() { return 1; }
    run verify
    assert_failure
}

@test "verify passes when installed and TEST_VERIFY_CMD succeeds" {
    _load_module
    is_installed() { return 0; }
    TEST_VERIFY_CMD="true"
    run verify
    assert_success
}

@test "doctor fails when not installed" {
    _load_module
    is_installed() { return 1; }
    run doctor
    assert_failure
}

@test "doctor passes when the linked binary answers --version" {
    _load_module
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/fzf"
    printf '#!/usr/bin/env bash\nprintf "0.0.1\\n"\n' > "${BIN_LINK}"
    chmod +x "${BIN_LINK}"
    run doctor
    assert_success
}

@test "is_outdated returns nonzero when no sidecar exists" {
    _load_module
    run is_outdated
    assert_failure
}

@test "is_outdated returns zero when sidecar version differs from latest" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '0.1.0' > "${INIT_UBUNTU_STATE_DIR}/versions/fzf"
    get_github_pkg_latest_version() {
        local -n _o="${1}"
        _o="9.9.9"
    }
    run is_outdated
    assert_success
}

@test "is_outdated returns nonzero when sidecar matches latest" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '9.9.9' > "${INIT_UBUNTU_STATE_DIR}/versions/fzf"
    get_github_pkg_latest_version() {
        local -n _o="${1}"
        _o="9.9.9"
    }
    run is_outdated
    assert_failure
}

# ── is_recommended ───────────────────────────────────────────────────────────

@test "is_recommended is nonzero when already installed" {
    _load_module
    is_installed() { return 0; }
    run is_recommended
    assert_failure
}

@test "is_recommended is zero when not installed" {
    _load_module
    is_installed() { return 1; }
    run is_recommended
    assert_success
}

# ── Dual-mode standalone CLI ─────────────────────────────────────────────────

@test "standalone: with no args prints usage + exits 2" {
    run _standalone_module
    assert_failure 2
    assert_output --partial "Usage:"
}

@test "standalone: --help shows phases" {
    run _standalone_module --help
    assert_success
    assert_output --partial "install"
    assert_output --partial "remove"
    assert_output --partial "purge"
}

@test "standalone: --version prints NAME + VERSION_PROVIDED" {
    run _standalone_module --version
    assert_success
    assert_output --partial "fzf"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module nope
    assert_failure 2
}

@test "standalone: info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        fzf"
    assert_output --partial "category:    optional"
    assert_output --partial "cli-essentials"
    assert_output --partial "curl"
}

@test "standalone: info --lang=zh-TW prints localized description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "模糊搜尋"
}

@test "standalone: status reports installed + outdated fields" {
    run _standalone_module status
    assert_success
    assert_output --partial "installed:"
    assert_output --partial "outdated:"
}

# ── AC-25: all 10 phases runnable, never "not implemented" exit 2 ────────────

@test "standalone: install --dry-run exits 0 with DRY-RUN output" {
    run _standalone_module install --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "standalone: upgrade --dry-run exits 0" {
    run _standalone_module upgrade --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "standalone: remove --dry-run exits 0" {
    run _standalone_module remove --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "standalone: purge --dry-run exits 0" {
    run _standalone_module purge --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "standalone: verify --dry-run exits 0" {
    run _standalone_module verify --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "standalone: detect is implemented (exit != 2)" {
    run _standalone_module detect
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: is-installed is implemented (exit != 2)" {
    run _standalone_module is-installed
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: is-recommended is implemented (exit != 2)" {
    run _standalone_module is-recommended
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: is-outdated is implemented (exit != 2)" {
    run _standalone_module is-outdated
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: doctor is implemented (exit != 2)" {
    run _standalone_module doctor
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}
