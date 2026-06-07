#!/usr/bin/env bats
# test/unit/module/fnm_spec.bats — module/fnm.module.sh (issue #56)
#
# Coverage per PRD Q29: smoke / metadata / lifecycle presence / dry-run /
# no-side-fx / sidecar (ADR-0001) / idempotency / shell-init hooks /
# is_outdated (mocked, Q46 zero-network) / doctor / standalone CLI (AC-25).

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
    # shellcheck source=../../../module/fnm.module.sh
    source "${MODULE_DIR}/fnm.module.sh"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "fnm module file exists" {
    [[ -f "${MODULE_DIR}/fnm.module.sh" ]]
}

@test "fnm module parses (bash -n)" {
    bash -n "${MODULE_DIR}/fnm.module.sh"
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

@test "NAME=fnm matches the filename stem" {
    _load_module
    [[ "${NAME}" == "fnm" ]]
}

@test "VERSION_PROVIDED is declared (latest)" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "latest" ]]
}

@test "CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "TAGS contains cli-essentials" {
    _load_module
    [[ " ${TAGS[*]} " == *" cli-essentials "* ]]
}

@test "DEPENDS_ON is empty (Q39: module names only, fnm has no module deps)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 0 ]]
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

@test "SUPPORTS_USER_HOME=true (pure \$HOME install, no sudo needed)" {
    _load_module
    [[ "${SUPPORTS_USER_HOME}" == "true" ]]
}

@test "RISK_LEVEL=low" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
}

@test "REBOOT_REQUIRED=false" {
    _load_module
    [[ "${REBOOT_REQUIRED}" == "false" ]]
}

@test "INSTALL_TARGET_DEFAULT=user-home" {
    _load_module
    [[ "${INSTALL_TARGET_DEFAULT}" == "user-home" ]]
}

@test "HOMEPAGE points at the upstream repo" {
    _load_module
    [[ "${HOMEPAGE}" == *"Schniz/fnm"* ]]
}

@test "archetype data: GITHUB_REPO / install script URL / install dir" {
    _load_module
    [[ "${GITHUB_REPO}" == "Schniz/fnm" ]]
    [[ "${FNM_INSTALL_SCRIPT_URL}" == "https://fnm.vercel.app/install" ]]
    [[ "${FNM_INSTALL_DIR}" == "${HOME}/.local/share/fnm" ]]
}

