#!/usr/bin/env bats
# test/unit/module/ranger_spec.bats — module/ranger.module.sh (issue #61)
#
# Q29 categories: smoke / metadata / lifecycle dry-run / no-side-fx /
# idempotency / standalone CLI / module-specific (apt + config-drop hybrid:
# managed rifle.conf, Sidecar lifecycle per ADR-0001).
#
# Mock convention: every test-local mock is invoked once directly right
# after its definition (wiring smoke + makes the indirect dispatch visible
# to ShellCheck without an SC2317 disable).

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    # Sandbox $HOME so config drops never touch the real home dir. Must be
    # set BEFORE the module loads: CONFIG_DEST expands ${HOME} at source time.
    export HOME="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${HOME}"
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
    # shellcheck source=../../../module/ranger.module.sh
    source "${MODULE_DIR}/ranger.module.sh"
}

# _standalone_module runs the module as a self-contained CLI (the same
# entry users hit when they type `bash module/ranger.module.sh ...`).
_standalone_module() {
    bash "${MODULE_DIR}/ranger.module.sh" "$@"
}

# Drop a marked (= managed) rifle.conf into the sandbox HOME.
_seed_managed_config() {
    mkdir -p "${HOME}/.config/ranger"
    {
        printf '# init_ubuntu managed\n'
        printf 'ext mp4 = mpv -- "$@"\n'
    } > "${HOME}/.config/ranger/rifle.conf"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "ranger module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/ranger.module.sh"
    assert_success
}

@test "ranger module sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "ranger module defines all 10 lifecycle functions" {
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

@test "ranger module declares NAME=ranger" {
    _load_module
    [[ "${NAME}" == "ranger" ]]
}

@test "ranger module CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "ranger TAGS contains filemgr" {
    _load_module
    [[ " ${TAGS[*]} " == *" filemgr "* ]]
}

@test "ranger DEPENDS_ON is empty (Q39: module names only)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 0 ]]
}

@test "ranger DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "ranger module_get_description falls back to en for unknown lang" {
    _load_module
    [[ "$(module_get_description en)" == *"ranger"* ]]
    [[ -n "$(module_get_description zh-TW)" ]]
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "ranger SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "ranger RISK_LEVEL=low and REBOOT_REQUIRED=false" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
    [[ "${REBOOT_REQUIRED}" == "false" ]]
}

@test "ranger module VERSION_PROVIDED=apt-managed" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "apt-managed" ]]
}

@test "ranger HOMEPAGE points at upstream ranger/ranger" {
    _load_module
    [[ "${HOMEPAGE}" == *"ranger/ranger"* ]]
}

@test "ranger archetype data installs the apt 'ranger' package" {
    _load_module
    [[ " ${APT_PKGS[*]} " == *" ranger "* ]]
}

@test "ranger CONFIG_TEMPLATE_SRC is the repo rifle.conf and it exists" {
    _load_module
    [[ "${CONFIG_TEMPLATE_SRC}" == *"/config/ranger/rifle.conf" ]]
    [[ -f "${CONFIG_TEMPLATE_SRC}" ]]
}

@test "ranger CONFIG_DEST is ~/.config/ranger/rifle.conf" {
    _load_module
    [[ "${CONFIG_DEST}" == "${HOME}/.config/ranger/rifle.conf" ]]
}

@test "ranger CONFIG_PATHS covers ~/.config/ranger for purge" {
    _load_module
    [[ " ${CONFIG_PATHS[*]} " == *" ${HOME}/.config/ranger "* ]]
}

# ── Engine discovery ─────────────────────────────────────────────────────────

@test "registry discovers ranger with tag filemgr" {
    # shellcheck source=../../../lib/registry.sh
    source "${LIB_DIR}/registry.sh"
    registry_load_all "${MODULE_DIR}"
    registry_has "ranger"
    run registry_list_names --tag=filemgr
    assert_success
    assert_line "ranger"
}

# ── is_installed (hybrid: apt pkg AND managed config) ────────────────────────

