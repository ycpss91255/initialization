#!/usr/bin/env bats
# test/unit/module/gemini_spec.bats — module/gemini.module.sh (issue #74)
#
# Coverage per PRD Q29: smoke / metadata / lifecycle presence / dry-run /
# no-side-fx / sidecar (ADR-0001) / idempotency / is_outdated (mocked,
# Q46 zero-network) / doctor / npm seam / standalone CLI (AC-25).

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
    # shellcheck source=../../../module/gemini.module.sh
    source "${MODULE_DIR}/gemini.module.sh"
}

_sidecar_file() {
    printf '%s/versions/gemini' "${INIT_UBUNTU_STATE_DIR}"
}

# ── Controllable mocks ───────────────────────────────────────────────────────
# Each shadowed function is defined exactly once and parameterized via
# MOCK_* variables, so every definition stays reachable for the linter
# (avoids SC2317 without disable directives).

# is_installed mock: MOCK_IS_INSTALLED_RC (0 = installed, 1 = not).
_mock_is_installed() {
    is_installed() { return "${MOCK_IS_INSTALLED_RC:-0}"; }
}

# npm package installer mock: MOCK_PKG_INSTALL_RC (0 = success).
_mock_pkg_install() {
    _gemini_pkg_install() { return "${MOCK_PKG_INSTALL_RC:-0}"; }
}

# npm package uninstaller mock: MOCK_PKG_UNINSTALL_RC (0 = success).
_mock_pkg_uninstall() {
    _gemini_pkg_uninstall() { return "${MOCK_PKG_UNINSTALL_RC:-0}"; }
}

# Version probe mock: MOCK_GEMINI_VERSION (default 9.9.9).
_mock_version() {
    _gemini_version() { printf '%s' "${MOCK_GEMINI_VERSION:-9.9.9}"; }
}

# Registry probe mock (is_outdated remote side, Q46 zero-network):
# MOCK_NPM_VIEW_RC + MOCK_NPM_VIEW_VERSION drive the `npm view` seam.
_mock_npm() {
    _gemini_npm() {
        [[ "${MOCK_NPM_VIEW_RC:-0}" -eq 0 ]] || return "${MOCK_NPM_VIEW_RC}"
        printf '%s\n' "${MOCK_NPM_VIEW_VERSION:-9.9.9}"
    }
}

# uname mock for detect(): MOCK_UNAME (machine string, default x86_64).
_mock_uname() {
    uname() { printf '%s' "${MOCK_UNAME:-x86_64}"; }
}

# Drop a fake executable into a scratch PATH dir; prints args log + version.
_make_fake_bin() {
    local _name="${1:?}" _dir="${INIT_UBUNTU_TEST_SCRATCH}/path-bin"
    mkdir -p "${_dir}"
    cat > "${_dir}/${_name}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${INIT_UBUNTU_TEST_SCRATCH}/${_name}-calls"
[[ "\${1:-}" == "--version" ]] && printf '9.9.9\n'
exit 0
EOF
    chmod +x "${_dir}/${_name}"
    printf '%s' "${_dir}"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "gemini module file exists" {
    [[ -f "${MODULE_DIR}/gemini.module.sh" ]]
}

@test "gemini module parses (bash -n)" {
    run bash -n "${MODULE_DIR}/gemini.module.sh"
    assert_success
}

@test "sourcing in engine mode exits 0 and runs no lifecycle" {
    run _load_module
    assert_success
    refute_output --partial "install"
}

@test "engine mode does not invoke module_standalone_main" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

# ── Metadata (doc/module-spec.md §3, PRD §9.1) ──────────────────────────────

@test "NAME=gemini matches the filename stem" {
    _load_module
    [[ "${NAME}" == "gemini" ]]
}

@test "VERSION_PROVIDED is declared (latest)" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "latest" ]]
}

@test "CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "TAGS contains agent" {
    _load_module
    [[ " ${TAGS[*]} " == *" agent "* ]]
}

