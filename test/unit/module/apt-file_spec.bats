#!/usr/bin/env bats
# test/unit/module/apt-file_spec.bats — module/apt-file.module.sh
#
# apt archetype-A module with an install() override that best-effort seeds the
# contents cache (`apt-file update`). Mirrors the tree/figlet archetype-A spec:
# smoke / metadata / lifecycle dry-run / no-side-fx / idempotency / standalone
# CLI / sidecar lifecycle (ADR-0001) + a REAL doctor() probe + coverage of the
# cache-seed override.

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
    # shellcheck source=../../../module/apt-file.module.sh
    source "${MODULE_DIR}/apt-file.module.sh"
}

_standalone_module() {
    bash "${MODULE_DIR}/apt-file.module.sh" "$@"
}

# ── Controllable mocks ───────────────────────────────────────────────────────

_mock_is_installed() {
    is_installed() { return "${MOCK_IS_INSTALLED_RC:-0}"; }
}

_mock_dpkg() {
    dpkg() {
        [[ -n "${MOCK_DPKG_OUTPUT:-}" ]] && printf '%s\n' "${MOCK_DPKG_OUTPUT}"
        return "${MOCK_DPKG_RC:-0}"
    }
}

_mock_apt_defaults() {
    module_default_apt_install() { return "${MOCK_APT_INSTALL_RC:-0}"; }
    module_default_apt_upgrade() { return "${MOCK_APT_UPGRADE_RC:-0}"; }
    module_default_apt_remove()  { return "${MOCK_APT_REMOVE_RC:-0}"; }
    module_default_apt_purge()   { return "${MOCK_APT_PURGE_RC:-0}"; }
}

# Neutralize the cache-seed side effect for install tests that run the real
# (non-dry-run) install() — the seed itself is exercised by dedicated tests.
_mock_seed() {
    _seed_apt_file_cache() { return 0; }
}


_mock_dpkg_query() {
    dpkg-query() {
        [[ -n "${MOCK_PKG_VERSION:-}" ]] || return 1
        printf '%s' "${MOCK_PKG_VERSION}"
    }
}

_mock_apt_list() {
    apt() { printf '%s' "${MOCK_APT_UPGRADABLE:-}"; }
}

_fake_bin() {
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/usr/bin/env bash\n%s\n' "${2:-exit 0}" > "${INIT_UBUNTU_TEST_SCRATCH}/bin/${1}"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/${1}"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "apt-file module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/apt-file.module.sh"
    assert_success
}

@test "apt-file module sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "apt-file module defines all 10 lifecycle functions" {
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

@test "apt-file module declares NAME=apt-file" {
    _load_module
    [[ "${NAME}" == "apt-file" ]]
}

@test "apt-file module CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "apt-file module TAGS contains cli" {
    _load_module
    [[ " ${TAGS[*]} " == *" cli "* ]]
}

@test "apt-file module DEPENDS_ON is empty" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 0 ]]
}

@test "apt-file DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "apt-file module_get_description returns language-specific text + en fallback" {
    _load_module
    [[ -n "$(module_get_description en)" ]]
    [[ "$(module_get_description zh-TW)" == *"套件"* ]]
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "apt-file SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "apt-file module RISK_LEVEL=low and VERSION_PROVIDED=apt-managed" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
    [[ "${VERSION_PROVIDED}" == "apt-managed" ]]
}

@test "apt-file archetype data installs the apt-file apt package" {
    _load_module
    [[ " ${APT_PKGS[*]} " == *" apt-file "* ]]
    [[ "${#APT_PKGS[@]}" -eq 1 ]]
    [[ -z "${APT_PPA}" ]]
}

# ── is_installed ─────────────────────────────────────────────────────────────

@test "is_installed returns nonzero when dpkg does not report apt-file" {
    _load_module
    MOCK_DPKG_RC=1
    _mock_dpkg
    run is_installed
    assert_failure
}

@test "is_installed returns zero when dpkg reports apt-file as ii" {
    _load_module
    MOCK_DPKG_OUTPUT='ii  apt-file  3.3  all  pkg'
    _mock_dpkg
    run is_installed
    assert_success
}

# ── Lifecycle dry-run ────────────────────────────────────────────────────────

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

# ── install() cache-seed override ────────────────────────────────────────────

@test "install dry-run does NOT reach the contents-cache seed" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    # The dry-run guard returns before _seed_apt_file_cache, so neither of the
    # real seed's log branches appears.
    refute_output --partial "seeding contents cache"
    refute_output --partial "skipping cache seed"
}

