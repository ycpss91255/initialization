#!/usr/bin/env bats
# shellcheck disable=SC2317  # mocks defined inside @test blocks (e.g. `is_installed() { return 0; }`) are dispatched indirectly via the module under test or `run` — https://www.shellcheck.net/wiki/SC2317
# test/unit/module/batcat_spec.bats — module/batcat.module.sh
#
# Per Q29: smoke / metadata / lifecycle dry-run / no-side-fx / idempotency /
# standalone CLI / module-specific (rc-file alias correctness — the issue #1
# copy-paste bug class — and sidecar lifecycle per ADR-0001).

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
    # shellcheck source=../../../module/batcat.module.sh
    source "${MODULE_DIR}/batcat.module.sh"
}

# _standalone_module runs the module as a self-contained CLI (the same
# entry users hit when they type `bash module/batcat.module.sh ...`).
_standalone_module() {
    bash "${MODULE_DIR}/batcat.module.sh" "$@"
}

# Point HOME at a scratch dir (with rc files) so alias writes never touch
# the real container HOME.
_scratch_home() {
    HOME="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${HOME}"
    export HOME
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "batcat module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/batcat.module.sh"
    assert_success
}

@test "batcat module sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "batcat module defines all 10 lifecycle functions" {
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

@test "batcat module declares NAME=batcat" {
    _load_module
    [[ "${NAME}" == "batcat" ]]
}

@test "batcat module CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "batcat module TAGS contains cli-essentials" {
    _load_module
    [[ " ${TAGS[*]} " == *" cli-essentials "* ]]
}

@test "batcat DEPENDS_ON is empty (issue #53 / Q39)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 0 ]]
}

@test "batcat DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "batcat module_get_description returns language-specific text + en fallback" {
    _load_module
    [[ "$(module_get_description en)" == *"cat"* ]]
    [[ -n "$(module_get_description zh-TW)" ]]
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "batcat SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "batcat module RISK_LEVEL=low" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
}

@test "batcat module VERSION_PROVIDED=apt-managed" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "apt-managed" ]]
}

@test "batcat HOMEPAGE points at upstream sharkdp/bat" {
    _load_module
    [[ "${HOMEPAGE}" == *"sharkdp/bat"* ]]
}

@test "batcat archetype data installs the apt 'bat' package" {
    _load_module
    [[ " ${APT_PKGS[*]} " == *" bat "* ]]
}

@test "batcat declares LEGACY_DOTFILE=true (writes ~/.bashrc, spec §6.1)" {
    _load_module
    [[ "${LEGACY_DOTFILE}" == "true" ]]
}

# ── rc-file alias correctness (issue #1 copy-paste bug class) ────────────────
# The apt package is `bat` but the Ubuntu binary is `batcat`. Every alias
# the module writes must (a) guard on the real binary `batcat` and
# (b) point its target at `batcat` — never at another tool.

@test "alias lines guard on and target the batcat binary" {
    _load_module
    [[ "${#_BATCAT_ALIAS_LINES[@]}" -gt 0 ]]
    local _line
    for _line in "${_BATCAT_ALIAS_LINES[@]}"; do
        [[ "${_line}" == *"command -v batcat"* ]]
        [[ "${_line}" == *"='batcat'"* ]]
    done
}

@test "aliases map cat and bat to batcat (cat replacement intent)" {
    _load_module
    [[ " ${_BATCAT_ALIAS_LINES[*]} " == *"alias cat='batcat'"* ]]
    [[ " ${_BATCAT_ALIAS_LINES[*]} " == *"alias bat='batcat'"* ]]
}

@test "every alias line carries the removal marker for purge" {
    _load_module
    local _line
    for _line in "${_BATCAT_ALIAS_LINES[@]}"; do
        [[ "${_line}" == *"# init_ubuntu:batcat"* ]]
    done
}

@test "_batcat_add_aliases appends alias lines to an existing bashrc" {
    _load_module
    _scratch_home
    touch "${HOME}/.bashrc"
    _batcat_add_aliases
    run grep -F "alias cat='batcat'" "${HOME}/.bashrc"
    assert_success
    run grep -F "alias bat='batcat'" "${HOME}/.bashrc"
    assert_success
}