@test "DEPENDS_ON is exactly fnm (Q39: module names only)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 1 ]]
    [[ "${DEPENDS_ON[0]}" == "fnm" ]]
}

@test "DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "$(module_get_description en)" ]]
    [[ -n "$(module_get_description zh-TW)" ]]
}

@test "POST_INSTALL_MESSAGE and WARN_MESSAGE are associative arrays" {
    _load_module
    [[ "$(declare -p POST_INSTALL_MESSAGE 2>/dev/null)" == 'declare -'*A* ]]
    [[ "$(declare -p WARN_MESSAGE 2>/dev/null)" == 'declare -'*A* ]]
}

@test "SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "SUPPORTED_PLATFORMS is non-empty" {
    _load_module
    [[ "${#SUPPORTED_PLATFORMS[@]}" -gt 0 ]]
}

@test "npm install lands in user home (no sudo): SUPPORTS_USER_HOME=true" {
    _load_module
    [[ "${SUPPORTS_USER_HOME}" == "true" ]]
    [[ "${INSTALL_TARGET_DEFAULT}" == "user-home" ]]
}

@test "RISK_LEVEL=low" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
}

@test "REBOOT_REQUIRED=false" {
    _load_module
    [[ "${REBOOT_REQUIRED}" == "false" ]]
}

@test "HOMEPAGE points at the upstream repo" {
    _load_module
    [[ "${HOMEPAGE}" == *"google-gemini/gemini-cli"* ]]
}

@test "archetype data: GEMINI_NPM_PKG is the npm-only distribution" {
    _load_module
    [[ "${GEMINI_NPM_PKG}" == "@google/gemini-cli" ]]
    [[ "${GEMINI_BIN_NAME}" == "gemini" ]]
}

@test "TEST_VERIFY_CMD is declared for module_default_verify" {
    _load_module
    [[ -n "${TEST_VERIFY_CMD}" ]]
}

# ── Lifecycle presence (ADR-0002: all 10 resolvable) ────────────────────────

@test "lifecycle: detect() is defined" {
    _load_module
    declare -F detect
}

@test "lifecycle: is_recommended() is defined" {
    _load_module
    declare -F is_recommended
}

@test "lifecycle: is_installed() is defined" {
    _load_module
    declare -F is_installed
}

@test "lifecycle: is_outdated() is defined" {
    _load_module
    declare -F is_outdated
}

@test "lifecycle: install() is defined" {
    _load_module
    declare -F install
}

@test "lifecycle: upgrade() is defined" {
    _load_module
    declare -F upgrade
}

@test "lifecycle: remove() is defined" {
    _load_module
    declare -F remove
}

@test "lifecycle: purge() is defined" {
    _load_module
    declare -F purge
}

@test "lifecycle: verify() is defined" {
    _load_module
    declare -F verify
}

@test "lifecycle: doctor() is defined" {
    _load_module
    declare -F doctor
}

# ── Dry-run (AC-12 pattern: log only, no side effects) ──────────────────────

