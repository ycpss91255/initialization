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
