#!/usr/bin/env bats
# test/unit/module/tmux_spec.bats — module/tmux.module.sh  (issue #123, Batch-A)
#
# Per Q29: smoke / metadata / lifecycle dry-run / no-side-fx / idempotency /
# standalone CLI / module-specific (apt archetype + config drop, sidecar
# semantics ADR-0001). Pattern mirrors ripgrep_spec.bats (apt Batch-B).
#
# Batch-A note: tmux predates the Batch-B backfill — it implements 9 of the
# 10 lifecycle functions (doctor pending) and does not yet write the version
# Sidecar. The spec pins today's contract; flip the marked tests when the
# module catches up.

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
    # shellcheck source=../../../module/tmux.module.sh
    source "${MODULE_DIR}/tmux.module.sh"
}

# _standalone_module runs the module as a self-contained CLI (the same
# entry users hit when they type `bash module/tmux.module.sh ...`).
_standalone_module() {
    bash "${MODULE_DIR}/tmux.module.sh" "$@"
}

# Point HOME at a per-test scratch dir BEFORE _load_module so both the
# source-time CONFIG_PATHS expansion and the runtime config drop land in
# the sandbox, never in the container's real HOME.
_use_scratch_home() {
    export HOME="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${HOME}"
}

# ── Controllable mocks ───────────────────────────────────────────────────────
# Each shadowed function is defined exactly once and parameterized via
# MOCK_* variables, so every definition stays reachable for the linter
# (avoids SC2317 without disable directives).

# is_installed mock: MOCK_IS_INSTALLED_RC (0 = installed, 1 = not).
_mock_is_installed() {
    is_installed() { return "${MOCK_IS_INSTALLED_RC:-0}"; }
}

# dpkg mock for module_default_apt_is_installed:
#   MOCK_DPKG_OUTPUT (line printed, e.g. "ii  tmux ...") / MOCK_DPKG_RC.
_mock_dpkg() {
    dpkg() {
        [[ -n "${MOCK_DPKG_OUTPUT:-}" ]] && printf '%s\n' "${MOCK_DPKG_OUTPUT}"
        return "${MOCK_DPKG_RC:-0}"
    }
}

# apt archetype default mocks: MOCK_APT_<PHASE>_RC (default 0 = success).
_mock_apt_defaults() {
    module_default_apt_install() { return "${MOCK_APT_INSTALL_RC:-0}"; }
    module_default_apt_upgrade() { return "${MOCK_APT_UPGRADE_RC:-0}"; }
    module_default_apt_remove()  { return "${MOCK_APT_REMOVE_RC:-0}"; }
    module_default_apt_purge()   { return "${MOCK_APT_PURGE_RC:-0}"; }
}

# sudo mock: swallow the privileged apt calls inside the REAL archetype
# defaults (used by the purge CONFIG_PATHS test).
_mock_sudo() {
    sudo() { return 0; }
}

# apt mock for module_default_apt_is_outdated: MOCK_APT_UPGRADABLE
# (full `apt list --upgradable` output to emit; empty = no output).
_mock_apt_list() {
    apt() { printf '%s' "${MOCK_APT_UPGRADABLE:-}"; }
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "tmux module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/tmux.module.sh"
    assert_success
}

@test "tmux module sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "tmux module defines 9 lifecycle functions (doctor pending, Batch-A)" {
    _load_module
    local _fn
    for _fn in detect is_recommended is_installed install upgrade \
               remove purge verify is_outdated; do
        declare -F "${_fn}" >/dev/null || {
            printf 'missing lifecycle function: %s\n' "${_fn}" >&2
            return 1
        }
    done
}

# ── Metadata sanity ──────────────────────────────────────────────────────────

@test "tmux module declares NAME=tmux" {
    _load_module
    [[ "${NAME}" == "tmux" ]]
}

@test "tmux module CATEGORY=recommended" {
    _load_module
    [[ "${CATEGORY}" == "recommended" ]]
}

@test "tmux module TAGS contains terminal + multiplexer" {
    _load_module
    [[ " ${TAGS[*]} " == *" terminal "* ]]
    [[ " ${TAGS[*]} " == *" multiplexer "* ]]
}

@test "tmux module DEPENDS_ON contains apt-essentials" {
    _load_module
    [[ " ${DEPENDS_ON[*]} " == *" apt-essentials "* ]]
}