@test "TEST_VERIFY_CMD is declared" {
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

# ── Sandbox + mocks ──────────────────────────────────────────────────────────

# Point all mutable paths into the per-test scratch dir so non-dry-run
# lifecycle runs never touch the real filesystem.
_sandbox_paths() {
    FNM_INSTALL_DIR="${INIT_UBUNTU_TEST_SCRATCH}/home/.local/share/fnm"
    FNM_FISH_CONF="${INIT_UBUNTU_TEST_SCRATCH}/home/.config/fish/conf.d/fnm.fish"
    FNM_BASH_RC="${INIT_UBUNTU_TEST_SCRATCH}/home/.bashrc"
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/home"
}

_sidecar_file() {
    printf '%s/versions/fnm' "${INIT_UBUNTU_STATE_DIR}"
}

# Mock the network-touching pieces (Q46: gates have zero network deps).
# The fake binary answers `fnm --version` so the Sidecar records ${1}.
_mock_remote() {
    local _ver="${1:-1.38.0}"
    eval "get_github_pkg_latest_version() { local -n _out=\"\${1}\"; _out=\"${_ver}\"; }"
    eval "_fnm_fetch_and_install() {
        mkdir -p \"\${FNM_INSTALL_DIR}\"
        printf '#!/usr/bin/env bash\nprintf \"fnm %s\\\\n\"\n' \"${_ver}\" \
            > \"\${FNM_INSTALL_DIR}/fnm\"
        chmod +x \"\${FNM_INSTALL_DIR}/fnm\"
    }"
    _fnm_install_default_node() { return 0; }
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

@test "install --dry-run writes nothing (no sidecar, no install dir, no hooks)" {
    _load_module
    _sandbox_paths
    _mock_remote
    INIT_UBUNTU_DRY_RUN=true install
    [[ ! -e "$(_sidecar_file)" ]]
    [[ ! -e "${FNM_INSTALL_DIR}" ]]
    [[ ! -e "${FNM_FISH_CONF}" ]]
    [[ ! -e "${FNM_BASH_RC}" ]]
}

@test "remove --dry-run does not delete an existing sidecar" {
    _load_module
    _sandbox_paths
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.38.0\n' > "$(_sidecar_file)"
    INIT_UBUNTU_DRY_RUN=true remove
    [[ -f "$(_sidecar_file)" ]]
}

@test "purge --dry-run leaves shell hooks untouched" {
    _load_module
    _sandbox_paths
    mkdir -p "${FNM_FISH_CONF%/*}"
    printf '%s\n' "${FNM_SHELL_MARKER}" > "${FNM_FISH_CONF}"
    printf '%s\nstuff\n%s\n' "${FNM_BASH_BLOCK_BEGIN}" "${FNM_BASH_BLOCK_END}" \
        > "${FNM_BASH_RC}"
    INIT_UBUNTU_DRY_RUN=true purge
    [[ -f "${FNM_FISH_CONF}" ]]
    grep -Fq "${FNM_BASH_BLOCK_BEGIN}" "${FNM_BASH_RC}"
}

# ── No-side-fx: read-only phases write nothing ──────────────────────────────

@test "detect / is_installed / doctor leave the state dir untouched" {
    _load_module
    _sandbox_paths
    detect || true
    is_installed || true
    doctor || true
    [[ -z "$(find "${INIT_UBUNTU_STATE_DIR}" -type f 2>/dev/null)" ]]
}

# ── Install + Sidecar (ADR-0001 / module-spec §4.7.4) ───────────────────────

@test "install fetches and exits 0 (mocked remote)" {
    _load_module
    _sandbox_paths
    _mock_remote "1.38.0"
    run install
    assert_success
    [[ -x "${FNM_INSTALL_DIR}/fnm" ]]
}

@test "install writes the Sidecar with the binary-reported version" {
    _load_module
    _sandbox_paths
    _mock_remote "1.38.0"
    install
    [[ -f "$(_sidecar_file)" ]]
    [[ "$(cat "$(_sidecar_file)")" == "1.38.0" ]]
}

@test "standalone install never touches state.json (AC-23 pattern)" {
    _load_module
    _sandbox_paths
    _mock_remote
    install
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "install short-circuits when already installed (AC-5 idempotency)" {
    _load_module
    _sandbox_paths
    _mock_remote
    eval 'is_installed() { return 0; }'
    run install
    assert_success
    assert_output --partial "already installed"
}

@test "second install run also exits 0 (AC-5 pattern, real is_installed)" {
    _load_module
    _sandbox_paths
    _mock_remote
    install
    run install
    assert_success
}

@test "failed fetch leaves no Sidecar behind" {
    _load_module
    _sandbox_paths
    _mock_remote
    eval '_fnm_fetch_and_install() { return 1; }'
    run install
    assert_failure
    [[ ! -e "$(_sidecar_file)" ]]
}

@test "upgrade re-fetches and updates the Sidecar version" {
    _load_module
    _sandbox_paths
    _mock_remote "1.38.0"
    install
    _mock_remote "1.39.0"
    upgrade
    [[ "$(cat "$(_sidecar_file)")" == "1.39.0" ]]
}

@test "remove deletes the fnm binary and Sidecar" {
    _load_module
    _sandbox_paths
    _mock_remote
    install
    remove
    [[ ! -e "${FNM_INSTALL_DIR}/fnm" ]]
    [[ ! -e "$(_sidecar_file)" ]]
}

@test "remove keeps downloaded Node versions (purge wipes them)" {
    _load_module
    _sandbox_paths
    _mock_remote
    install
    mkdir -p "${FNM_INSTALL_DIR}/node-versions/v22.0.0"
    remove
    [[ -d "${FNM_INSTALL_DIR}/node-versions/v22.0.0" ]]
}

@test "remove on a clean system still exits 0 (idempotent)" {
    _load_module
    _sandbox_paths
    run remove
    assert_success
    run remove
    assert_success
}

@test "purge deletes install dir (incl. Node versions), hooks and Sidecar" {
    _load_module
    _sandbox_paths
    _mock_remote
    printf '# user bashrc\n' > "${FNM_BASH_RC}"
    install
    mkdir -p "${FNM_INSTALL_DIR}/node-versions/v22.0.0"
    purge
    [[ ! -e "${FNM_INSTALL_DIR}" ]]
    [[ ! -e "${FNM_FISH_CONF}" ]]
    ! grep -Fq "${FNM_BASH_BLOCK_BEGIN}" "${FNM_BASH_RC}"
    [[ ! -e "$(_sidecar_file)" ]]
}

@test "purge on a clean system still exits 0 (idempotent)" {
    _load_module
    _sandbox_paths
    run purge
    assert_success
}

# ── Shell-init hooks (idempotent, marker-guarded) ───────────────────────────

@test "install writes the fish conf.d hook with our marker" {
    _load_module
    _sandbox_paths
    _mock_remote
    install
    [[ -f "${FNM_FISH_CONF}" ]]
    grep -Fq "${FNM_SHELL_MARKER}" "${FNM_FISH_CONF}"
    grep -Fq "fnm env --use-on-cd --shell fish" "${FNM_FISH_CONF}"
}

@test "fish hook embeds the actual install dir" {
    _load_module
    _sandbox_paths
    _mock_remote
    install
    grep -Fq "set -gx FNM_PATH \"${FNM_INSTALL_DIR}\"" "${FNM_FISH_CONF}"
}

@test "second run leaves the fish hook byte-identical (idempotent)" {
    _load_module
    _sandbox_paths
    _mock_remote
    install
    local _before; _before="$(cat "${FNM_FISH_CONF}")"
    upgrade
    [[ "$(cat "${FNM_FISH_CONF}")" == "${_before}" ]]
}

@test "a user-owned fnm.fish (no marker) is never clobbered" {
    _load_module
    _sandbox_paths
    _mock_remote
    mkdir -p "${FNM_FISH_CONF%/*}"
    printf '# my own fnm setup\n' > "${FNM_FISH_CONF}"
    install
    [[ "$(cat "${FNM_FISH_CONF}")" == "# my own fnm setup" ]]
}

@test "purge keeps a user-owned fnm.fish (no marker)" {
    _load_module
    _sandbox_paths
    mkdir -p "${FNM_FISH_CONF%/*}"
    printf '# my own fnm setup\n' > "${FNM_FISH_CONF}"
    purge
    [[ -f "${FNM_FISH_CONF}" ]]
}

@test "install appends the bash hook block to an existing .bashrc" {
    _load_module
    _sandbox_paths
    _mock_remote
    printf '# user bashrc\n' > "${FNM_BASH_RC}"
    install
    grep -Fq "${FNM_BASH_BLOCK_BEGIN}" "${FNM_BASH_RC}"
    grep -Fq 'eval "$(fnm env --use-on-cd)"' "${FNM_BASH_RC}"
    grep -Fq "${FNM_BASH_BLOCK_END}" "${FNM_BASH_RC}"
}

@test "install never creates a .bashrc when none exists" {
    _load_module
    _sandbox_paths
    _mock_remote
    install
    [[ ! -e "${FNM_BASH_RC}" ]]
}

@test "second run appends the bash block exactly once (idempotent)" {
    _load_module
    _sandbox_paths
    _mock_remote
    printf '# user bashrc\n' > "${FNM_BASH_RC}"
    install
    upgrade
    [[ "$(grep -Fc "${FNM_BASH_BLOCK_BEGIN}" "${FNM_BASH_RC}")" -eq 1 ]]
}

@test "purge strips only the fenced bash block, keeping user content" {
    _load_module
    _sandbox_paths
    _mock_remote
    printf '# user bashrc top\n' > "${FNM_BASH_RC}"
    install
    printf '# user bashrc bottom\n' >> "${FNM_BASH_RC}"
    purge
    grep -Fq "# user bashrc top" "${FNM_BASH_RC}"
    grep -Fq "# user bashrc bottom" "${FNM_BASH_RC}"
    ! grep -Fq "${FNM_BASH_BLOCK_BEGIN}" "${FNM_BASH_RC}"
    ! grep -Fq "FNM_PATH" "${FNM_BASH_RC}"
}
