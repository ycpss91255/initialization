#!/usr/bin/env bats
# test/unit/module/claude-code-config_spec.bats — module/claude-code-config.module.sh
#
# Per Q29: smoke / metadata / lifecycle dry-run / no-side-fx / idempotency /
# standalone CLI / module-specific (config-drop archetype, multi-file drop,
# $HOME localization, sidecar lifecycle ADR-0001).

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    TEST_HOME="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${TEST_HOME}"
    export TEST_HOME
}

teardown() {
    teardown_test_env
}

# Engine-mode load: source the module with HOME pointed at a scratch dir so
# CONFIG_DEST (computed at source time) lands inside the test sandbox.
_load_module() {
    export HOME="${TEST_HOME}"
    # shellcheck source=../../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../../lib/general.sh
    source "${LIB_DIR}/general.sh"
    # shellcheck source=../../../lib/module_helper.sh
    source "${LIB_DIR}/module_helper.sh"
    # shellcheck source=../../../module/claude-code-config.module.sh
    source "${MODULE_DIR}/claude-code-config.module.sh"
}

# _standalone_module runs the module as a self-contained CLI inside the
# scratch HOME (the same entry users hit when they type
# `bash module/claude-code-config.module.sh ...`).
_standalone_module() {
    HOME="${TEST_HOME}" XDG_STATE_HOME="${TEST_HOME}/.local/state" \
        bash "${MODULE_DIR}/claude-code-config.module.sh" "$@"
}

# ── Controllable mocks ───────────────────────────────────────────────────────

# is_installed mock: MOCK_IS_INSTALLED_RC (0 = installed, 1 = not).
_mock_is_installed() {
    is_installed() { return "${MOCK_IS_INSTALLED_RC:-0}"; }
}

# Fake `claude` binary on PATH for is_recommended.
_fake_claude_on_path() {
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/bin/sh\nexit 0\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/claude"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/claude"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "claude-code-config module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/claude-code-config.module.sh"
    assert_success
}

@test "claude-code-config sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "claude-code-config defines all 10 lifecycle functions" {
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

@test "claude-code-config declares NAME=claude-code-config" {
    _load_module
    [[ "${NAME}" == "claude-code-config" ]]
}

@test "claude-code-config CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "claude-code-config TAGS[0]=agent (TUI grouping)" {
    _load_module
    [[ "${TAGS[0]}" == "agent" ]]
}

@test "claude-code-config DEPENDS_ON is exactly claude-code (module name only, Q39)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 1 ]]
    [[ "${DEPENDS_ON[0]}" == "claude-code" ]]
}

@test "claude-code-config DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "claude-code-config module_get_description returns language-specific text" {
    _load_module
    [[ "$(module_get_description en)" == *"Claude Code"* ]]
    [[ -n "$(module_get_description zh-TW)" ]]
    # Unknown language falls back to en.
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "claude-code-config SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "claude-code-config RISK_LEVEL=low" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
}

@test "claude-code-config is a user-home config drop (no sudo)" {
    _load_module
    [[ "${SUPPORTS_USER_HOME}" == "true" ]]
    [[ "${INSTALL_TARGET_DEFAULT}" == "user-home" ]]
}

@test "claude-code-config archetype data targets ~/.claude/settings.json" {
    _load_module
    [[ "${CONFIG_DEST}" == "${HOME}/.claude/settings.json" ]]
}

@test "claude-code-config template source lives in module/config/claude and exists" {
    _load_module
    [[ "${CONFIG_TEMPLATE_SRC}" == *"/config/claude/settings.json" ]]
    [[ -f "${CONFIG_TEMPLATE_SRC}" ]]
}

@test "claude-code-config repo ships all three template files" {
    [[ -f "${MODULE_DIR}/config/claude/settings.json" ]]
    [[ -f "${MODULE_DIR}/config/claude/run-statusline.sh" ]]
    [[ -f "${MODULE_DIR}/config/claude/settings.statusline.json" ]]
}

@test "claude-code-config CONFIG_MARKER is JSON-safe (already present in template)" {
    _load_module
    # The marker must already exist in the JSON template so the archetype
    # never injects a '#' comment line into a JSON file.
    grep -qF "${CONFIG_MARKER}" "${CONFIG_TEMPLATE_SRC}"
}