@test "tmux DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "tmux module_get_description returns language-specific text" {
    _load_module
    [[ "$(module_get_description en)" == *"multiplexer"* ]]
    [[ -n "$(module_get_description zh-TW)" ]]
    # Unknown language falls back to en.
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "tmux SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "tmux module RISK_LEVEL=low" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
}

@test "tmux module VERSION_PROVIDED=apt-managed" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "apt-managed" ]]
}

@test "tmux HOMEPAGE points at upstream tmux/tmux" {
    _load_module
    [[ "${HOMEPAGE}" == *"tmux/tmux"* ]]
}

@test "tmux archetype data installs the tmux apt package" {
    _load_module
    [[ " ${APT_PKGS[*]} " == *" tmux "* ]]
}

@test "tmux CONFIG_PATHS covers .tmux.conf + .config/tmux + .tmux" {
    _use_scratch_home
    _load_module
    [[ " ${CONFIG_PATHS[*]} " == *" ${HOME}/.tmux.conf "* ]]
    [[ " ${CONFIG_PATHS[*]} " == *" ${HOME}/.config/tmux "* ]]
    [[ " ${CONFIG_PATHS[*]} " == *" ${HOME}/.tmux "* ]]
}

@test "tmux POST_INSTALL_MESSAGE explains the reload command" {
    _load_module
    [[ "$(module_get_post_install_message en)" == *"tmux source"* ]]
    [[ -n "$(module_get_post_install_message zh-TW)" ]]
}

@test "tmux TEST_VERIFY_CMD checks the tmux binary" {
    _load_module
    [[ "${TEST_VERIFY_CMD}" == *"tmux -V"* ]]
}

@test "tmux config bundle ships in the repo (tmux.conf + tmux-powerline)" {
    [[ -f "${MODULE_DIR}/config/tmux/tmux.conf" ]]
    [[ -d "${MODULE_DIR}/config/tmux/tmux-powerline" ]]
}

# ── is_installed: relies on dpkg ─────────────────────────────────────────────

@test "is_installed returns nonzero when dpkg does not report tmux" {
    _load_module
    MOCK_DPKG_RC=1
    _mock_dpkg
    run is_installed
    assert_failure
}

@test "is_installed returns zero when dpkg reports tmux as ii" {
    _load_module
    MOCK_DPKG_OUTPUT='ii  tmux  3.4-1  amd64  terminal multiplexer'
    _mock_dpkg
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
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/tmux" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "dry-run install drops no config into a scratch HOME" {
    _use_scratch_home
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ ! -e "${HOME}/.tmux.conf" ]]
    [[ ! -e "${HOME}/.tmux" ]]
}

@test "dry-run remove leaves an existing sidecar in place" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf 'apt-managed\n' > "${INIT_UBUNTU_STATE_DIR}/versions/tmux"
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/tmux" ]]
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

# ── Sidecar semantics (ADR-0001) ─────────────────────────────────────────────

