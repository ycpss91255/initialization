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
    # Never run the real `npm install -g ccstatusline` host install from a
    # test path (hard rule 2 / #231): the module short-circuits the binary
    # provisioning step on this guard.
    export INIT_UBUNTU_STATUSLINE_NO_BINARY=true
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
    # Drop the test-env state-dir override so the sidecar lands under the
    # scratch XDG_STATE_HOME, exactly like a real user invocation.
    env -u INIT_UBUNTU_STATE_DIR \
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

@test "claude-code-config repo ships all four template files" {
    [[ -f "${MODULE_DIR}/config/claude/settings.json" ]]
    [[ -f "${MODULE_DIR}/config/claude/run-ccstatusline.sh" ]]
    [[ -f "${MODULE_DIR}/config/claude/settings.statusline.json" ]]
    [[ -f "${MODULE_DIR}/config/claude/ccstatusline.settings.json" ]]
}

@test "claude-code-config CONFIG_MARKER is JSON-safe (already present in template)" {
    _load_module
    # The marker must already exist in the JSON template so the archetype
    # never injects a '#' comment line into a JSON file.
    grep -qF "${CONFIG_MARKER}" "${CONFIG_TEMPLATE_SRC}"
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

@test "dry-run install writes nothing to HOME or the state dir" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ ! -e "${HOME}/.claude" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/claude-code-config" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "dry-run remove leaves dropped files and sidecar in place" {
    _load_module
    module_standalone_main install
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    [[ -f "${HOME}/.claude/settings.json" ]]
    [[ -f "${HOME}/.claude/run-ccstatusline.sh" ]]
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/claude-code-config" ]]
}

@test "standalone dry-run install creates no files in a scratch HOME" {
    run _standalone_module install --dry-run
    assert_success
    local _leftover
    _leftover="$(find "${TEST_HOME}" -mindepth 1 2>/dev/null)"
    [[ -z "${_leftover}" ]]
}

# ── install drops the config bundle ──────────────────────────────────────────

@test "install drops settings.json with the JSON marker" {
    _load_module
    run install
    assert_success
    [[ -f "${HOME}/.claude/settings.json" ]]
    grep -qF "${CONFIG_MARKER}" "${HOME}/.claude/settings.json"
}

@test "install drops run-ccstatusline.sh as an executable" {
    _load_module
    install
    [[ -x "${HOME}/.claude/run-ccstatusline.sh" ]]
}

@test "install drops settings.statusline.json (mode 644)" {
    _load_module
    install
    [[ -f "${HOME}/.claude/settings.statusline.json" ]]
    [[ "$(stat -c '%a' "${HOME}/.claude/settings.statusline.json")" == "644" ]]
}

@test "install drops the ccstatusline layout to the XDG config path (#231)" {
    _load_module
    install
    local _xdg="${HOME}/.config/ccstatusline/settings.json"
    [[ -f "${_xdg}" ]]
    [[ "$(stat -c '%a' "${_xdg}")" == "644" ]]
    # Byte-fidelity: the XDG drop equals the shipped template (no home paths).
    run jq -e '.version == 3' "${_xdg}"
    assert_success
}

@test "install skips the host npm binary install under the test guard (#231)" {
    _load_module
    # INIT_UBUNTU_STATUSLINE_NO_BINARY=true (setup) — no npm install must fire.
    run install
    assert_success
    refute_output --partial "npm install -g ccstatusline"
}

# ── statusline width feeding (#228 / #231) ───────────────────────────────────
# Claude Code invokes the status line with a piped (non-TTY) stdout, so
# ccstatusline cannot auto-detect terminal width and clips with `...`.
# run-ccstatusline.sh must feed the real width (tmux pane_width, minus the
# flexMode offset of 8) via CCSTATUSLINE_WIDTH. These run the launcher with
# stubbed tmux + a fake `ccstatusline` binary that just echoes the width it got.

