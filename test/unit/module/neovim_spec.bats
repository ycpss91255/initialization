#!/usr/bin/env bats
# test/unit/module/neovim_spec.bats — module/neovim.module.sh (issue #123)
#
# Coverage per PRD Q29: smoke / metadata / lifecycle presence / dry-run /
# no-side-fx / sidecar semantics (ADR-0001) / idempotency (AC-5) /
# standalone CLI (AC-25) / module-specific nvimdots config drop.
#
# Archetype B (GitHub release) on the default wiring: is_installed / upgrade /
# remove / purge / verify come straight from module_use_github_release_archetype;
# install() is overridden to super-call the archetype fetch and then drop the
# nvimdots config into ~/.config/nvim. The module implements neither
# is_outdated() nor doctor() (no archetype-B default exists) — the standalone
# CLI degrades to "not implemented" exit 2 for those phases.

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
    # shellcheck source=../../../module/neovim.module.sh
    source "${MODULE_DIR}/neovim.module.sh"
}

# Point all mutable paths into the per-test scratch dir so non-dry-run
# lifecycle runs never touch the real filesystem. HOME is sandboxed too:
# the nvimdots config drop writes to ${HOME}/.config/nvim at call time.
_sandbox_paths() {
    INSTALL_DIR="${INIT_UBUNTU_TEST_SCRATCH}/opt/nvim"
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/bin/nvim"
    USE_SUDO=false
    HOME="${INIT_UBUNTU_TEST_SCRATCH}/home"
    CONFIG_PATHS=(
        "${HOME}/.config/nvim"
        "${HOME}/.local/share/nvim"
        "${HOME}/.cache/nvim"
    )
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin" "${HOME}"
}

# Config re-drops route through backup_file (lib/general.sh), which
# log_fatals when BACKUP_DIR is unset. Helper (not inline in the @test
# bodies: shellcheck SC2030/SC2031 flag cross-test var modification).
_use_backup_dir() {
    export BACKUP_DIR="${INIT_UBUNTU_TEST_SCRATCH}/backup"
}

# Mock the network-touching pieces (Q46: gates have zero network deps).
_mock_remote() {
    local _ver="${1:-0.11.0}"
    eval "get_github_pkg_latest_version() { local -n _out=\"\${1}\"; _out=\"${_ver}\"; }"
    _module_github_release_fetch_and_install() {
        mkdir -p "${INSTALL_DIR}/bin"
        printf '#!/usr/bin/env bash\nprintf "NVIM v0.0-test\\n"\n' \
            > "${INSTALL_DIR}/bin/nvim"
        chmod +x "${INSTALL_DIR}/bin/nvim"
        ln -sfn "${INSTALL_DIR}/bin/nvim" "${BIN_LINK}"
    }
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "neovim module file exists" {
    [[ -f "${MODULE_DIR}/neovim.module.sh" ]]
}

@test "neovim module parses (bash -n)" {
    bash -n "${MODULE_DIR}/neovim.module.sh"
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

@test "NAME=neovim matches the filename stem" {
    _load_module
    [[ "${NAME}" == "neovim" ]]
}

@test "VERSION_PROVIDED is declared (latest)" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "latest" ]]
}

@test "CATEGORY=recommended" {
    _load_module
    [[ "${CATEGORY}" == "recommended" ]]
}

@test "TAGS contains editor and cli" {
    _load_module
    [[ " ${TAGS[*]} " == *" editor "* ]]
    [[ " ${TAGS[*]} " == *" cli "* ]]
}

@test "DEPENDS_ON is exactly curl + git-config (Q39)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 2 ]]
    [[ " ${DEPENDS_ON[*]} " == *" curl "* ]]
    [[ " ${DEPENDS_ON[*]} " == *" git-config "* ]]
}

@test "every DEPENDS_ON entry is a real module name (Q39)" {
    _load_module
    local _dep
    for _dep in "${DEPENDS_ON[@]}"; do
        [[ -f "${MODULE_DIR}/${_dep}.module.sh" ]]
    done
}