@test "install --dry-run exits 0 and logs DRY-RUN" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "upgrade --dry-run exits 0 and logs DRY-RUN" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run upgrade
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "remove --dry-run exits 0 and logs DRY-RUN" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "purge --dry-run exits 0 and logs DRY-RUN" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run purge
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "verify --dry-run exits 0 and logs DRY-RUN" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run verify
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "install --dry-run writes nothing (no sidecar, no state.json)" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true install
    [[ ! -e "$(_sidecar_file)" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "remove --dry-run does not delete an existing sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '0.9.0\n' > "$(_sidecar_file)"
    INIT_UBUNTU_DRY_RUN=true remove
    [[ -f "$(_sidecar_file)" ]]
}

# ── No-side-fx: read-only phases write nothing ──────────────────────────────

@test "detect / is_installed / doctor leave the state dir untouched" {
    _load_module
    detect || true
    is_installed || true
    doctor || true
    [[ -z "$(find "${INIT_UBUNTU_STATE_DIR}" -type f 2>/dev/null)" ]]
}

# ── Install + Sidecar (ADR-0001 / module-spec §4.7.4) ───────────────────────

@test "install writes the Sidecar with the probed version (mocked npm)" {
    _load_module
    _mock_pkg_install
    _mock_version
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    module_standalone_main install
    [[ -f "$(_sidecar_file)" ]]
    [[ "$(cat "$(_sidecar_file)")" == "9.9.9" ]]
}

@test "standalone install never touches state.json (AC-23 pattern)" {
    _load_module
    printf '{"schema_version":"0.1.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    _mock_pkg_install
    _mock_version
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "install short-circuits when already installed (AC-5 idempotency)" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    run install
    assert_success
    assert_output --partial "already installed"
}

@test "second install run also exits 0 (AC-5 pattern)" {
    _load_module
    _mock_pkg_install
    _mock_version
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run install
    assert_success
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    run install
    assert_success
}

@test "failed npm install leaves no Sidecar behind" {
    _load_module
    MOCK_PKG_INSTALL_RC=1
    _mock_pkg_install
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run module_standalone_main install
    assert_failure
    [[ ! -e "$(_sidecar_file)" ]]
}

@test "upgrade refreshes the Sidecar version" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "$(_sidecar_file)"
    _mock_pkg_install
    _mock_version
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    module_standalone_main upgrade
    [[ "$(cat "$(_sidecar_file)")" == "9.9.9" ]]
}

@test "upgrade falls back to install when not installed" {
    _load_module
    _mock_pkg_install
    _mock_version
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run upgrade
    assert_success
    assert_output --partial "running install instead"
}

@test "upgrade fails when the npm refresh fails (no stale Sidecar)" {
    _load_module
    MOCK_PKG_INSTALL_RC=1
    _mock_pkg_install
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    run module_standalone_main upgrade
    assert_failure
    [[ ! -e "$(_sidecar_file)" ]]
}

@test "remove uninstalls the package and deletes the Sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "$(_sidecar_file)"
    _mock_pkg_uninstall
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    module_standalone_main remove
    [[ ! -e "$(_sidecar_file)" ]]
}

@test "remove on a clean system still exits 0 (idempotent)" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run remove
    assert_success
    run remove
    assert_success
}

@test "purge deletes CONFIG_PATHS and the Sidecar" {
    _load_module
    CONFIG_PATHS=("${INIT_UBUNTU_TEST_SCRATCH}/dot-gemini")
    mkdir -p "${CONFIG_PATHS[0]}"
    printf '{}\n' > "${CONFIG_PATHS[0]}/settings.json"
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "$(_sidecar_file)"
    _mock_pkg_uninstall
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    module_standalone_main purge
    [[ ! -e "${CONFIG_PATHS[0]}" ]]
    [[ ! -e "$(_sidecar_file)" ]]
}

@test "purge on a clean system still exits 0 (idempotent)" {
    _load_module
    CONFIG_PATHS=("${INIT_UBUNTU_TEST_SCRATCH}/dot-gemini")
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run purge
    assert_success
    run purge
    assert_success
}

# ── npm seam (custom archetype: PATH npm first, fnm exec fallback) ──────────

@test "_gemini_npm prefers npm on PATH" {
    _load_module
    local _dir
    _dir="$(_make_fake_bin npm)"
    PATH="${_dir}:${PATH}" _gemini_npm install -g "${GEMINI_NPM_PKG}@latest"
    grep -q "install -g ${GEMINI_NPM_PKG}@latest" \
        "${INIT_UBUNTU_TEST_SCRATCH}/npm-calls"
}

@test "_gemini_npm falls back to fnm exec when npm is missing" {
    _load_module
    local _dir
    _dir="$(_make_fake_bin fnm)"
    GEMINI_FNM_DIR="${INIT_UBUNTU_TEST_SCRATCH}/no-such-fnm-dir"
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${_dir}:${INIT_UBUNTU_TEST_SCRATCH}/empty-bin:/usr/bin:/bin" \
        _gemini_npm ls -g "${GEMINI_NPM_PKG}"
    grep -q "exec --using=default npm ls -g ${GEMINI_NPM_PKG}" \
        "${INIT_UBUNTU_TEST_SCRATCH}/fnm-calls"
}