_run_statusline() {
    local bin="${INIT_UBUNTU_TEST_SCRATCH}/sl-bin"
    mkdir -p "${bin}"
    # Fake ccstatusline: report whatever width the launcher handed down. Quoted
    # heredoc keeps ${CCSTATUSLINE_WIDTH} literal — it must expand when the
    # fake runs, not while this helper writes it.
    cat > "${bin}/ccstatusline" <<'CCS'
#!/bin/sh
printf 'WIDTH=%s\n' "${CCSTATUSLINE_WIDTH:-unset}"
CCS
    # Fake tmux: emit a fixed pane width, or fail when MOCK_TMUX_FAIL=1.
    if [[ "${MOCK_TMUX_FAIL:-0}" == "1" ]]; then
        cat > "${bin}/tmux" <<'TMUX'
#!/bin/sh
exit 1
TMUX
    else
        cat > "${bin}/tmux" <<TMUX
#!/bin/sh
printf '%s\n' "${MOCK_PANE_WIDTH:-99}"
TMUX
    fi
    chmod +x "${bin}/ccstatusline" "${bin}/tmux"
    PATH="${bin}:${PATH}" \
        bash "${MODULE_DIR}/config/claude/run-ccstatusline.sh"
}

@test "statusline feeds tmux pane width minus the flexMode offset (#231)" {
    MOCK_PANE_WIDTH=99 run _run_statusline
    assert_success
    assert_output "WIDTH=91"
}

@test "statusline omits the width override when tmux is unavailable (#228)" {
    MOCK_TMUX_FAIL=1 run _run_statusline
    assert_success
    assert_output "WIDTH=unset"
}

@test "repo template settings.json ships no hardcoded /home path (#100)" {
    # AC-1: the source template must carry no template-author home prefix.
    run grep -n "/home/" "${MODULE_DIR}/config/claude/settings.json"
    assert_failure
}

@test "repo template settings.statusline.json ships no hardcoded /home path (#100)" {
    run grep -n "/home/" "${MODULE_DIR}/config/claude/settings.statusline.json"
    assert_failure
}

@test "repo template settings.json pins no fnm node-version seccomp path (#100)" {
    # The old sandbox.seccomp.applyPath pinned a specific fnm-managed Node
    # version; it must not ship as a static, machine-specific value.
    run grep -nE "seccomp|node-versions" "${MODULE_DIR}/config/claude/settings.json"
    assert_failure
}

# ── Config-content fidelity to the #231 final consolidated files ─────────────
# Per the qmk/codex/yazi precedent: assert on the shipped template content, not
# on runtime behavior. These lock the maintainer-verified regex/values so a
# careless edit (e.g. the \+ -> * 7d31% regression) is caught.

_ccs_run="${MODULE_DIR}/config/claude/run-ccstatusline.sh"
_ccs_json="${MODULE_DIR}/config/claude/ccstatusline.settings.json"

@test "run-ccstatusline.sh parses (bash -n)" {
    run bash -n "${_ccs_run}"
    assert_success
}

@test "run-ccstatusline.sh execs the ccstatusline binary" {
    grep -q '^exec ccstatusline' "${_ccs_run}"
}

@test "run-ccstatusline.sh feeds width with the flexMode -8 offset (#231)" {
    grep -qF 'CCSTATUSLINE_WIDTH=' "${_ccs_run}"
    grep -qF 'width - 8' "${_ccs_run}"
}

@test "run-ccstatusline.sh defines the NBSP separator (U+00A0 UTF-8 bytes)" {
    grep -qF "NBSP=\$'\\xc2\\xa0'" "${_ccs_run}"
}

@test "run-ccstatusline.sh has the percentage-rounding sed rule (rule 1)" {
    grep -qF 's/\([0-9]\+\)\.[0-9]\+%/\1%/g' "${_ccs_run}"
}

@test "run-ccstatusline.sh has the days sub-unit stripper with \\+ (rule 2)" {
    # Anchored substrings avoid embedding ${NBSP} in the needle; the NBSP
    # separator + \+ group form is asserted by the dedicated tests below.
    grep -qF '\([0-9]\+d\)\(' "${_ccs_run}"
}