@test "is_installed returns nonzero on a fresh test container" {
    _load_module
    run is_installed
    assert_failure
}

@test "is_installed returns 0 when pkg installed AND managed config present" {
    _load_module
    dpkg() { printf 'ii  ranger 1.9.3-1 all  console file manager\n'; }
    dpkg -l ranger >/dev/null
    _seed_managed_config
    run is_installed
    assert_success
}

@test "is_installed fails when pkg installed but managed config missing" {
    _load_module
    dpkg() { printf 'ii  ranger 1.9.3-1 all  console file manager\n'; }
    dpkg -l ranger >/dev/null
    run is_installed
    assert_failure
}

@test "is_installed fails when config present but pkg missing" {
    _load_module
    _seed_managed_config
    run is_installed
    assert_failure
}

# ── Config drop (module-specific) ────────────────────────────────────────────

@test "install drops rifle.conf with the managed marker (apt super-call mocked)" {
    _load_module
    module_default_apt_install() { return 0; }
    module_default_apt_install
    install
    [[ -f "${HOME}/.config/ranger/rifle.conf" ]]
    run grep -F "# init_ubuntu managed" "${HOME}/.config/ranger/rifle.conf"
    assert_success
}

@test "dropped rifle.conf carries the repo template content" {
    _load_module
    module_default_apt_install() { return 0; }
    module_default_apt_install
    install
    run grep -F "rifle" "${HOME}/.config/ranger/rifle.conf"
    assert_success
}

@test "dropped rifle.conf has mode 644" {
    _load_module
    module_default_apt_install() { return 0; }
    module_default_apt_install
    install
    [[ "$(stat -c '%a' "${HOME}/.config/ranger/rifle.conf")" == "644" ]]
}

@test "install preserves a user-modified managed rifle.conf (no clobber)" {
    _load_module
    dpkg() { printf 'ii  ranger 1.9.3-1 all  console file manager\n'; }
    dpkg -l ranger >/dev/null
    _seed_managed_config
    printf 'ext pdf = zathura -- "$@"  # MY CUSTOM RULE\n' \
        >> "${HOME}/.config/ranger/rifle.conf"
    run install
    assert_success
    run grep -F "MY CUSTOM RULE" "${HOME}/.config/ranger/rifle.conf"
    assert_success
}

@test "upgrade re-drops the managed rifle.conf from the template" {
    _load_module
    # config-archetype upgrade backs up the existing file first; BACKUP_DIR
    # is the engine-provided contract for lib/general.sh::backup_file.
    export BACKUP_DIR="${INIT_UBUNTU_TEST_SCRATCH}/backup"
    module_default_apt_upgrade() { return 0; }
    module_default_apt_upgrade
    mkdir -p "${HOME}/.config/ranger"
    printf 'stale content without marker\n' > "${HOME}/.config/ranger/rifle.conf"
    upgrade
    run grep -F "# init_ubuntu managed" "${HOME}/.config/ranger/rifle.conf"
    assert_success
    run grep -F "stale content without marker" "${HOME}/.config/ranger/rifle.conf"
    assert_failure
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

@test "dry-run install writes no sidecar, no state.json, no config" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/ranger" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
    [[ ! -e "${HOME}/.config/ranger/rifle.conf" ]]
}

@test "dry-run remove and purge keep an existing sidecar" {
    _load_module
    module_sidecar_write "ranger" "1.9.3"
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    INIT_UBUNTU_DRY_RUN=true run purge
    assert_success
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/ranger" ]]
}

@test "standalone dry-run install creates no files in the sandbox HOME" {
    XDG_STATE_HOME="${HOME}/.local/state" run _standalone_module install --dry-run
    assert_success
    local _leftover
    _leftover="$(find "${HOME}" -mindepth 1 2>/dev/null)"
    [[ -z "${_leftover}" ]]
}

# ── Sidecar lifecycle (ADR-0001) ─────────────────────────────────────────────

