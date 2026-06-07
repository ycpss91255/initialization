#!/usr/bin/env bats
# test/unit/module/font_spec.bats — module/font.module.sh (issue #123, Batch-A)
#
# Coverage per PRD Q29: smoke / metadata / lifecycle presence / dry-run /
# no-side-fx / sidecar semantics (ADR-0001) / idempotency (AC-5) /
# standalone CLI (AC-25) / module-specific behaviors (multi-family Nerd Font
# download loop, graceful per-family download failure, fc-cache refresh).
#
# Pattern: codex_spec.bats (custom hand-written lifecycle). All non-dry-run
# install paths mock curl/unzip — Q46: gates have zero network deps.

bats_require_minimum_version 1.5.0

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
    # shellcheck source=../../../module/font.module.sh
    source "${MODULE_DIR}/font.module.sh"
}

# Point the mutable font dir into the per-test scratch dir so non-dry-run
# lifecycle runs never touch the real filesystem.
_sandbox_paths() {
    _FONTS_DIR="${INIT_UBUNTU_TEST_SCRATCH}/home/.local/share/fonts"
}

# Pretend all three families are already installed.
_make_installed() {
    local _f
    for _f in "${_NERD_FONTS[@]}"; do
        mkdir -p "${_FONTS_DIR}/${_f}"
    done
}

# Mock the network-touching pieces (Q46): curl drops an empty "zip", unzip
# is a no-op (install already mkdir-ed the family dir), fc-cache is inert
# (touches MOCK_FCCACHE_TOUCH when set, for spy assertions).
# MOCK_REMOTE_MODE picks the curl behaviour at call time:
#   ok (default) — every download succeeds
#   down         — every download fails
#   partial      — only the FiraCode URL fails (partial-failure path)
# Single definition site: redefining the same mock per scenario trips
# SC2317 in the linter (re-definitions are flagged as unreachable).
_mock_remote() {
    curl() {
        local _out="" _url=""
        while [[ $# -gt 0 ]]; do
            case "${1}" in
                -o) _out="${2}"; shift 2 ;;
                http*) _url="${1}"; shift ;;
                *)  shift ;;
            esac
        done
        case "${MOCK_REMOTE_MODE:-ok}" in
            down)    return 1 ;;
            partial) [[ "${_url}" == *"FiraCode"* ]] && return 1 ;;
        esac
        [[ -n "${_out}" ]] && : > "${_out}"
        return 0
    }
    unzip() { return 0; }
    fc-cache() {
        [[ -n "${MOCK_FCCACHE_TOUCH:-}" ]] && : > "${MOCK_FCCACHE_TOUCH}"
        return 0
    }
}

_mock_remote_ok()      { MOCK_REMOTE_MODE=ok;      _mock_remote; }
_mock_remote_down()    { MOCK_REMOTE_MODE=down;    _mock_remote; }
_mock_remote_partial() { MOCK_REMOTE_MODE=partial; _mock_remote; }

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "font module file exists" {
    [[ -f "${MODULE_DIR}/font.module.sh" ]]
}

@test "font module parses (bash -n)" {
    bash -n "${MODULE_DIR}/font.module.sh"
}

@test "sourcing in engine mode exits 0 and runs no lifecycle" {
    run _load_module
    assert_success
    refute_output --partial "DRY-RUN"
    refute_output --partial "download"
}

@test "engine mode does not invoke module_standalone_main" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

# ── Metadata (doc/module-spec.md §3, PRD §9.1) ──────────────────────────────

@test "NAME=font matches the filename stem" {
    _load_module
    [[ "${NAME}" == "font" ]]
}

@test "VERSION_PROVIDED is declared (latest)" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "latest" ]]
}

@test "CATEGORY=recommended" {
    _load_module
    [[ "${CATEGORY}" == "recommended" ]]
}

@test "TAGS contains font, nerd-font and desktop" {
    _load_module
    [[ " ${TAGS[*]} " == *" font "* ]]
    [[ " ${TAGS[*]} " == *" nerd-font "* ]]
    [[ " ${TAGS[*]} " == *" desktop "* ]]
}

@test "DEPENDS_ON is exactly apt-essentials (curl + unzip provider)" {
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

@test "POST_INSTALL_MESSAGE tells the user to switch the terminal font" {
    _load_module
    [[ "$(module_get_post_install_message en)" == *"Nerd Font"* ]]
}

@test "SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "SUPPORTED_PLATFORMS is desktop + wsl only (no server)" {
    _load_module
    [[ " ${SUPPORTED_PLATFORMS[*]} " == *" desktop "* ]]
    [[ " ${SUPPORTED_PLATFORMS[*]} " == *" wsl "* ]]
    [[ " ${SUPPORTED_PLATFORMS[*]} " != *" server "* ]]
}

