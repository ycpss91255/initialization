#!/usr/bin/env bats
# test/unit/module/notion_spec.bats — module/notion.module.sh (issue #65)
#
# Coverage per PRD Q29: smoke / metadata / lifecycle presence / dry-run /
# no-side-fx / sidecar (ADR-0001) / idempotency / is_outdated (mocked,
# Q46 zero-network) / doctor / standalone CLI (AC-25).
#
# notion rides the github-release archetype but consumes a .deb
# (anechunaev/notion-electron, Q50 / #35): install downloads the versioned
# .deb asset and hands it to `apt-get install ./<deb>`. All privileged /
# network side effects live in mockable private helpers
# (_notion_fetch_and_install_deb / _notion_pkg_remove) so this spec never
# touches apt or the network.

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
    # shellcheck source=../../../module/notion.module.sh
    source "${MODULE_DIR}/notion.module.sh"
}

# Point all mutable paths into the per-test scratch dir so non-dry-run
# lifecycle runs never touch the real filesystem.
_sandbox_paths() {
    CONFIG_PATHS=("${INIT_UBUNTU_TEST_SCRATCH}/home/.config/notion-electron")
}

_sidecar_file() {
    printf '%s/versions/notion' "${INIT_UBUNTU_STATE_DIR}"
}

_pkg_marker() {
    printf '%s/notion-electron.installed' "${INIT_UBUNTU_TEST_SCRATCH}"
}

# Mock the network/apt-touching pieces (Q46: gates have zero network deps).
# Upstream tags look like v2.1.0; the module normalises that to 2.1.0.
# dpkg state is faked through a marker file in the scratch dir so the real
# is_installed() code path is exercised.
_mock_remote() {
    local _tag="${1:-v2.1.0}"
    eval "get_github_pkg_latest_version() { local -n _out=\"\${1}\"; _out=\"${_tag}\"; }"
    _notion_fetch_and_install_deb() {
        : > "$(_pkg_marker)"
    }
    _notion_pkg_remove() {
        rm -f "$(_pkg_marker)"
    }
    dpkg() {
        [[ -e "$(_pkg_marker)" ]] || return 1
        printf 'ii  notion-electron 2.1.0 amd64 Unofficial Notion client\n'
    }
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "notion module file exists" {
    [[ -f "${MODULE_DIR}/notion.module.sh" ]]
}

@test "notion module parses (bash -n)" {
    bash -n "${MODULE_DIR}/notion.module.sh"
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

@test "NAME=notion matches the filename stem" {
    _load_module
    [[ "${NAME}" == "notion" ]]
}

@test "VERSION_PROVIDED is declared (latest)" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "latest" ]]
}

@test "CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "TAGS contains notes" {
    _load_module
    [[ " ${TAGS[*]} " == *" notes "* ]]
}

@test "DEPENDS_ON is exactly apt-essentials (module names only, Q39)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 1 ]]
    [[ "${DEPENDS_ON[0]}" == "apt-essentials" ]]
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