@test "module_sidecar_write / get_version / remove roundtrip" {
    _load_module
    module_sidecar_write "ranger" "1.9.3"
    [[ "$(module_sidecar_get_version "ranger")" == "1.9.3" ]]
    module_sidecar_remove "ranger"
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/ranger" ]]
    run module_sidecar_get_version "ranger"
    assert_failure
}

@test "install writes the sidecar with the dpkg version" {
    _load_module
    module_default_apt_install() { return 0; }
    module_default_apt_install
    _ranger_pkg_version() { printf '1.9.3-1'; }
    [[ "$(_ranger_pkg_version)" == "1.9.3-1" ]]
    install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/ranger")" == "1.9.3-1" ]]
}

@test "install never touches state.json (ADR-0001 / AC-23 pattern)" {
    _load_module
    printf '{"sentinel":true}\n' > "${INIT_UBUNTU_STATE_DIR}/state.json"
    module_default_apt_install() { return 0; }
    module_default_apt_install
    run install
    assert_success
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == '{"sentinel":true}' ]]
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/ranger" ]]
}

@test "failed apt install leaves no sidecar and no config (ADR-0015)" {
    _load_module
    module_default_apt_install() { return 1; }
    ! module_default_apt_install
    run install
    assert_failure
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/ranger" ]]
    [[ ! -e "${HOME}/.config/ranger/rifle.conf" ]]
}

@test "failed config drop leaves no sidecar behind" {
    _load_module
    module_default_apt_install() { return 0; }
    module_default_apt_install
    module_default_config_install() { return 1; }
    ! module_default_config_install
    run install
    assert_failure
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/ranger" ]]
}

@test "upgrade refreshes the sidecar version" {
    _load_module
    module_sidecar_write "ranger" "1.8.0"
    module_default_apt_upgrade() { return 0; }
    module_default_apt_upgrade
    _ranger_pkg_version() { printf '9.9.9'; }
    [[ "$(_ranger_pkg_version)" == "9.9.9" ]]
    upgrade
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/ranger")" == "9.9.9" ]]
}

@test "remove deletes the sidecar" {
    _load_module
    module_sidecar_write "ranger" "1.9.3"
    module_default_apt_remove() { return 0; }
    module_default_apt_remove
    remove
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/ranger" ]]
}

@test "purge deletes the sidecar" {
    _load_module
    module_sidecar_write "ranger" "1.9.3"
    module_default_apt_purge() { return 0; }
    module_default_apt_purge
    purge
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/ranger" ]]
}

# ── remove/purge config semantics (spec §4.7.4) ──────────────────────────────

@test "remove keeps the managed rifle.conf (user config preserved)" {
    _load_module
    _seed_managed_config
    module_default_apt_remove() { return 0; }
    module_default_apt_remove
    remove
    [[ -f "${HOME}/.config/ranger/rifle.conf" ]]
}

@test "purge removes the whole ~/.config/ranger dir (CONFIG_PATHS)" {
    _load_module
    _seed_managed_config
    sudo() { return 0; }
    sudo true
    run purge
    assert_success
    [[ ! -e "${HOME}/.config/ranger" ]]
}

# ── Idempotency (AC-5 pattern) ───────────────────────────────────────────────

@test "install short-circuits when is_installed returns 0 (idempotency)" {
    _load_module
    is_installed() { return 0; }
    is_installed
    run install
    assert_success
    assert_output --partial "already installed"
}

@test "install twice with apt mocked exits 0 both times" {
    _load_module
    module_default_apt_install() { return 0; }
    module_default_apt_install
    run install
    assert_success
    run install
    assert_success
}

@test "remove is idempotent — second run still exits 0" {
    _load_module
    module_default_apt_remove() { return 0; }
    module_default_apt_remove
    run remove
    assert_success
    run remove
    assert_success
}

@test "purge is idempotent — second run still exits 0" {
    _load_module
    sudo() { return 0; }
    sudo true
    run purge
    assert_success
    run purge
    assert_success
}

# ── verify / doctor / is_outdated ────────────────────────────────────────────