@test "install reaches the contents-cache seed after a successful apt install" {
    _load_module
    _mock_apt_defaults
    run install
    assert_success
    # apt-file is not on PATH in the test image, so the best-effort seed takes
    # its skip branch — proving install() reached _seed_apt_file_cache.
    assert_output --partial "skipping cache seed"
}

@test "cache seed is a best-effort no-op when apt-file is not on PATH" {
    _load_module
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty" run _seed_apt_file_cache
    assert_success
}

@test "cache seed never aborts when apt-file update fails (no network)" {
    _load_module
    _fake_bin apt-file 'exit 1'
    _fake_bin sudo 'shift; exec "$@"'
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run _seed_apt_file_cache
    assert_success
    assert_output --partial "will populate on first search"
}

# ── No side effects under dry-run ────────────────────────────────────────────

@test "dry-run install writes nothing under the state dir" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/apt-file" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
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

@test "install writes the sidecar with the dpkg-reported version" {
    _load_module
    _mock_apt_defaults
    _mock_seed
    MOCK_PKG_VERSION="3.3"
    _mock_dpkg_query
    module_standalone_main install
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/apt-file" ]]
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/apt-file")" == "3.3" ]]
}

@test "install never touches state.json (ADR-0001)" {
    _load_module
    printf '{"version":"0.2.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    _mock_apt_defaults
    _mock_seed
    MOCK_PKG_VERSION="3.3"
    _mock_dpkg_query
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "failed apt install leaves no sidecar behind (ADR-0015)" {
    _load_module
    MOCK_APT_INSTALL_RC=1
    _mock_apt_defaults
    _mock_seed
    run module_standalone_main install
    assert_failure
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/apt-file" ]]
}

@test "remove deletes the sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/apt-file"
    _mock_apt_defaults
    module_standalone_main remove
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/apt-file" ]]
}

@test "purge deletes the sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/apt-file"
    _mock_apt_defaults
    module_standalone_main purge
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/apt-file" ]]
}

# ── Idempotency ──────────────────────────────────────────────────────────────

@test "install short-circuits when is_installed returns 0 (idempotency)" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_seed
    MOCK_PKG_VERSION="3.3"
    _mock_dpkg_query
    run install
    assert_success
    assert_output --partial "already installed"
}

@test "install twice with apt mocked exits 0 both times" {
    _load_module
    _mock_apt_defaults
    _mock_seed
    MOCK_PKG_VERSION="3.3"
    _mock_dpkg_query
    run install
    assert_success
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    run install
    assert_success
}

@test "remove is idempotent — second run still exits 0" {
    _load_module
    _mock_apt_defaults
    run remove
    assert_success
    run remove
    assert_success
}

# ── verify / doctor / is_outdated ────────────────────────────────────────────

@test "verify fails when not installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run verify
    assert_failure
}

@test "verify passes when installed and TEST_VERIFY_CMD succeeds" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    TEST_VERIFY_CMD="true"
    run verify
    assert_success
}

@test "doctor fails when not installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run doctor
    assert_failure
}

@test "doctor passes when the apt-file probe binary is available" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _fake_bin apt-file 'exit 0'
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run doctor
    assert_success
}

@test "doctor fails when the apt-file probe binary is missing even though installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty" run doctor
    assert_failure
}

@test "is_outdated returns zero when apt reports apt-file upgradable" {
    _load_module
    MOCK_APT_UPGRADABLE='apt-file/noble-updates 3.3 all [upgradable from: 3.2]'
    _mock_apt_list
    run is_outdated
    assert_success
}

@test "is_outdated returns nonzero when apt-file is not in the upgradable list" {
    _load_module
    MOCK_APT_UPGRADABLE='some-other-pkg/noble 1.0 amd64 [upgradable from: 0.9]'
    _mock_apt_list
    run is_outdated
    assert_failure
}

# ── is_recommended ───────────────────────────────────────────────────────────

@test "is_recommended is nonzero when already installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    run is_recommended
    assert_failure
}

@test "is_recommended is zero when not installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run is_recommended
    assert_success
}

# ── detect ───────────────────────────────────────────────────────────────────

@test "detect succeeds when apt-get is available" {
    _load_module
    _fake_bin apt-get 'exit 0'
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run detect
    assert_success
}

@test "detect fails when apt-get is not on PATH" {
    _load_module
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin" run detect
    assert_failure
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
    assert_output --partial "apt-file"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module nope
    assert_failure 2
}

@test "standalone: info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        apt-file"
    assert_output --partial "category:    optional"
}

@test "standalone: info --lang=zh-TW prints localized description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "套件"
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

@test "standalone: doctor is implemented (exit != 2)" {
    run _standalone_module doctor
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}