@test "_gemini_npm fails cleanly when neither npm nor fnm exists" {
    _load_module
    GEMINI_FNM_DIR="${INIT_UBUNTU_TEST_SCRATCH}/no-such-fnm-dir"
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin:/usr/bin:/bin" \
        run _gemini_npm ls -g "${GEMINI_NPM_PKG}"
    assert_failure
    assert_output --partial "fnm"
}

@test "install fails with a clear error when no npm is reachable" {
    _load_module
    GEMINI_FNM_DIR="${INIT_UBUNTU_TEST_SCRATCH}/no-such-fnm-dir"
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin:/usr/bin:/bin" \
        run module_standalone_main install
    assert_failure
    assert_output --partial "fnm"
    [[ ! -e "$(_sidecar_file)" ]]
}

# ── is_installed ─────────────────────────────────────────────────────────────

@test "is_installed returns nonzero on a clean container" {
    _load_module
    GEMINI_FNM_DIR="${INIT_UBUNTU_TEST_SCRATCH}/no-such-fnm-dir"
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin:/usr/bin:/bin" \
        run is_installed
    assert_failure
}

@test "is_installed returns zero when gemini is on PATH" {
    _load_module
    local _dir
    _dir="$(_make_fake_bin gemini)"
    PATH="${_dir}:${PATH}" run is_installed
    assert_success
}

@test "is_installed asks the npm global tree when no binary is on PATH" {
    _load_module
    local _dir
    _dir="$(_make_fake_bin npm)"
    GEMINI_FNM_DIR="${INIT_UBUNTU_TEST_SCRATCH}/no-such-fnm-dir"
    PATH="${_dir}:/usr/bin:/bin" run is_installed
    assert_success
    grep -q "ls -g ${GEMINI_NPM_PKG}" "${INIT_UBUNTU_TEST_SCRATCH}/npm-calls"
}

# ── is_outdated (mocked registry, Q46 zero-network) ─────────────────────────

@test "is_outdated returns nonzero when not installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run is_outdated
    assert_failure
}

@test "is_outdated returns nonzero when local matches the registry" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '9.9.9\n' > "$(_sidecar_file)"
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    MOCK_NPM_VIEW_VERSION="9.9.9"
    _mock_npm
    run is_outdated
    assert_failure
}

@test "is_outdated returns 0 when the registry has a newer version" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '9.9.9\n' > "$(_sidecar_file)"
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    MOCK_NPM_VIEW_VERSION="10.0.0"
    _mock_npm
    run is_outdated
    assert_success
}

@test "is_outdated returns nonzero when the registry query fails" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '9.9.9\n' > "$(_sidecar_file)"
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    MOCK_NPM_VIEW_RC=1
    _mock_npm
    run is_outdated
    assert_failure
}

# ── doctor (Sidecar invariant: is_installed ⟷ Sidecar exists) ───────────────

@test "doctor passes on a clean system (not installed, no Sidecar)" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run doctor
    assert_success
}

@test "doctor passes after a successful install" {
    _load_module
    _mock_pkg_install
    _mock_version
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    module_standalone_main install
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    run doctor
    assert_success
}

@test "doctor flags drift: installed but Sidecar missing" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    run doctor
    assert_failure
}

@test "doctor flags drift: Sidecar exists but not installed" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '9.9.9\n' > "$(_sidecar_file)"
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run doctor
    assert_failure
}

@test "doctor fails when the gemini binary does not answer --version" {
    _load_module
    local _dir="${INIT_UBUNTU_TEST_SCRATCH}/broken-bin"
    mkdir -p "${_dir}"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${_dir}/gemini"
    chmod +x "${_dir}/gemini"
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '9.9.9\n' > "$(_sidecar_file)"
    PATH="${_dir}:${PATH}" run doctor
    assert_failure
}

# ── detect / is_recommended ─────────────────────────────────────────────────

