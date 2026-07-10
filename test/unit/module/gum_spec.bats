#!/usr/bin/env bats
# test/unit/module/gum_spec.bats — module/gum.module.sh (issue #171)
#
# gum = the preferred modern TUI backend (gum > whiptail, dialog dropped).
# Coverage mirrors the github-release archetype spec (cf. lazygit_spec.bats):
# smoke / metadata / lifecycle presence / dry-run / no-side-fx / sidecar
# (ADR-0001) / idempotency / is_outdated (mocked, zero-network) / doctor /
# multi-arch asset resolution / standalone CLI (AC-25).

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    # HERMETIC is_installed (issue #180): the github-release archetype's
    # is_installed() falls back to `command -v gum` on PATH when the
    # scratch-scoped BIN_LINK is absent. The test-tools image bakes
    # /usr/bin/gum (for the AC-10 TUI smoke, issue #171), so that PATH
    # fallback would report a never-installed module as present and corrupt
    # every install / sidecar / doctor / is_outdated assertion. Engaging the
    # existing offline seam (INIT_UBUNTU_TEST_GH_FIXTURE_DIR, lib/module_helper.sh)
    # suppresses the PATH fallback exactly as the #175 integration harness
    # does — so is_installed reflects ONLY the scratch BIN_LINK, regardless of
    # what binaries the image bakes. No production change; mirrors the
    # integration-side isolation.
    # SR-01: the offline seam only activates under the dedicated test-mode flag
    # (INIT_UBUNTU_TEST_MODE=1). Production never sets it, so setting the fixture
    # dir alone can no longer swap the payload.
    export INIT_UBUNTU_TEST_MODE=1
    export INIT_UBUNTU_TEST_GH_FIXTURE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/gh-fixture"
    mkdir -p "${INIT_UBUNTU_TEST_GH_FIXTURE_DIR}"
}

teardown() {
    unset INIT_UBUNTU_TEST_GH_FIXTURE_DIR INIT_UBUNTU_TEST_MODE
    teardown_test_env
}

_load_module() {
    # shellcheck source=../../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../../lib/general.sh
    source "${LIB_DIR}/general.sh"
    # shellcheck source=../../../lib/module_helper.sh
    source "${LIB_DIR}/module_helper.sh"
    # shellcheck source=../../../module/gum.module.sh
    source "${MODULE_DIR}/gum.module.sh"
}

# Point all mutable paths into the per-test scratch dir so non-dry-run
# lifecycle runs never touch the real filesystem.
_sandbox_paths() {
    INSTALL_DIR="${INIT_UBUNTU_TEST_SCRATCH}/share/gum"
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/bin/gum"
    USE_SUDO=false
    CONFIG_PATHS=("${INIT_UBUNTU_TEST_SCRATCH}/home/.config/gum")
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
}

_sidecar_file() {
    printf '%s/versions/gum' "${INIT_UBUNTU_STATE_DIR}"
}

# Mock the network-touching pieces (gates have zero network deps). Also pin a
# deterministic arch so resolution is reproducible across runners.
_mock_remote() {
    local _ver="${1:-0.17.0}"
    eval "get_github_pkg_latest_version() { local -n _out=\"\${1}\"; _out=\"${_ver}\"; }"
    eval 'uname() { printf "x86_64\n"; }'
    _module_github_release_fetch_and_install() {
        mkdir -p "${INSTALL_DIR}"
        : > "${INSTALL_DIR}/gum"
        chmod +x "${INSTALL_DIR}/gum"
        ln -sfn "${INSTALL_DIR}/gum" "${BIN_LINK}"
    }
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "gum module file exists" {
    [[ -f "${MODULE_DIR}/gum.module.sh" ]]
}

@test "gum module parses (bash -n)" {
    bash -n "${MODULE_DIR}/gum.module.sh"
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

# ── Metadata (doc/module-spec.md §3) ────────────────────────────────────────

@test "NAME=gum matches the filename stem" {
    _load_module
    [[ "${NAME}" == "gum" ]]
}

@test "VERSION_PROVIDED is declared (latest)" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "latest" ]]
}

@test "CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "TAGS contains tui" {
    _load_module
    [[ " ${TAGS[*]} " == *" tui "* ]]
}

@test "DEPENDS_ON is exactly curl" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 1 ]]
    [[ "${DEPENDS_ON[0]}" == "curl" ]]
}