@test "SUPPORTED_PLATFORMS is desktop only (Q50)" {
    _load_module
    [[ "${#SUPPORTED_PLATFORMS[@]}" -eq 1 ]]
    [[ "${SUPPORTED_PLATFORMS[0]}" == "desktop" ]]
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

@test "HOMEPAGE points at the upstream repo" {
    _load_module
    [[ "${HOMEPAGE}" == *"anechunaev/notion-electron"* ]]
}

@test "archetype data: GITHUB_REPO + deb package name" {
    _load_module
    [[ "${GITHUB_REPO}" == "anechunaev/notion-electron" ]]
    [[ "${NOTION_DEB_PKG}" == "notion-electron" ]]
}

@test "GITHUB_ASSET_PATTERN placeholder is a .deb asset" {
    _load_module
    [[ "${GITHUB_ASSET_PATTERN}" == Notion_Electron-*.deb ]]
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

@test "install --dry-run writes nothing (no sidecar, no pkg marker)" {
    _load_module
    _sandbox_paths
    _mock_remote
    INIT_UBUNTU_DRY_RUN=true install
    [[ ! -e "$(_sidecar_file)" ]]
    [[ ! -e "$(_pkg_marker)" ]]
}

@test "remove --dry-run does not delete an existing sidecar" {
    _load_module
    _sandbox_paths
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '2.1.0\n' > "$(_sidecar_file)"
    INIT_UBUNTU_DRY_RUN=true remove
    [[ -f "$(_sidecar_file)" ]]
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

@test "install fetches the .deb and exits 0 (mocked remote)" {
    _load_module
    _sandbox_paths
    _mock_remote "v2.1.0"
    run install
    assert_success
}

@test "install resolves the versioned arch-specific .deb asset name" {
    _load_module
    _sandbox_paths
    _mock_remote "v2.1.0"
    eval 'uname() { printf "x86_64\n"; }'
    install
    [[ "${GITHUB_ASSET_PATTERN}" == "Notion_Electron-2.1.0-amd64.deb" ]]
}

@test "asset resolve maps aarch64 to the arm64 .deb" {
    _load_module
    _mock_remote "v2.1.0"
    eval 'uname() { printf "aarch64\n"; }'
    _notion_resolve_asset_pattern
    [[ "${GITHUB_ASSET_PATTERN}" == "Notion_Electron-2.1.0-arm64.deb" ]]
}

@test "install writes the Sidecar with the normalised version" {
    _load_module
    _sandbox_paths
    _mock_remote "v2.1.0"
    install
    [[ -f "$(_sidecar_file)" ]]
    [[ "$(cat "$(_sidecar_file)")" == "2.1.0" ]]
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
    assert_output --partial "already installed"
}

@test "failed fetch leaves no Sidecar behind" {
    _load_module
    _sandbox_paths
    _mock_remote
    eval '_notion_fetch_and_install_deb() { return 1; }'
    run install
    assert_failure
    [[ ! -e "$(_sidecar_file)" ]]
}

@test "install fails when version resolve fails (versioned asset URL)" {
    _load_module
    _sandbox_paths
    _mock_remote
    eval 'get_github_pkg_latest_version() { return 1; }'
    run install
    assert_failure
    [[ ! -e "$(_sidecar_file)" ]]
}

@test "install fails on an arch upstream does not ship" {
    _load_module
    _sandbox_paths
    _mock_remote
    eval 'uname() { printf "armv7l\n"; }'
    run install
    assert_failure
    [[ ! -e "$(_sidecar_file)" ]]
}

@test "upgrade re-fetches and updates the Sidecar version" {
    _load_module
    _sandbox_paths
    _mock_remote "v2.1.0"
    install
    _mock_remote "v2.2.0"
    upgrade
    [[ "$(cat "$(_sidecar_file)")" == "2.2.0" ]]
}

@test "remove uninstalls the package and deletes the Sidecar" {
    _load_module
    _sandbox_paths
    _mock_remote
    install
    remove
    [[ ! -e "$(_pkg_marker)" ]]
    [[ ! -e "$(_sidecar_file)" ]]
}

@test "remove on a clean system still exits 0 (idempotent)" {
    _load_module
    _sandbox_paths
    run remove
    assert_success
    run remove
    assert_success
}

@test "purge deletes Sidecar and CONFIG_PATHS" {
    _load_module
    _sandbox_paths
    _mock_remote
    install
    mkdir -p "${CONFIG_PATHS[0]}"
    : > "${CONFIG_PATHS[0]}/config.json"
    purge
    [[ ! -e "$(_pkg_marker)" ]]
    [[ ! -e "$(_sidecar_file)" ]]
    [[ ! -e "${CONFIG_PATHS[0]}" ]]
}

@test "purge on a clean system still exits 0 (idempotent)" {
    _load_module
    _sandbox_paths
    run purge
    assert_success
}

# ── is_outdated (mocked remote, Q46) ────────────────────────────────────────

@test "is_outdated returns nonzero when not installed" {
    _load_module
    _sandbox_paths
    eval 'is_installed() { return 1; }'
    run is_outdated
    assert_failure
}

@test "is_outdated returns nonzero when local matches latest" {
    _load_module
    _sandbox_paths
    _mock_remote "v2.1.0"
    install
    run is_outdated
    assert_failure
}

@test "is_outdated returns 0 when a newer release exists" {
    _load_module
    _sandbox_paths
    _mock_remote "v2.1.0"
    install
    eval 'get_github_pkg_latest_version() { local -n _out="${1}"; _out="v2.2.0"; }'
    run is_outdated
    assert_success
}

@test "is_outdated normalises the v tag prefix before comparing" {
    _load_module
    _sandbox_paths
    _mock_remote "v2.1.0"
    install
    # Same release, raw tag form: must NOT be reported as outdated.
    eval 'get_github_pkg_latest_version() { local -n _out="${1}"; _out="v2.1.0"; }'
    run is_outdated
    assert_failure
}

@test "is_outdated returns nonzero when the remote query fails" {
    _load_module
    _sandbox_paths
    _mock_remote "v2.1.0"
    install
    eval 'get_github_pkg_latest_version() { return 1; }'
    run is_outdated
    assert_failure
}

# ── doctor (Sidecar invariant: is_installed ⟷ Sidecar exists) ───────────────

@test "doctor passes on a clean system (not installed, no Sidecar)" {
    _load_module
    _sandbox_paths
    run doctor
    assert_success
}

@test "doctor passes after a successful install" {
    _load_module
    _sandbox_paths
    _mock_remote
    install
    run doctor
    assert_success
}

@test "doctor flags drift: installed but Sidecar missing" {
    _load_module
    _sandbox_paths
    _mock_remote
    install
    rm -f "$(_sidecar_file)"
    run doctor
    assert_failure
}

@test "doctor flags drift: Sidecar exists but not installed" {
    _load_module
    _sandbox_paths
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '2.1.0\n' > "$(_sidecar_file)"
    run doctor
    assert_failure
}

# ── detect / is_recommended ─────────────────────────────────────────────────

@test "detect returns 0 on x86_64 (amd64 .deb shipped upstream)" {
    _load_module
    # test-tools image is Alpine: stub apt-get (command -v sees functions)
    eval 'apt-get() { :; }'
    eval 'uname() { printf "x86_64\n"; }'
    run detect
    assert_success
}

@test "detect returns 0 on aarch64 (arm64 .deb shipped upstream)" {
    _load_module
    eval 'apt-get() { :; }'
    eval 'uname() { printf "aarch64\n"; }'
    run detect
    assert_success
}

@test "detect returns nonzero on unsupported arch" {
    _load_module
    eval 'apt-get() { :; }'
    eval 'uname() { printf "armv7l\n"; }'
    run detect
    assert_failure
}

@test "detect returns nonzero when apt-get is unavailable" {
    _load_module
    eval 'uname() { printf "x86_64\n"; }'
    PATH="/nonexistent" run detect
    assert_failure
}

@test "is_recommended returns 0 on desktop when not installed" {
    _load_module
    eval 'is_installed() { return 1; }'
    INIT_UBUNTU_FORM_FACTOR=desktop run is_recommended
    assert_success
}

@test "is_recommended returns nonzero when already installed" {
    _load_module
    eval 'is_installed() { return 0; }'
    INIT_UBUNTU_FORM_FACTOR=desktop run is_recommended
    assert_failure
}

@test "is_recommended returns nonzero on non-desktop form factors (Q50)" {
    _load_module
    eval 'is_installed() { return 1; }'
    INIT_UBUNTU_FORM_FACTOR=server run is_recommended
    assert_failure
}

# ── Engine discovery (registry scan) ────────────────────────────────────────

@test "registry discovers notion under --tag=notes" {
    # shellcheck source=../../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../../lib/registry.sh
    source "${LIB_DIR}/registry.sh"
    export INIT_UBUNTU_USER_MODULE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/user-module"
    registry_load_all "${MODULE_DIR}"
    run registry_list_names --tag=notes
    assert_success
    assert_output --partial "notion"
}

# ── Standalone CLI (AC-25: all 10 phases, never not-implemented exit 2) ─────

_standalone() {
    local _home="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${_home}"
    HOME="${_home}" XDG_STATE_HOME="" INIT_UBUNTU_STATE_DIR="" \
        run bash "${MODULE_DIR}/notion.module.sh" "$@"
}

@test "standalone --help prints usage" {
    _standalone --help
    assert_success
    assert_output --partial "Usage:"
}

@test "standalone --version prints name + version" {
    _standalone --version
    assert_success
    assert_output --partial "notion"
}

@test "standalone info prints metadata" {
    _standalone info
    assert_success
    assert_output --partial "name:        notion"
    assert_output --partial "notes"
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
        run bash "${MODULE_DIR}/notion.module.sh" install --dry-run
    assert_success
    [[ -z "$(find "${_home}" -type f 2>/dev/null)" ]]
}