@test "detect returns 0 on x86_64" {
    _load_module
    MOCK_UNAME=x86_64
    _mock_uname
    run detect
    assert_success
}

@test "detect returns 0 on aarch64" {
    _load_module
    MOCK_UNAME=aarch64
    _mock_uname
    run detect
    assert_success
}

@test "detect returns nonzero on an unsupported arch" {
    _load_module
    MOCK_UNAME=mips
    _mock_uname
    run detect
    assert_failure
}

@test "is_recommended returns 0 when not installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run is_recommended
    assert_success
}

@test "is_recommended returns nonzero when already installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    run is_recommended
    assert_failure
}

# ── verify ───────────────────────────────────────────────────────────────────

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

# ── Engine discovery (registry scan) ────────────────────────────────────────

@test "registry discovers gemini under --tag=agent" {
    # shellcheck source=../../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../../lib/registry.sh
    source "${LIB_DIR}/registry.sh"
    export INIT_UBUNTU_USER_MODULE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/user-module"
    registry_load_all "${MODULE_DIR}"
    run registry_list_names --tag=agent
    assert_success
    assert_output --partial "gemini"
}

# ── Standalone CLI (AC-25: all 10 phases, never not-implemented exit 2) ─────

_standalone() {
    local _home="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${_home}"
    HOME="${_home}" XDG_STATE_HOME="" INIT_UBUNTU_STATE_DIR="" \
        run bash "${MODULE_DIR}/gemini.module.sh" "$@"
}

@test "standalone --help prints usage" {
    _standalone --help
    assert_success
    assert_output --partial "Usage:"
}

@test "standalone --version prints name + version" {
    _standalone --version
    assert_success
    assert_output --partial "gemini"
}

@test "standalone info prints metadata incl. fnm dependency" {
    _standalone info
    assert_success
    assert_output --partial "name:        gemini"
    assert_output --partial "agent"
    assert_output --partial "depends_on:  fnm"
}

@test "standalone status reports install state" {
    _standalone status
    assert_success
    assert_output --partial "installed:"
}

@test "standalone with no args exits 2 and shows usage" {
    _standalone
    [[ "${status}" -eq 2 ]]
}

@test "standalone with unknown phase exits 2" {
    _standalone frobnicate
    [[ "${status}" -eq 2 ]]
}

@test "AC-25 standalone install --dry-run runs (exit 0)" {
    _standalone install --dry-run
    assert_success
    refute_output --partial "not implemented"
}

@test "AC-25 standalone upgrade --dry-run runs (exit 0)" {
    _standalone upgrade --dry-run
    assert_success
    refute_output --partial "not implemented"
}

@test "AC-25 standalone remove --dry-run runs (exit 0)" {
    _standalone remove --dry-run
    assert_success
    refute_output --partial "not implemented"
}

@test "AC-25 standalone purge --dry-run runs (exit 0)" {
    _standalone purge --dry-run
    assert_success
    refute_output --partial "not implemented"
}

@test "AC-25 standalone verify --dry-run runs (exit 0)" {
    _standalone verify --dry-run
    assert_success
    refute_output --partial "not implemented"
}

@test "AC-25 standalone detect runs (exit != 2)" {
    _standalone detect
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "AC-25 standalone is-installed runs (exit != 2)" {
    _standalone is-installed
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "AC-25 standalone is-recommended runs (exit != 2)" {
    _standalone is-recommended
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "AC-25 standalone is-outdated runs (exit != 2)" {
    _standalone is-outdated
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "AC-25 standalone doctor runs (exit != 2)" {
    _standalone doctor
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone --dry-run install leaves a fresh HOME empty" {
    local _home="${INIT_UBUNTU_TEST_SCRATCH}/home-clean"
    mkdir -p "${_home}"
    HOME="${_home}" XDG_STATE_HOME="" INIT_UBUNTU_STATE_DIR="" \
        run bash "${MODULE_DIR}/gemini.module.sh" install --dry-run
    assert_success
    [[ -z "$(find "${_home}" -type f 2>/dev/null)" ]]
}