@test "run-ccstatusline.sh has the hours sub-unit stripper with \\+ (rule 3)" {
    grep -qF '\([0-9]\+hr\)\(' "${_ccs_run}"
}

@test "run-ccstatusline.sh has the mid-unit truncation stripper (rule 4)" {
    grep -qF 's/\([0-9]\+[a-z]\)\.\.\./\1/g' "${_ccs_run}"
}

@test "run-ccstatusline.sh has the hr->h shortener (rule 5)" {
    grep -qF 's/\([0-9]\+\)hr/\1h/g' "${_ccs_run}"
}

@test "run-ccstatusline.sh sub-unit groups use \\+ not * (the 7d31% bugfix)" {
    # The one-or-more group quantifier must be present twice (d + hr rules)...
    [[ "$(grep -cF '[0-9a-z.]\+\)\+' "${_ccs_run}")" -eq 2 ]]
    # ...and the buggy zero-or-more form must be gone entirely.
    run grep -F '[0-9a-z.]*\)\+' "${_ccs_run}"
    assert_failure
}

@test "ccstatusline.settings.json is valid JSON" {
    run jq empty "${_ccs_json}"
    assert_success
}

@test "ccstatusline.settings.json declares version 3" {
    run jq -e '.version == 3' "${_ccs_json}"
    assert_success
}

@test "ccstatusline.settings.json has the two-row layout (+ trailing empty row)" {
    run jq -e '(.lines | length) == 3
               and (.lines[0] | length) > 0
               and (.lines[1] | length) > 0
               and (.lines[2] | length) == 0' "${_ccs_json}"
    assert_success
}

@test "ccstatusline.settings.json row 1 leads with cwd then git (reordered layout)" {
    run jq -e '.lines[0][0].type == "current-working-dir"
               and .lines[0][2].type == "git-branch"' "${_ccs_json}"
    assert_success
}

@test "ccstatusline.settings.json row 2 inlines reset timers (no separate Reset row)" {
    run jq -e '[.lines[1][].type] as $t
               | ($t | index("context-percentage")) != null
               and ($t | index("reset-timer")) != null
               and ($t | index("weekly-reset-timer")) != null' "${_ccs_json}"
    assert_success
}

@test "ccstatusline.settings.json omits the volatile installation block" {
    run jq -e 'has("installation") | not' "${_ccs_json}"
    assert_success
}

@test "install substitutes the __HOME__ placeholder to the current HOME (#100)" {
    _load_module
    install
    # statusLine resolves to this HOME; no placeholder or foreign /home/<user>
    # prefix survives in either dropped file.
    run grep -F "${HOME}/.claude/run-ccstatusline.sh" "${HOME}/.claude/settings.json"
    assert_success
    run grep -F "__HOME__" "${HOME}/.claude/settings.json"
    assert_failure
    run grep -q "/home/yunchien" "${HOME}/.claude/settings.json"
    assert_failure
    run grep -F "__HOME__" "${HOME}/.claude/settings.statusline.json"
    assert_failure
    run grep -q "/home/yunchien" "${HOME}/.claude/settings.statusline.json"
    assert_failure
}

@test "install drops settings.json free of any pinned node-version path (#100)" {
    _load_module
    install
    run grep -nE "node-versions" "${HOME}/.claude/settings.json"
    assert_failure
}

@test "install drops valid JSON settings (marker never injected as a comment)" {
    _load_module
    install
    # First byte must still be '{' — the archetype must not have prepended
    # a '#' marker line to the JSON file.
    [[ "$(head -c 1 "${HOME}/.claude/settings.json")" == "{" ]]
}

@test "install then is_installed returns 0" {
    _load_module
    install
    run is_installed
    assert_success
}

# ── Sidecar lifecycle (ADR-0001) ─────────────────────────────────────────────