@test "DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "$(module_get_description en)" ]]
    [[ -n "$(module_get_description zh-TW)" ]]
}

@test "POST_INSTALL_MESSAGE carries the lazy.nvim first-launch note (en + zh-TW)" {
    _load_module
    [[ "$(declare -p POST_INSTALL_MESSAGE 2>/dev/null)" == 'declare -'*A* ]]
    [[ "$(module_get_post_install_message en)" == *"lazy.nvim"* ]]
    [[ -n "$(module_get_post_install_message zh-TW)" ]]
}

@test "WARN_MESSAGE is an associative array" {
    _load_module
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

@test "SUPPORTS_USER_HOME=false" {
    _load_module
    [[ "${SUPPORTS_USER_HOME}" == "false" ]]
}

@test "RISK_LEVEL=low" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
}

@test "REBOOT_REQUIRED=false" {
    _load_module
    [[ "${REBOOT_REQUIRED}" == "false" ]]
}

@test "INSTALL_TARGET_DEFAULT=sudo" {
    _load_module
    [[ "${INSTALL_TARGET_DEFAULT}" == "sudo" ]]
}

@test "HOMEPAGE points at neovim.io" {
    _load_module
    [[ "${HOMEPAGE}" == *"neovim.io"* ]]
}

@test "archetype data: GITHUB_REPO / asset / BIN_NAME / INSTALL_DIR / BIN_LINK" {
    _load_module
    [[ "${GITHUB_REPO}" == "neovim/neovim" ]]
    [[ "${GITHUB_ASSET_PATTERN}" == "nvim-linux-x86_64.tar.gz" ]]
    [[ "${BIN_NAME}" == "nvim" ]]
    [[ "${INSTALL_DIR}" == "/opt/nvim" ]]
    [[ "${BIN_LINK}" == "/usr/local/bin/nvim" ]]
    [[ "${STRIP_COMPONENTS}" -eq 1 ]]
}

@test "CONFIG_PATHS covers nvim config, data and cache dirs" {
    _load_module
    [[ "${#CONFIG_PATHS[@]}" -eq 3 ]]
    [[ " ${CONFIG_PATHS[*]} " == *"/.config/nvim "* ]]
    [[ " ${CONFIG_PATHS[*]} " == *"/.local/share/nvim "* ]]
    [[ " ${CONFIG_PATHS[*]} " == *"/.cache/nvim "* ]]
}

@test "TEST_VERIFY_CMD is declared for module_default_verify" {
    _load_module
    [[ -n "${TEST_VERIFY_CMD}" ]]
}

# ── Lifecycle presence (ADR-0002) ───────────────────────────────────────────

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

# ── Dry-run (AC-12 pattern: log only, no side effects) ──────────────────────

@test "install --dry-run exits 0, logs DRY-RUN incl. the nvimdots drop" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    assert_output --partial "DRY-RUN"
    assert_output --partial "nvimdots"
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

@test "install --dry-run writes nothing (no install dir, no config drop)" {
    _load_module
    _sandbox_paths
    _mock_remote
    INIT_UBUNTU_DRY_RUN=true install
    [[ ! -e "${INSTALL_DIR}" ]]
    [[ ! -e "${HOME}/.config/nvim" ]]
    [[ -z "$(find "${INIT_UBUNTU_STATE_DIR}" -type f 2>/dev/null)" ]]
}

@test "remove --dry-run leaves an existing install untouched" {
    _load_module
    _sandbox_paths
    _mock_remote
    install
    INIT_UBUNTU_DRY_RUN=true remove
    [[ -x "${BIN_LINK}" ]]
    [[ -d "${INSTALL_DIR}" ]]
}

@test "purge --dry-run leaves the dropped config untouched" {
    _load_module
    _sandbox_paths
    _mock_remote
    install
    INIT_UBUNTU_DRY_RUN=true purge
    [[ -d "${HOME}/.config/nvim" ]]
}

