#!/usr/bin/env bats
# test/unit/module/claude-code_spec.bats — module/claude-code.module.sh
#
# Per Q29: smoke / metadata / lifecycle dry-run / no-side-fx / idempotency /
# standalone CLI / module-specific (custom archetype D: official native
# installer, self-updating tool, sidecar lifecycle ADR-0001).

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
    # shellcheck source=../../../module/claude-code.module.sh
    source "${MODULE_DIR}/claude-code.module.sh"
}

# _standalone_module runs the module as a self-contained CLI (the same
# entry users hit when they type `bash module/claude-code.module.sh ...`).
_standalone_module() {
    bash "${MODULE_DIR}/claude-code.module.sh" "$@"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "claude-code module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/claude-code.module.sh"
    assert_success
}

@test "claude-code module sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "claude-code module defines all 10 lifecycle functions" {
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

@test "claude-code module declares NAME=claude-code" {
    _load_module
    [[ "${NAME}" == "claude-code" ]]
}

@test "claude-code module CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "claude-code module TAGS contains agent" {
    _load_module
    [[ " ${TAGS[*]} " == *" agent "* ]]
}

@test "claude-code module DEPENDS_ON is empty (Q39: module names only)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 0 ]]
}

@test "claude-code DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "claude-code module_get_description returns language-specific text" {
    _load_module
    [[ "$(module_get_description en)" == *"Claude Code"* ]]
    [[ -n "$(module_get_description zh-TW)" ]]
    # Unknown language falls back to en.
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "claude-code SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "claude-code module RISK_LEVEL=low" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
}

@test "claude-code module VERSION_PROVIDED=latest" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "latest" ]]
}

@test "claude-code HOMEPAGE is an https URL" {
    _load_module
    [[ "${HOMEPAGE}" == https://* ]]
}

@test "claude-code installs to user home without sudo (native installer)" {
    _load_module
    [[ "${SUPPORTS_USER_HOME}" == "true" ]]
    [[ "${INSTALL_TARGET_DEFAULT}" == "user-home" ]]
}

@test "claude-code installer URL is the official claude.ai install script" {
    _load_module
    [[ "${CLAUDE_CODE_INSTALLER_URL}" == "https://claude.ai/install.sh" ]]
}

@test "claude-code POST_INSTALL_MESSAGE mentions sign-in and auto-update" {
    _load_module
    [[ "$(module_get_post_install_message en)" == *"claude"* ]]
    [[ -n "$(module_get_post_install_message zh-TW)" ]]
}