@test "install writes the sidecar with VERSION_PROVIDED" {
    _load_module
    module_standalone_main install
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/claude-code-config" ]]
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/claude-code-config")" == "${VERSION_PROVIDED}" ]]
}

@test "install never touches state.json (ADR-0001 / AC-23 pattern)" {
    _load_module
    printf '{"schema_version":"0.1.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "failed drop leaves no sidecar behind (ADR-0015)" {
    _load_module
    _claude_config_drop_files() { return 1; }
    run module_standalone_main install
    assert_failure
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/claude-code-config" ]]
}

@test "upgrade refreshes the sidecar version" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '0.9\n' > "${INIT_UBUNTU_STATE_DIR}/versions/claude-code-config"
    module_standalone_main upgrade
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/claude-code-config")" == "${VERSION_PROVIDED}" ]]
}

@test "remove deletes the sidecar" {
    _load_module
    module_standalone_main install
    module_standalone_main remove
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/claude-code-config" ]]
}

@test "purge deletes the sidecar" {
    _load_module
    module_standalone_main install
    module_standalone_main purge
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/claude-code-config" ]]
}

# ── upgrade ──────────────────────────────────────────────────────────────────

@test "upgrade restores drifted settings back to the template content" {
    _load_module
    install
    printf '{ "drifted": true }\n' > "${HOME}/.claude/settings.json"
    upgrade
    grep -qF "${CONFIG_MARKER}" "${HOME}/.claude/settings.json"
}

@test "upgrade works as initial drop when nothing is installed" {
    _load_module
    run upgrade
    assert_success
    [[ -f "${HOME}/.claude/settings.json" ]]
    [[ -x "${HOME}/.claude/run-ccstatusline.sh" ]]
}

# ── remove / purge ───────────────────────────────────────────────────────────

@test "remove deletes all three dropped files + the XDG layout" {
    _load_module
    install
    remove
    [[ ! -e "${HOME}/.claude/settings.json" ]]
    [[ ! -e "${HOME}/.claude/run-ccstatusline.sh" ]]
    [[ ! -e "${HOME}/.claude/settings.statusline.json" ]]
    [[ ! -e "${HOME}/.config/ccstatusline/settings.json" ]]
}

@test "remove does not touch unmanaged files in ~/.claude" {
    _load_module
    install
    mkdir -p "${HOME}/.claude"
    printf 'user data\n' > "${HOME}/.claude/CLAUDE.md"
    remove
    [[ -f "${HOME}/.claude/CLAUDE.md" ]]
}

@test "purge deletes all three dropped files + the XDG layout" {
    _load_module
    install
    purge
    [[ ! -e "${HOME}/.claude/settings.json" ]]
    [[ ! -e "${HOME}/.claude/run-ccstatusline.sh" ]]
    [[ ! -e "${HOME}/.claude/settings.statusline.json" ]]
    [[ ! -e "${HOME}/.config/ccstatusline/settings.json" ]]
}

# ── Idempotency (AC-5 pattern) ───────────────────────────────────────────────

@test "install twice exits 0 both times and converges (AC-5)" {
    _load_module
    run install
    assert_success
    local _hash1; _hash1="$(cat "${HOME}/.claude/settings.json")"
    run install
    assert_success
    [[ "$(cat "${HOME}/.claude/settings.json")" == "${_hash1}" ]]
}

@test "install short-circuits the primary drop when already installed" {
    _load_module
    install
    run install
    assert_success
    assert_output --partial "already installed"
}

@test "remove is idempotent — second run still exits 0" {
    _load_module
    install
    run remove
    assert_success
    run remove
    assert_success
}

@test "purge is idempotent — second run still exits 0" {
    _load_module
    run purge
    assert_success
    run purge
    assert_success
}

# ── is_installed ─────────────────────────────────────────────────────────────

@test "is_installed fails when settings.json is absent" {
    _load_module
    run is_installed
    assert_failure
}