@test "install never touches state.json (ADR-0001 / AC-23 pattern)" {
    _use_scratch_home
    _load_module
    printf '{"schema_version":"0.1.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    _mock_apt_defaults
    install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "failed apt install propagates failure and drops no config (ADR-0015)" {
    _use_scratch_home
    _load_module
    MOCK_APT_INSTALL_RC=1
    _mock_apt_defaults
    run install
    assert_failure
    [[ ! -e "${HOME}/.tmux.conf" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/tmux" ]]
}

# ── Config drop (module-specific) ────────────────────────────────────────────

@test "install drops the repo tmux.conf to HOME/.tmux.conf" {
    _use_scratch_home
    _load_module
    _mock_apt_defaults
    install
    [[ -f "${HOME}/.tmux.conf" ]]
    diff -q "${MODULE_DIR}/config/tmux/tmux.conf" "${HOME}/.tmux.conf"
}

@test "install copies the tmux-powerline bundle under HOME/.tmux" {
    _use_scratch_home
    _load_module
    _mock_apt_defaults
    install
    [[ -d "${HOME}/.tmux/tmux-powerline" ]]
    [[ -f "${HOME}/.tmux/tmux-powerline/config.sh" ]]
}

@test "install backs up a pre-existing HOME/.tmux.conf to BACKUP_DIR" {
    _use_scratch_home
    _load_module
    _mock_apt_defaults
    export BACKUP_DIR="${INIT_UBUNTU_TEST_SCRATCH}/backup"
    printf '# user-local tweaks\n' > "${HOME}/.tmux.conf"
    install
    [[ -f "${BACKUP_DIR}/.tmux.conf" ]]
    [[ "$(cat "${BACKUP_DIR}/.tmux.conf")" == "# user-local tweaks" ]]
    diff -q "${MODULE_DIR}/config/tmux/tmux.conf" "${HOME}/.tmux.conf"
}

@test "install warns but succeeds when the config source dir is missing" {
    _use_scratch_home
    _load_module
    _mock_apt_defaults
    MODULE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/no-such-module-dir"
    run install
    assert_success
    assert_output --partial "config dir missing"
    [[ ! -e "${HOME}/.tmux.conf" ]]
}

@test "upgrade re-drops the config over a locally modified HOME/.tmux.conf" {
    _use_scratch_home
    _load_module
    _mock_apt_defaults
    export BACKUP_DIR="${INIT_UBUNTU_TEST_SCRATCH}/backup"
    printf '# drifted local copy\n' > "${HOME}/.tmux.conf"
    upgrade
    diff -q "${MODULE_DIR}/config/tmux/tmux.conf" "${HOME}/.tmux.conf"
}

@test "purge removes every CONFIG_PATHS entry (archetype + tmux data)" {
    _use_scratch_home
    _load_module
    _mock_sudo
    printf '# conf\n' > "${HOME}/.tmux.conf"
    mkdir -p "${HOME}/.config/tmux" "${HOME}/.tmux/tmux-powerline"
    run purge
    assert_success
    [[ ! -e "${HOME}/.tmux.conf" ]]
    [[ ! -e "${HOME}/.config/tmux" ]]
    [[ ! -e "${HOME}/.tmux" ]]
}

# ── Idempotency (AC-5 pattern) ───────────────────────────────────────────────

@test "install short-circuits the apt step when already installed" {
    _use_scratch_home
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    run install
    assert_success
    assert_output --partial "already installed"
}

@test "install twice with apt mocked exits 0 both times" {
    _use_scratch_home
    _load_module
    _mock_apt_defaults
    # Second pass re-drops the config over the first pass's ~/.tmux.conf,
    # which goes through backup_file — that helper requires BACKUP_DIR.
    export BACKUP_DIR="${INIT_UBUNTU_TEST_SCRATCH}/backup"
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

# ── verify / is_outdated ─────────────────────────────────────────────────────

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

@test "is_outdated returns zero when apt reports tmux upgradable" {
    _load_module
    MOCK_APT_UPGRADABLE='tmux/noble-updates 3.4-2 amd64 [upgradable from: 3.4-1]'
    _mock_apt_list
    run is_outdated
    assert_success
}

@test "is_outdated returns nonzero when tmux is not in the upgradable list" {
    _load_module
    MOCK_APT_UPGRADABLE='some-other-pkg/noble 1.0 amd64 [upgradable from: 0.9]'
    _mock_apt_list
    run is_outdated
    assert_failure
}

@test "is_outdated returns nonzero when apt output is empty" {
    _load_module
    MOCK_APT_UPGRADABLE=""
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
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/bin/sh\nexit 0\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/apt-get"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/apt-get"
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
    assert_output --partial "tmux"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module nope
    assert_failure 2
}

@test "standalone: info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        tmux"
    assert_output --partial "category:    recommended"
    assert_output --partial "multiplexer"
    assert_output --partial "apt-essentials"
}

@test "standalone: info --lang=zh-TW prints localized description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "終端機"
}

@test "standalone: status reports installed + outdated fields" {
    run _standalone_module status
    assert_success
    assert_output --partial "installed:"
    assert_output --partial "outdated:"
}

# ── AC-25: implemented phases runnable, graceful exit 2 only for doctor ──────

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
    # Fake `apt` on PATH: the test container has no apt, and a bare
    # command-not-found (127) would trip bats' BW01 warning.
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/bin/sh\nexit 0\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/apt"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/apt"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run _standalone_module is-outdated
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: doctor is not yet implemented (Batch-A gap, graceful exit 2)" {
    # Pins today's contract: tmux has no doctor(); the standalone CLI must
    # degrade gracefully (exit 2 + explicit message), never crash. Flip this
    # test when the Batch-A backfill adds doctor() to the module.
    run _standalone_module doctor
    assert_failure 2
    assert_output --partial "not implemented"
}