# ── No-side-fx: read-only phases write nothing ──────────────────────────────

@test "detect / is_installed / is_recommended leave the state dir untouched" {
    _load_module
    _sandbox_paths
    detect || true
    is_installed || true
    is_recommended || true
    [[ -z "$(find "${INIT_UBUNTU_STATE_DIR}" -type f 2>/dev/null)" ]]
}

# ── Install + nvimdots config drop ──────────────────────────────────────────

@test "install fetches and exits 0 (mocked remote)" {
    _load_module
    _sandbox_paths
    _mock_remote "0.11.0"
    run install
    assert_success
    [[ -x "${BIN_LINK}" ]]
}

@test "install drops the nvimdots config into ~/.config/nvim" {
    _load_module
    _sandbox_paths
    _mock_remote
    install
    [[ -d "${HOME}/.config/nvim" ]]
}

@test "install backs up an existing ~/.config/nvim before the drop" {
    _load_module
    _sandbox_paths
    _mock_remote
    _use_backup_dir
    mkdir -p "${HOME}/.config/nvim"
    printf '%s\n' '-- user config' > "${HOME}/.config/nvim/init.lua"
    run install
    assert_success
    [[ -f "${BACKUP_DIR}/nvim/init.lua" ]]
}

@test "install warns but exits 0 when the nvimdots source dir is missing" {
    _load_module
    _sandbox_paths
    _mock_remote
    local _empty_module="${INIT_UBUNTU_TEST_SCRATCH}/empty-module"
    mkdir -p "${_empty_module}"
    MODULE_DIR="${_empty_module}" run install
    assert_success
    assert_output --partial "config dir missing"
    [[ ! -e "${HOME}/.config/nvim" ]]
}

@test "failed fetch aborts install before the config drop" {
    _load_module
    _sandbox_paths
    _mock_remote
    eval '_module_github_release_fetch_and_install() { return 1; }'
    run install
    assert_failure
    [[ ! -e "${HOME}/.config/nvim" ]]
}

# ── Sidecar semantics (ADR-0001 / AC-23 pattern) ────────────────────────────