@test "every DEPENDS_ON entry is a real module name" {
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

@test "SUPPORTS_USER_HOME=true (installs to ~/.local/bin, no sudo)" {
    _load_module
    [[ "${SUPPORTS_USER_HOME}" == "true" ]]
}

@test "INSTALL_TARGET_DEFAULT=user-home" {
    _load_module
    [[ "${INSTALL_TARGET_DEFAULT}" == "user-home" ]]
}

@test "USE_SUDO=false (no host package installs / no root)" {
    _load_module
    [[ "${USE_SUDO}" == "false" ]]
}

@test "BIN_LINK lands under ~/.local/bin" {
    _load_module
    [[ "${BIN_LINK}" == *"/.local/bin/gum" ]]
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
    [[ "${HOMEPAGE}" == *"charmbracelet/gum"* ]]
}

@test "archetype data: GITHUB_REPO / BIN_NAME / STRIP_COMPONENTS" {
    _load_module
    [[ "${GITHUB_REPO}" == "charmbracelet/gum" ]]
    [[ "${BIN_NAME}" == "gum" ]]
    # tarball nests gum_<ver>_Linux_<arch>/gum → strip one component
    [[ "${STRIP_COMPONENTS}" -eq 1 ]]
    [[ "${BIN_PATH_IN_TAR}" == "gum" ]]
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

@test "install --dry-run writes nothing (no sidecar, no install dir)" {
    _load_module
    _sandbox_paths
    _mock_remote
    INIT_UBUNTU_DRY_RUN=true install
    [[ ! -e "$(_sidecar_file)" ]]
    [[ ! -e "${INSTALL_DIR}" ]]
}

@test "remove --dry-run does not delete an existing sidecar" {
    _load_module
    _sandbox_paths
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '0.17.0\n' > "$(_sidecar_file)"
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

# ── Multi-arch asset resolution (issue #171 asset map) ──────────────────────

@test "asset pattern resolves x86_64 -> gum_<ver>_Linux_x86_64.tar.gz" {
    _load_module
    _sandbox_paths
    eval 'get_github_pkg_latest_version() { local -n _out="${1}"; _out="0.17.0"; }'
    eval 'uname() { printf "x86_64\n"; }'
    _gum_resolve_asset_pattern
    [[ "${GITHUB_ASSET_PATTERN}" == "gum_0.17.0_Linux_x86_64.tar.gz" ]]
}

@test "asset pattern resolves aarch64 -> _arm64 (rpi4/5, Jetson)" {
    _load_module
    _sandbox_paths
    eval 'get_github_pkg_latest_version() { local -n _out="${1}"; _out="0.17.0"; }'
    eval 'uname() { printf "aarch64\n"; }'
    _gum_resolve_asset_pattern
    [[ "${GITHUB_ASSET_PATTERN}" == "gum_0.17.0_Linux_arm64.tar.gz" ]]
}

@test "asset pattern resolves armv7l -> _armv7" {
    _load_module
    _sandbox_paths
    eval 'get_github_pkg_latest_version() { local -n _out="${1}"; _out="0.17.0"; }'
    eval 'uname() { printf "armv7l\n"; }'
    _gum_resolve_asset_pattern
    [[ "${GITHUB_ASSET_PATTERN}" == "gum_0.17.0_Linux_armv7.tar.gz" ]]
}

@test "asset resolution fails on an unsupported architecture" {
    _load_module
    eval 'get_github_pkg_latest_version() { local -n _out="${1}"; _out="0.17.0"; }'
    eval 'uname() { printf "riscv64\n"; }'
    run _gum_resolve_asset_pattern
    assert_failure
}

@test "asset resolution fails when the latest version cannot be resolved" {
    _load_module
    eval 'uname() { printf "x86_64\n"; }'
    eval 'get_github_pkg_latest_version() { return 1; }'
    run _gum_resolve_asset_pattern
    assert_failure
}

# ── Install + Sidecar (ADR-0001 / module-spec §4.7.4) ───────────────────────

@test "install fetches and exits 0 (mocked remote)" {
    _load_module
    _sandbox_paths
    _mock_remote "0.17.0"
    run install
    assert_success
    [[ -x "${BIN_LINK}" ]]
}

@test "install writes the Sidecar with the resolved version" {
    _load_module
    _sandbox_paths
    _mock_remote "0.17.0"
    module_standalone_main install
    [[ -f "$(_sidecar_file)" ]]
    [[ "$(cat "$(_sidecar_file)")" == "0.17.0" ]]
}

@test "standalone install never touches state.json" {
    _load_module
    _sandbox_paths
    _mock_remote
    module_standalone_main install
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "install short-circuits when already installed (idempotency)" {
    _load_module
    _sandbox_paths
    _mock_remote
    eval 'is_installed() { return 0; }'
    run install
    assert_success
    assert_output --partial "already installed"
}

@test "second install run also exits 0 (real is_installed)" {
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
    eval '_module_github_release_fetch_and_install() { return 1; }'
    run module_standalone_main install
    assert_failure
    [[ ! -e "$(_sidecar_file)" ]]
}

@test "install fails when the latest version cannot be resolved" {
    _load_module
    _sandbox_paths
    _mock_remote
    eval 'get_github_pkg_latest_version() { return 1; }'
    run module_standalone_main install
    assert_failure
    [[ ! -e "$(_sidecar_file)" ]]
}

@test "upgrade re-fetches and updates the Sidecar version" {
    _load_module
    _sandbox_paths
    _mock_remote "0.16.0"
    module_standalone_main install
    _mock_remote "0.17.0"
    module_standalone_main upgrade
    [[ "$(cat "$(_sidecar_file)")" == "0.17.0" ]]
}

@test "remove deletes install dir, symlink and Sidecar" {
    _load_module
    _sandbox_paths
    _mock_remote
    module_standalone_main install
    module_standalone_main remove
    [[ ! -e "${INSTALL_DIR}" ]]
    [[ ! -e "${BIN_LINK}" ]]
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

@test "purge deletes the Sidecar" {
    _load_module
    _sandbox_paths
    _mock_remote
    module_standalone_main install
    module_standalone_main purge
    [[ ! -e "$(_sidecar_file)" ]]
    [[ ! -e "${BIN_LINK}" ]]
}

@test "purge on a clean system still exits 0 (idempotent)" {
    _load_module
    _sandbox_paths
    run purge
    assert_success
}

# ── is_outdated (mocked remote, zero-network) ───────────────────────────────

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
    _mock_remote "0.17.0"
    module_standalone_main install
    run is_outdated
    assert_failure
}

@test "is_outdated returns 0 when a newer release exists" {
    _load_module
    _sandbox_paths
    _mock_remote "0.16.0"
    module_standalone_main install
    eval 'get_github_pkg_latest_version() { local -n _out="${1}"; _out="0.17.0"; }'
    run is_outdated
    assert_success
}

@test "is_outdated returns nonzero when the remote query fails" {
    _load_module
    _sandbox_paths
    _mock_remote "0.17.0"
    module_standalone_main install
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
    module_standalone_main install
    run doctor
    assert_success
}

@test "doctor flags drift: installed but Sidecar missing" {
    _load_module
    _sandbox_paths
    _mock_remote
    module_standalone_main install
    rm -f "$(_sidecar_file)"
    run doctor
    assert_failure
}

@test "doctor flags drift: Sidecar exists but not installed" {
    _load_module
    _sandbox_paths
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '0.17.0\n' > "$(_sidecar_file)"
    run doctor
    assert_failure
}

# ── detect / is_recommended ─────────────────────────────────────────────────

@test "detect returns 0 on x86_64" {
    _load_module
    eval 'uname() { printf "x86_64\n"; }'
    run detect
    assert_success
}

@test "detect returns 0 on aarch64 (multi-arch, unlike x86_64-only modules)" {
    _load_module
    eval 'uname() { printf "aarch64\n"; }'
    run detect
    assert_success
}

@test "detect returns 0 on armv7l" {
    _load_module
    eval 'uname() { printf "armv7l\n"; }'
    run detect
    assert_success
}

@test "detect returns nonzero on an unsupported architecture" {
    _load_module
    eval 'uname() { printf "riscv64\n"; }'
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

@test "registry discovers gum under --tag=tui" {
    # shellcheck source=../../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../../lib/registry.sh
    source "${LIB_DIR}/registry.sh"
    export INIT_UBUNTU_USER_MODULE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/user-module"
    registry_load_all "${MODULE_DIR}"
    run registry_list_names --tag=tui
    assert_success
    assert_output --partial "gum"
}

# ── Standalone CLI (AC-25: all 10 phases, never not-implemented exit 2) ─────

_standalone() {
    local _home="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${_home}"
    HOME="${_home}" XDG_STATE_HOME="" INIT_UBUNTU_STATE_DIR="" \
        run bash "${MODULE_DIR}/gum.module.sh" "$@"
}

@test "standalone --help prints usage" {
    _standalone --help
    assert_success
    assert_output --partial "Usage:"
}

@test "standalone --version prints name + version" {
    _standalone --version
    assert_success
    assert_output --partial "gum"
}

@test "standalone info prints metadata" {
    _standalone info
    assert_success
    assert_output --partial "name:        gum"
    assert_output --partial "tui"
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
        run bash "${MODULE_DIR}/gum.module.sh" install --dry-run
    assert_success
    [[ -z "$(find "${_home}" -type f 2>/dev/null)" ]]
}