@test "_batcat_add_aliases is idempotent (no duplicate lines)" {
    _load_module
    _scratch_home
    touch "${HOME}/.bashrc"
    _batcat_add_aliases
    _batcat_add_aliases
    [[ "$(grep -cF "alias cat='batcat'" "${HOME}/.bashrc")" -eq 1 ]]
}

@test "_batcat_add_aliases skips rc files that do not exist" {
    _load_module
    _scratch_home
    # No .bashrc / .zshrc in scratch home.
    _batcat_add_aliases
    [[ ! -e "${HOME}/.bashrc" ]]
    [[ ! -e "${HOME}/.zshrc" ]]
}

@test "_batcat_add_aliases also covers zshrc when present" {
    _load_module
    _scratch_home
    touch "${HOME}/.zshrc"
    _batcat_add_aliases
    run grep -F "alias cat='batcat'" "${HOME}/.zshrc"
    assert_success
}

@test "_batcat_remove_aliases strips only marked lines" {
    _load_module
    _scratch_home
    {
        printf '%s\n' "export KEEP_ME=1"
        printf '%s\n' "${_BATCAT_ALIAS_LINES[@]}"
    } > "${HOME}/.bashrc"
    _batcat_remove_aliases
    run grep -F "alias cat='batcat'" "${HOME}/.bashrc"
    assert_failure
    run grep -F "KEEP_ME" "${HOME}/.bashrc"
    assert_success
}

# ── is_installed ─────────────────────────────────────────────────────────────

@test "is_installed returns nonzero on a fresh test container" {
    _load_module
    run is_installed
    assert_failure
}

@test "is_installed returns zero when dpkg reports bat installed" {
    _load_module
    dpkg() { printf 'ii  bat  0.24.0  amd64  cat clone\n'; }
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
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/batcat" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "dry-run install does not touch rc files" {
    _load_module
    _scratch_home
    touch "${HOME}/.bashrc"
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ ! -s "${HOME}/.bashrc" ]]
}

@test "dry-run remove leaves an existing sidecar in place" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '0.24.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/batcat"
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/batcat" ]]
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

@test "install writes the sidecar with the dpkg version" {
    _load_module
    _scratch_home
    module_default_apt_install() { return 0; }
    dpkg-query() { printf '0.24.0'; }
    module_standalone_main install
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/batcat" ]]
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/batcat")" == "0.24.0" ]]
}

@test "install never touches state.json (ADR-0001 / AC-23 pattern)" {
    _load_module
    _scratch_home
    printf '{"schema_version":"0.1.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    module_default_apt_install() { return 0; }
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "failed apt install leaves no sidecar behind (ADR-0015)" {
    _load_module
    _scratch_home
    module_default_apt_install() { return 1; }
    run module_standalone_main install
    assert_failure
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/batcat" ]]
}

@test "upgrade refreshes the sidecar version" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '0.20.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/batcat"
    module_default_apt_upgrade() { return 0; }
    dpkg-query() { printf '9.9.9'; }
    module_standalone_main upgrade
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/batcat")" == "9.9.9" ]]
}

@test "remove deletes the sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '0.24.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/batcat"
    module_default_apt_remove() { return 0; }
    module_standalone_main remove
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/batcat" ]]
}

@test "purge deletes the sidecar" {
    _load_module
    _scratch_home
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '0.24.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/batcat"
    module_default_apt_purge() { return 0; }
    module_standalone_main purge
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/batcat" ]]
}

@test "purge strips the alias lines from rc files" {
    _load_module
    _scratch_home
    printf '%s\n' "${_BATCAT_ALIAS_LINES[@]}" > "${HOME}/.bashrc"
    module_default_apt_purge() { return 0; }
    purge
    run grep -F "alias cat='batcat'" "${HOME}/.bashrc"
    assert_failure
}