@test "standalone install never touches state.json (AC-23 pattern)" {
    _load_module
    _sandbox_paths
    _mock_remote
    install
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

# ── Idempotency (AC-5) ──────────────────────────────────────────────────────

@test "install short-circuits the fetch when already installed (AC-5)" {
    _load_module
    _sandbox_paths
    _mock_remote
    eval 'is_installed() { return 0; }'
    run install
    assert_success
    assert_output --partial "already installed"
    [[ ! -e "${INSTALL_DIR}" ]]
}

@test "second install run also exits 0 (AC-5 pattern, real is_installed)" {
    _load_module
    _sandbox_paths
    _mock_remote
    # Second run re-drops the config over an existing ~/.config/nvim, which
    # routes through backup_file — that helper log_fatals without BACKUP_DIR.
    _use_backup_dir
    install
    run install
    assert_success
}

@test "upgrade re-fetches the binary but never re-drops the config" {
    _load_module
    _sandbox_paths
    _mock_remote
    upgrade
    [[ -x "${BIN_LINK}" ]]
    [[ ! -e "${HOME}/.config/nvim" ]]
}

@test "remove deletes install dir + symlink but keeps the user config" {
    _load_module
    _sandbox_paths
    _mock_remote
    install
    remove
    [[ ! -e "${INSTALL_DIR}" ]]
    [[ ! -e "${BIN_LINK}" ]]
    [[ -d "${HOME}/.config/nvim" ]]
}

@test "remove on a clean system still exits 0 (idempotent)" {
    _load_module
    _sandbox_paths
    run remove
    assert_success
    run remove
    assert_success
}

@test "purge deletes install dir and all three CONFIG_PATHS" {
    _load_module
    _sandbox_paths
    _mock_remote
    install
    mkdir -p "${CONFIG_PATHS[1]}" "${CONFIG_PATHS[2]}"
    : > "${CONFIG_PATHS[1]}/shada"
    : > "${CONFIG_PATHS[2]}/luac"
    purge
    [[ ! -e "${INSTALL_DIR}" ]]
    [[ ! -e "${BIN_LINK}" ]]
    [[ ! -e "${CONFIG_PATHS[0]}" ]]
    [[ ! -e "${CONFIG_PATHS[1]}" ]]
    [[ ! -e "${CONFIG_PATHS[2]}" ]]
}

@test "purge on a clean system still exits 0 (idempotent)" {
    _load_module
    _sandbox_paths
    run purge
    assert_success
}

# ── verify ──────────────────────────────────────────────────────────────────

@test "verify fails when not installed" {
    _load_module
    _sandbox_paths
    run verify
    assert_failure
}

@test "verify passes after install (runnable mocked binary on PATH)" {
    _load_module
    _sandbox_paths
    _mock_remote
    install
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run verify
    assert_success
}

# ── detect / is_recommended ─────────────────────────────────────────────────

@test "detect returns 0 on x86_64" {
    _load_module
    eval 'uname() { printf "x86_64\n"; }'
    run detect
    assert_success
}

@test "detect returns nonzero on non-x86_64 (upstream asset is x86_64-only)" {
    _load_module
    eval 'uname() { printf "aarch64\n"; }'
    run detect
    assert_failure
}

@test "is_recommended returns 0 when not installed" {
    _load_module
    eval 'is_installed() { return 1; }'
    run is_recommended
    assert_success
}

@test "is_recommended returns nonzero when already installed" {
    _load_module
    eval 'is_installed() { return 0; }'
    run is_recommended
    assert_failure
}

# ── Engine discovery (registry scan) ────────────────────────────────────────

@test "registry discovers neovim under --tag=editor" {
    # shellcheck source=../../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../../lib/registry.sh
    source "${LIB_DIR}/registry.sh"
    export INIT_UBUNTU_USER_MODULE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/user-module"
    registry_load_all "${MODULE_DIR}"
    run registry_list_names --tag=editor
    assert_success
    assert_output --partial "neovim"
}

# ── Standalone CLI (AC-25) ──────────────────────────────────────────────────

_standalone() {
    local _home="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${_home}"
    HOME="${_home}" XDG_STATE_HOME="" INIT_UBUNTU_STATE_DIR="" \
        run bash "${MODULE_DIR}/neovim.module.sh" "$@"
}

@test "standalone --help prints usage" {
    _standalone --help
    assert_success
    assert_output --partial "Usage:"
}

@test "standalone --version prints name + version" {
    _standalone --version
    assert_success
    assert_output --partial "neovim"
}

@test "standalone info prints metadata" {
    _standalone info
    assert_success
    assert_output --partial "name:        neovim"
    assert_output --partial "editor"
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

@test "standalone is-outdated degrades gracefully (optional phase, exit 2)" {
    # neovim implements no is_outdated(); module_standalone_main reports
    # the optional phase as not implemented with exit 2 (doc/module-spec.md).
    _standalone is-outdated
    [[ "${status}" -eq 2 ]]
    assert_output --partial "not implemented"
}

@test "standalone doctor degrades gracefully (optional phase, exit 2)" {
    _standalone doctor
    [[ "${status}" -eq 2 ]]
    assert_output --partial "not implemented"
}

@test "standalone --dry-run install leaves a fresh HOME empty" {
    local _home="${INIT_UBUNTU_TEST_SCRATCH}/home-clean"
    mkdir -p "${_home}"
    HOME="${_home}" XDG_STATE_HOME="" INIT_UBUNTU_STATE_DIR="" \
        run bash "${MODULE_DIR}/neovim.module.sh" install --dry-run
    assert_success
    [[ -z "$(find "${_home}" -type f 2>/dev/null)" ]]
}
