#!/usr/bin/env bats
# test/unit/module/lnav_spec.bats — module/lnav.module.sh
#
# Per Q29: smoke / metadata / lifecycle dry-run / no-side-fx / idempotency /
# standalone CLI / module-specific (custom archetype: apt package + legacy
# lnav_pkg config bundle deploy, sidecar lifecycle ADR-0001).

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
    # shellcheck source=../../../module/lnav.module.sh
    source "${MODULE_DIR}/lnav.module.sh"
}

# _load_module_scratch_home points HOME at a per-test scratch dir BEFORE
# sourcing, so the module computes its config destination under scratch.
_load_module_scratch_home() {
    HOME="${INIT_UBUNTU_TEST_SCRATCH}/home"
    export HOME
    mkdir -p "${HOME}"
    _load_module
}

# _standalone_module runs the module as a self-contained CLI (the same
# entry users hit when they type `bash module/lnav.module.sh ...`).
_standalone_module() {
    bash "${MODULE_DIR}/lnav.module.sh" "$@"
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
#   MOCK_DPKG_OUTPUT (line printed, e.g. "ii  lnav ...") / MOCK_DPKG_RC.
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

# dpkg-query mock for the sidecar version: MOCK_PKG_VERSION (empty = fail).
_mock_dpkg_query() {
    dpkg-query() {
        [[ -n "${MOCK_PKG_VERSION:-}" ]] || return 1
        printf '%s' "${MOCK_PKG_VERSION}"
    }
}

# apt mock for module_default_apt_is_outdated: MOCK_APT_UPGRADABLE
# (full `apt list --upgradable` output to emit; empty = no output).
_mock_apt_list() {
    apt() { printf '%s' "${MOCK_APT_UPGRADABLE:-}"; }
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "lnav module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/lnav.module.sh"
    assert_success
}

@test "lnav module sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "lnav module defines all 10 lifecycle functions" {
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

@test "lnav module declares NAME=lnav" {
    _load_module
    [[ "${NAME}" == "lnav" ]]
}

@test "lnav module CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "lnav module TAGS contains logs" {
    _load_module
    [[ " ${TAGS[*]} " == *" logs "* ]]
}

@test "lnav module DEPENDS_ON is empty (issue #62 / Q39)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 0 ]]
}

@test "lnav DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "lnav module_get_description returns language-specific text" {
    _load_module
    [[ "$(module_get_description en)" == *"log"* ]]
    [[ -n "$(module_get_description zh-TW)" ]]
    # Unknown language falls back to en.
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "lnav SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "lnav module RISK_LEVEL=low" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
}

@test "lnav module VERSION_PROVIDED=apt-managed" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "apt-managed" ]]
}

@test "lnav HOMEPAGE points at lnav.org" {
    _load_module
    [[ "${HOMEPAGE}" == *"lnav.org"* ]]
}

@test "lnav archetype data installs the lnav apt package" {
    _load_module
    [[ " ${APT_PKGS[*]} " == *" lnav "* ]]
}

@test "lnav config bundle source points at the legacy lnav_pkg dir" {
    _load_module
    [[ "${LNAV_CONFIG_SRC}" == *"/config/lnav_pkg" ]]
    [[ -d "${LNAV_CONFIG_SRC}" ]]
    [[ -f "${LNAV_CONFIG_SRC}/config.json" ]]
}

@test "lnav config bundle destination is HOME/.config/lnav" {
    _load_module_scratch_home
    [[ "${LNAV_CONFIG_DEST}" == "${HOME}/.config/lnav" ]]
}

@test "lnav POST_INSTALL_MESSAGE mentions the config bundle" {
    _load_module
    [[ "$(module_get_post_install_message en)" == *"config"* ]]
    [[ -n "$(module_get_post_install_message zh-TW)" ]]
}