@test "is_installed fails when settings.json exists without the marker" {
    _load_module
    mkdir -p "${HOME}/.claude"
    printf '{ "foreign": true }\n' > "${HOME}/.claude/settings.json"
    run is_installed
    assert_failure
}

# ── verify / doctor / is_outdated ────────────────────────────────────────────

@test "verify fails when not installed" {
    _load_module
    run verify
    assert_failure
}

@test "verify passes after a real install (TEST_VERIFY_CMD)" {
    _load_module
    install
    run verify
    assert_success
}

@test "doctor fails when not installed" {
    _load_module
    run doctor
    assert_failure
}

@test "doctor passes after a real install" {
    _load_module
    module_standalone_main install
    run doctor
    assert_success
}

@test "doctor fails when run-ccstatusline.sh lost its executable bit" {
    _load_module
    module_standalone_main install
    chmod 644 "${HOME}/.claude/run-ccstatusline.sh"
    run doctor
    assert_failure
}

@test "doctor warns (but passes) when the sidecar is missing" {
    _load_module
    module_standalone_main install
    rm -f "${INIT_UBUNTU_STATE_DIR}/versions/claude-code-config"
    run doctor
    assert_success
    assert_output --partial "sidecar missing"
}

@test "is_outdated fails when not installed" {
    _load_module
    run is_outdated
    assert_failure
}

@test "is_outdated fails right after a fresh install (up to date)" {
    _load_module
    install
    run is_outdated
    assert_failure
}

@test "is_outdated succeeds when a dropped file drifted from the template" {
    _load_module
    install
    printf '\n' >> "${HOME}/.claude/settings.statusline.json"
    run is_outdated
    assert_success
}

@test "is_outdated succeeds when a companion file was deleted" {
    _load_module
    install
    rm -f "${HOME}/.claude/run-ccstatusline.sh"
    run is_outdated
    assert_success
}

# ── detect / is_recommended ──────────────────────────────────────────────────

@test "detect succeeds with a normal HOME" {
    _load_module
    run detect
    assert_success
}

@test "detect fails when HOME points nowhere" {
    _load_module
    HOME="${INIT_UBUNTU_TEST_SCRATCH}/does-not-exist" run detect
    assert_failure
}

@test "is_recommended is zero when claude is on PATH and config not dropped" {
    _load_module
    _fake_claude_on_path
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run is_recommended
    assert_success
}

@test "is_recommended is nonzero when already installed" {
    _load_module
    _fake_claude_on_path
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run is_recommended
    assert_failure
}

@test "is_recommended is nonzero when the claude CLI is absent" {
    _load_module
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin" run is_recommended
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
    assert_output --partial "claude-code-config"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module nope
    assert_failure 2
}

@test "standalone: info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        claude-code-config"
    assert_output --partial "category:    optional"
    assert_output --partial "agent"
    assert_output --partial "depends_on:  claude-code"
}

@test "standalone: info --lang=zh-TW prints localized description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "設定"
}

@test "standalone: status reports installed + outdated fields" {
    run _standalone_module status
    assert_success
    assert_output --partial "installed:"
    assert_output --partial "outdated:"
}

# ── Standalone full cycle (AC-23: state.json never touched) ──────────────────

@test "standalone: install -> remove cycle never creates state.json" {
    run _standalone_module install
    assert_success
    [[ -f "${TEST_HOME}/.claude/settings.json" ]]
    [[ -f "${TEST_HOME}/.local/state/init_ubuntu/versions/claude-code-config" ]]
    run _standalone_module remove
    assert_success
    [[ ! -e "${TEST_HOME}/.claude/settings.json" ]]
    [[ ! -e "${TEST_HOME}/.local/state/init_ubuntu/versions/claude-code-config" ]]
    [[ ! -e "${TEST_HOME}/.local/state/init_ubuntu/state.json" ]]
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
    run _standalone_module is-outdated
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: doctor is implemented (exit != 2)" {
    run _standalone_module doctor
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}