@test "remove keeps the alias lines (user config preserved, spec §4.7.4)" {
    _load_module
    _scratch_home
    printf '%s\n' "${_BATCAT_ALIAS_LINES[@]}" > "${HOME}/.bashrc"
    module_default_apt_remove() { return 0; }
    remove
    run grep -F "alias cat='batcat'" "${HOME}/.bashrc"
    assert_success
}

# ── Idempotency (AC-5 pattern) ───────────────────────────────────────────────

@test "install short-circuits when is_installed returns 0 (idempotency)" {
    _load_module
    _scratch_home
    is_installed() { return 0; }
    run install
    assert_success
    assert_output --partial "already installed"
}

@test "install twice with apt mocked exits 0 both times" {
    _load_module
    _scratch_home
    touch "${HOME}/.bashrc"
    module_default_apt_install() { return 0; }
    dpkg-query() { printf '0.24.0'; }
    run install
    assert_success
    run install
    assert_success
}

@test "remove is idempotent — second run still exits 0" {
    _load_module
    module_default_apt_remove() { return 0; }
    run remove
    assert_success
    run remove
    assert_success
}

@test "purge is idempotent — second run still exits 0" {
    _load_module
    _scratch_home
    module_default_apt_purge() { return 0; }
    run purge
    assert_success
    run purge
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

@test "doctor passes when installed and batcat answers --version" {
    _load_module
    is_installed() { return 0; }
    batcat() { printf 'bat 0.24.0\n'; }
    run doctor
    assert_success
}

@test "doctor (inherited default) passes when installed, fails when not" {
    # batcat now inherits module_default_doctor (is_installed + warn). The
    # binary --version check moved to verify (TEST_VERIFY_CMD), so doctor's
    # pass/fail tracks is_installed only.
    _load_module
    is_installed() { return 0; }
    run doctor
    assert_success
    is_installed() { return 1; }
    run doctor
    assert_failure
    assert_output --partial "not installed"
}

@test "is_outdated returns zero when apt lists bat as upgradable" {
    _load_module
    apt() { printf 'bat/jammy-updates 0.99.0 amd64 [upgradable from: 0.24.0]\n'; }
    run is_outdated
    assert_success
}

@test "is_outdated returns nonzero when apt lists no bat upgrade" {
    _load_module
    apt() { printf 'something-else/jammy 1.0 amd64 [upgradable from: 0.9]\n'; }
    run is_outdated
    assert_failure
}

# ── detect / is_recommended ──────────────────────────────────────────────────

@test "detect succeeds when apt-get is available" {
    _load_module
    local _bin="${INIT_UBUNTU_TEST_SCRATCH}/bin"
    mkdir -p "${_bin}"
    printf '#!/bin/sh\nexit 0\n' > "${_bin}/apt-get"
    chmod +x "${_bin}/apt-get"
    PATH="${_bin}:${PATH}" run detect
    assert_success
}

@test "detect fails without apt-get on PATH" {
    _load_module
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-path" run detect
    assert_failure
}

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
    assert_output --partial "batcat"
    assert_output --partial "apt-managed"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module nope
    assert_failure 2
}

@test "standalone: info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        batcat"
    assert_output --partial "category:    optional"
    assert_output --partial "cli-essentials"
}

@test "standalone: info --lang=zh-TW prints localized description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "語法上色"
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

@test "standalone: doctor is implemented (exit != 2)" {
    run _standalone_module doctor
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
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
    # Provide a no-op `apt` so the check is environment-independent
    # (the test container is not Ubuntu-based).
    local _bin="${INIT_UBUNTU_TEST_SCRATCH}/bin"
    mkdir -p "${_bin}"
    printf '#!/bin/sh\nexit 0\n' > "${_bin}/apt"
    chmod +x "${_bin}/apt"
    PATH="${_bin}:${PATH}" run _standalone_module is-outdated
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

# ── Source mode never triggers the standalone footer ─────────────────────────

@test "source mode does not dispatch the standalone CLI" {
    # If the footer had run, sourcing with no args would have printed usage.
    run _load_module
    assert_success
    refute_output --partial "Usage:"
}