@test "SUPPORTS_USER_HOME=true" {
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

@test "HOMEPAGE points at nerdfonts.com" {
    _load_module
    [[ "${HOMEPAGE}" == *"nerdfonts.com"* ]]
}

@test "TEST_VERIFY_CMD is declared for module_default_verify" {
    _load_module
    [[ -n "${TEST_VERIFY_CMD}" ]]
}

@test "module data: pinned release + three families + HOME font dir" {
    _load_module
    [[ "${_NERD_FONT_VERSION}" == v* ]]
    [[ "${#_NERD_FONTS[@]}" -eq 3 ]]
    [[ " ${_NERD_FONTS[*]} " == *" Hack "* ]]
    [[ " ${_NERD_FONTS[*]} " == *" FiraCode "* ]]
    [[ " ${_NERD_FONTS[*]} " == *" JetBrainsMono "* ]]
    [[ "${_FONTS_DIR}" == "${HOME}/.local/share/fonts" ]]
}

# ── Lifecycle presence (module-spec: mandatory phases resolvable) ───────────

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

@test "lifecycle: is_outdated() and doctor() are absent (optional phases)" {
    # Hand-written Batch-A module: optional read phases not implemented;
    # the standalone CLI degrades gracefully (exit 2, see AC-25 block below).
    _load_module
    run ! declare -F is_outdated
    run ! declare -F doctor
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

@test "install --dry-run writes nothing (no font dir, no state)" {
    _load_module
    _sandbox_paths
    _mock_remote_ok
    INIT_UBUNTU_DRY_RUN=true install
    [[ ! -e "${_FONTS_DIR}" ]]
    [[ -z "$(find "${INIT_UBUNTU_STATE_DIR}" -type f 2>/dev/null)" ]]
}

@test "remove --dry-run keeps existing font dirs" {
    _load_module
    _sandbox_paths
    _make_installed
    INIT_UBUNTU_DRY_RUN=true remove
    [[ -d "${_FONTS_DIR}/Hack" ]]
    [[ -d "${_FONTS_DIR}/FiraCode" ]]
    [[ -d "${_FONTS_DIR}/JetBrainsMono" ]]
}

@test "upgrade --dry-run keeps existing font dirs" {
    _load_module
    _sandbox_paths
    _make_installed
    INIT_UBUNTU_DRY_RUN=true upgrade
    [[ -d "${_FONTS_DIR}/Hack" ]]
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

# ── is_installed semantics (all three families required) ────────────────────

@test "is_installed fails on a clean system" {
    _load_module
    _sandbox_paths
    run is_installed
    assert_failure
}

@test "is_installed succeeds when all three family dirs exist" {
    _load_module
    _sandbox_paths
    _make_installed
    run is_installed
    assert_success
}

@test "is_installed fails when any single family is missing" {
    _load_module
    _sandbox_paths
    _make_installed
    rm -rf "${_FONTS_DIR}/FiraCode"
    run is_installed
    assert_failure
}

# ── Install (mocked remote, Q46) ────────────────────────────────────────────

@test "install creates all three family dirs (mocked remote)" {
    _load_module
    _sandbox_paths
    _mock_remote_ok
    run install
    assert_success
    [[ -d "${_FONTS_DIR}/Hack" ]]
    [[ -d "${_FONTS_DIR}/FiraCode" ]]
    [[ -d "${_FONTS_DIR}/JetBrainsMono" ]]
}

@test "install short-circuits when already installed (AC-5 idempotency)" {
    _load_module
    _sandbox_paths
    _make_installed
    run install
    assert_success
    assert_output --partial "already installed"
}

@test "second install run also exits 0 (AC-5 pattern, real is_installed)" {
    _load_module
    _sandbox_paths
    _mock_remote_ok
    install
    run install
    assert_success
}

@test "install refreshes the font cache via fc-cache (spy)" {
    _load_module
    _sandbox_paths
    _mock_remote_ok
    MOCK_FCCACHE_TOUCH="${INIT_UBUNTU_TEST_SCRATCH}/fc-cache-called"
    install
    [[ -f "${INIT_UBUNTU_TEST_SCRATCH}/fc-cache-called" ]]
}

@test "failed download warns + skips that family, still exits 0" {
    _load_module
    _sandbox_paths
    _mock_remote_down
    run install
    assert_success
    assert_output --partial "download failed"
    [[ ! -d "${_FONTS_DIR}/Hack" ]]
    [[ ! -d "${_FONTS_DIR}/FiraCode" ]]
    [[ ! -d "${_FONTS_DIR}/JetBrainsMono" ]]
}

@test "partial download failure keeps the families that succeeded" {
    _load_module
    _sandbox_paths
    _mock_remote_partial
    run install
    assert_success
    assert_output --partial "download failed for FiraCode"
    [[ -d "${_FONTS_DIR}/Hack" ]]
    [[ ! -d "${_FONTS_DIR}/FiraCode" ]]
    [[ -d "${_FONTS_DIR}/JetBrainsMono" ]]
}

# ── Sidecar semantics (ADR-0001) + state isolation (AC-23) ──────────────────

@test "install never touches state.json (AC-23 pattern)" {
    _load_module
    _sandbox_paths
    _mock_remote_ok
    install
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "install writes no Sidecar (Batch-A: version recording not yet wired)" {
    # Documents current behavior: font predates the ADR-0001 sidecar backfill
    # and records no versions/<name> file. If sidecar wiring lands, flip this
    # to assert the recorded version instead.
    _load_module
    _sandbox_paths
    _mock_remote_ok
    install
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/font" ]]
}

# ── Upgrade / Remove / Purge ────────────────────────────────────────────────

@test "upgrade wipes the family dirs and re-downloads" {
    _load_module
    _sandbox_paths
    _mock_remote_ok
    _make_installed
    : > "${_FONTS_DIR}/Hack/stale.ttf"
    upgrade
    [[ -d "${_FONTS_DIR}/Hack" ]]
    [[ ! -e "${_FONTS_DIR}/Hack/stale.ttf" ]]
}

@test "upgrade on a clean system falls through to install" {
    _load_module
    _sandbox_paths
    _mock_remote_ok
    run upgrade
    assert_success
    [[ -d "${_FONTS_DIR}/JetBrainsMono" ]]
}

@test "remove deletes the three family dirs but spares other fonts" {
    _load_module
    _sandbox_paths
    _make_installed
    mkdir -p "${_FONTS_DIR}/OtherFont"
    remove
    [[ ! -e "${_FONTS_DIR}/Hack" ]]
    [[ ! -e "${_FONTS_DIR}/FiraCode" ]]
    [[ ! -e "${_FONTS_DIR}/JetBrainsMono" ]]
    [[ -d "${_FONTS_DIR}/OtherFont" ]]
}

@test "remove on a clean system still exits 0 (idempotent)" {
    _load_module
    _sandbox_paths
    run remove
    assert_success
    assert_output --partial "not installed"
    run remove
    assert_success
}

@test "purge behaves like remove (no extra config to drop)" {
    _load_module
    _sandbox_paths
    _make_installed
    purge
    [[ ! -e "${_FONTS_DIR}/Hack" ]]
    run is_installed
    assert_failure
}

@test "purge on a clean system still exits 0 (idempotent)" {
    _load_module
    _sandbox_paths
    run purge
    assert_success
}

# ── verify ───────────────────────────────────────────────────────────────────

@test "verify fails when not installed" {
    _load_module
    _sandbox_paths
    run verify
    assert_failure
    assert_output --partial "verify failed"
}

@test "verify succeeds when installed and TEST_VERIFY_CMD passes" {
    _load_module
    _sandbox_paths
    _make_installed
    TEST_VERIFY_CMD="true"
    run verify
    assert_success
}

@test "verify fails when TEST_VERIFY_CMD fails despite dirs present" {
    _load_module
    _sandbox_paths
    _make_installed
    TEST_VERIFY_CMD="false"
    run verify
    assert_failure
}

# ── detect / is_recommended ─────────────────────────────────────────────────

@test "detect always returns 0 (platform gating is metadata-driven)" {
    _load_module
    run detect
    assert_success
}

@test "is_recommended returns 0 when not installed" {
    _load_module
    _sandbox_paths
    run is_recommended
    assert_success
}

@test "is_recommended returns nonzero when already installed" {
    _load_module
    _sandbox_paths
    _make_installed
    run is_recommended
    assert_failure
}

# ── Engine discovery (registry scan) ────────────────────────────────────────

@test "registry discovers font under --tag=nerd-font" {
    # shellcheck source=../../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../../lib/registry.sh
    source "${LIB_DIR}/registry.sh"
    export INIT_UBUNTU_USER_MODULE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/user-module"
    registry_load_all "${MODULE_DIR}"
    run registry_list_names --tag=nerd-font
    assert_success
    assert_output --partial "font"
}

# ── Standalone CLI (AC-25) ──────────────────────────────────────────────────

_standalone() {
    local _home="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${_home}"
    HOME="${_home}" XDG_STATE_HOME="" INIT_UBUNTU_STATE_DIR="" \
        run bash "${MODULE_DIR}/font.module.sh" "$@"
}

@test "standalone --help prints usage" {
    _standalone --help
    assert_success
    assert_output --partial "Usage:"
}

@test "standalone --version prints name + version" {
    _standalone --version
    assert_success
    assert_output --partial "font"
}

@test "standalone info prints metadata" {
    _standalone info
    assert_success
    assert_output --partial "name:        font"
    assert_output --partial "nerd-font"
}

@test "standalone status reports install state + missing is_outdated" {
    _standalone status
    assert_success
    assert_output --partial "installed:"
    assert_output --partial "(no is_outdated)"
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

@test "standalone is-outdated degrades gracefully (exit 2, not implemented)" {
    _standalone is-outdated
    [[ "${status}" -eq 2 ]]
    assert_output --partial "not implemented"
}

@test "standalone doctor degrades gracefully (exit 2, not implemented)" {
    _standalone doctor
    [[ "${status}" -eq 2 ]]
    assert_output --partial "not implemented"
}

@test "standalone --dry-run install leaves a fresh HOME empty" {
    local _home="${INIT_UBUNTU_TEST_SCRATCH}/home-clean"
    mkdir -p "${_home}"
    HOME="${_home}" XDG_STATE_HOME="" INIT_UBUNTU_STATE_DIR="" \
        run bash "${MODULE_DIR}/font.module.sh" install --dry-run
    assert_success
    [[ -z "$(find "${_home}" -type f 2>/dev/null)" ]]
}
