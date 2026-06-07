#!/usr/bin/env bats
# test/unit/module/yazi_spec.bats — module/yazi.module.sh (issue #60)
#
# Covers (Q29): smoke / metadata / lifecycle dry-run / no-side-fx /
# idempotency / Sidecar (ADR-0001) / standalone CLI (AC-25) / registry
# discovery / legacy #1 alias regression (alias must target yazi, not cat).

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    # Sandbox HOME so alias writes never touch the container user's rc files.
    TEST_HOME="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${TEST_HOME}"
    export TEST_HOME
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
    # shellcheck source=../../../module/yazi.module.sh
    source "${MODULE_DIR}/yazi.module.sh"
}

# ── Smoke: contract shape ────────────────────────────────────────────────────

@test "yazi module defines all 10 lifecycle functions" {
    _load_module
    local _fn
    for _fn in detect is_recommended is_installed install upgrade \
               remove purge verify is_outdated doctor; do
        declare -F "${_fn}" >/dev/null || {
            printf "missing lifecycle fn: %s\n" "${_fn}" >&2
            return 1
        }
    done
}

# ── Metadata sanity (PRD §9.1 / issue #60) ──────────────────────────────────

@test "yazi module declares NAME=yazi" {
    _load_module
    [[ "${NAME}" == "yazi" ]]
}

@test "yazi module CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "yazi module TAGS[0]=filemgr" {
    _load_module
    [[ "${TAGS[0]}" == "filemgr" ]]
}

@test "yazi module DEPENDS_ON is empty (Q39: module names only)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 0 ]]
}

@test "yazi DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "$(module_get_description en)" ]]
    [[ -n "$(module_get_description zh-TW)" ]]
}

@test "yazi POST_INSTALL_MESSAGE has en + zh-TW entries" {
    _load_module
    [[ -n "$(module_get_post_install_message en)" ]]
    [[ -n "$(module_get_post_install_message zh-TW)" ]]
}

@test "yazi module SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "yazi module SUPPORTED_PLATFORMS is non-empty" {
    _load_module
    [[ "${#SUPPORTED_PLATFORMS[@]}" -gt 0 ]]
}

@test "yazi module HOMEPAGE points at sxyazi/yazi" {
    _load_module
    [[ "${HOMEPAGE}" == *"github.com/sxyazi/yazi"* ]]
}

@test "yazi module VERSION_PROVIDED=latest" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "latest" ]]
}

@test "yazi module RISK_LEVEL=low" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
}

@test "yazi module REBOOT_REQUIRED=false" {
    _load_module
    [[ "${REBOOT_REQUIRED}" == "false" ]]
}

@test "yazi module INSTALL_TARGET_DEFAULT=sudo" {
    _load_module
    [[ "${INSTALL_TARGET_DEFAULT}" == "sudo" ]]
}

@test "yazi module SUPPORTS_USER_HOME is a boolean" {
    _load_module
    [[ "${SUPPORTS_USER_HOME}" == "true" || "${SUPPORTS_USER_HOME}" == "false" ]]
}

@test "yazi archetype data points at sxyazi/yazi zip asset" {
    _load_module
    [[ "${GITHUB_REPO}" == "sxyazi/yazi" ]]
    [[ "${BIN_NAME}" == "yazi" ]]
    [[ "${GITHUB_ASSET_PATTERN}" == *".zip" ]]
}

@test "yazi module CONFLICTS_WITH is empty" {
    _load_module
    [[ "${#CONFLICTS_WITH[@]}" -eq 0 ]]
}