@test "verify fails when not installed" {
    _load_module
    is_installed() { return 1; }
    ! is_installed
    run verify
    assert_failure
}

@test "verify passes when installed and TEST_VERIFY_CMD succeeds" {
    _load_module
    is_installed() { return 0; }
    is_installed
    TEST_VERIFY_CMD="true"
    run verify
    assert_success
}

@test "doctor fails when not installed" {
    _load_module
    is_installed() { return 1; }
    ! is_installed
    run doctor
    assert_failure
}

@test "doctor passes when installed and ranger answers --version" {
    _load_module
    is_installed() { return 0; }
    is_installed
    ranger() { printf 'ranger version: ranger 1.9.3\n'; }
    ranger --version >/dev/null
    run doctor
    assert_success
}

@test "doctor fails when ranger binary is missing from PATH" {
    _load_module
    is_installed() { return 0; }
    is_installed
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-path" run doctor
    assert_failure
}

@test "is_outdated returns zero when apt lists ranger as upgradable" {
    _load_module
    apt() { printf 'ranger/noble-updates 1.9.9 all [upgradable from: 1.9.3]\n'; }
    apt list >/dev/null
    run is_outdated
    assert_success
}

@test "is_outdated returns nonzero when apt lists no ranger upgrade" {
    _load_module
    apt() { printf 'something-else/noble 1.0 amd64 [upgradable from: 0.9]\n'; }
    apt list >/dev/null
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

@test "is_recommended is zero when not installed, nonzero when installed" {
    _load_module
    is_installed() { return 1; }
    ! is_installed
    run is_recommended
    assert_success
    is_installed() { return 0; }
    is_installed
    run is_recommended
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
    assert_output --partial "ranger"
    assert_output --partial "apt-managed"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module frobnicate
    assert_failure 2
}

@test "standalone: info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        ranger"
    assert_output --partial "category:    optional"
    assert_output --partial "filemgr"
}

@test "standalone: info --lang=zh-TW prints localized description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "檔案管理"
}

@test "standalone: status reports installed + outdated fields" {
    run _standalone_module status
    assert_success
    assert_output --partial "installed:"
    assert_output --partial "outdated:"
}

# ── AC-25: all 10 phases runnable, never "not implemented" exit 2 ────────────

@test "AC-25: mutating phases run standalone with --dry-run, exit 0" {
    local _phase
    for _phase in install upgrade remove purge verify; do
        run _standalone_module "${_phase}" --dry-run
        if [[ "${status}" -ne 0 ]]; then
            printf 'phase %s exited %s\noutput: %s\n' \
                "${_phase}" "${status}" "${output}" >&2
            return 1
        fi
        assert_output --partial "DRY-RUN"
    done
}

@test "AC-25: query phases run standalone, never 'not implemented' exit 2" {
    # Stub apt/dpkg so the apt-archetype queries behave on a non-Ubuntu
    # test container (no apt -> command-not-found would exit >= 2).
    local _bin="${INIT_UBUNTU_TEST_SCRATCH}/bin"
    mkdir -p "${_bin}"
    printf '#!/bin/sh\nexit 0\n' > "${_bin}/apt"
    printf '#!/bin/sh\nexit 1\n' > "${_bin}/dpkg"
    chmod +x "${_bin}/apt" "${_bin}/dpkg"
    local _phase
    for _phase in detect is-installed is-recommended is-outdated; do
        PATH="${_bin}:${PATH}" run _standalone_module "${_phase}"
        if [[ "${status}" -ge 2 ]]; then
            printf 'phase %s exited %s\noutput: %s\n' \
                "${_phase}" "${status}" "${output}" >&2
            return 1
        fi
        refute_output --partial "not implemented"
    done
}

@test "AC-25: doctor is implemented (exit != 2)" {
    run _standalone_module doctor
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

# ── Source mode never triggers the standalone footer ─────────────────────────

@test "source mode does not dispatch the standalone CLI" {
    run _load_module
    assert_success
    refute_output --partial "Usage:"
}
