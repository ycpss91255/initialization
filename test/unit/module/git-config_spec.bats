#!/usr/bin/env bats
# test/unit/module/git-config_spec.bats — module/git-config.module.sh
#
# Per Q29: smoke / metadata / lifecycle dry-run / no-side-fx / idempotency /
# standalone CLI / module-specific (pure config-drop archetype, marker
# injection into a non-marker template, sidecar semantics ADR-0001).
#
# git-config is a PURE config-drop archetype module (no hand-written
# lifecycle overrides): it wires is_installed/install/upgrade/remove/purge/
# verify via module_use_config_archetype and adds only detect +
# is_recommended. is_outdated and doctor are intentionally not implemented
# (optional per module-spec §4.1) — the standalone CLI exits 2 with
# "not implemented" for those phases.

bats_require_minimum_version 1.5.0

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
    # shellcheck source=../../../module/git-config.module.sh
    source "${MODULE_DIR}/git-config.module.sh"
}

# _standalone_module runs the module as a self-contained CLI inside the
# scratch HOME (the same entry users hit when they type
# `bash module/git-config.module.sh ...`).
_standalone_module() {
    # Drop the test-env state-dir override so any state writes would land
    # under the scratch XDG_STATE_HOME, exactly like a real user invocation.
    # cwd = scratch HOME: TEST_VERIFY_CMD shells out to git, whose repo
    # discovery must not start inside the repo mount (a worktree's .git
    # gitfile points at a host path that does not exist in the container).
    cd "${TEST_HOME}" \
        && env -u INIT_UBUNTU_STATE_DIR \
            HOME="${TEST_HOME}" XDG_STATE_HOME="${TEST_HOME}/.local/state" \
            bash "${MODULE_DIR}/git-config.module.sh" "$@"
}

# _in_home <cmd> [args...] — run a lifecycle function or git command with
# cwd outside the repo mount (same git repo-discovery concern as above).
# Only used inside bats `run` or $(...) subshells, so the cd is contained.
_in_home() {
    cd "${HOME}" && "$@"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "git-config module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/git-config.module.sh"
    assert_success
}

@test "git-config sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "git-config defines the 5 mandatory + 3 archetype lifecycle functions" {
    _load_module
    local _fn
    for _fn in detect is_recommended is_installed install upgrade \
               remove purge verify; do
        declare -F "${_fn}" >/dev/null || {
            printf 'missing lifecycle function: %s\n' "${_fn}" >&2
            return 1
        }
    done
}

@test "git-config inherits is_outdated and doctor from the config macro (ADR-0002)" {
    _load_module
    # The macros now emit the full lifecycle: is_outdated
    # (module_default_config_is_outdated, returns 1 = not outdated) and doctor
    # (module_default_doctor).
    run declare -F is_outdated
    assert_success
    run declare -F doctor
    assert_success
}

# ── Metadata sanity ──────────────────────────────────────────────────────────

@test "git-config declares NAME=git-config" {
    _load_module
    [[ "${NAME}" == "git-config" ]]
}

@test "git-config CATEGORY=recommended" {
    _load_module
    [[ "${CATEGORY}" == "recommended" ]]
}

@test "git-config TAGS contain config + git + dotfile" {
    _load_module
    [[ " ${TAGS[*]} " == *" config "* ]]
    [[ " ${TAGS[*]} " == *" git "* ]]
    [[ " ${TAGS[*]} " == *" dotfile "* ]]
}

@test "git-config DEPENDS_ON is exactly git (module name only, Q39)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 1 ]]
    [[ "${DEPENDS_ON[0]}" == "git" ]]
}

@test "git-config DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "git-config module_get_description returns language-specific text" {
    _load_module
    [[ "$(module_get_description en)" == *".gitconfig"* ]]
    [[ -n "$(module_get_description zh-TW)" ]]
    # Unknown language falls back to en.
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "git-config POST_INSTALL_MESSAGE tells the user to set name + email" {
    _load_module
    [[ "$(module_get_post_install_message en)" == *"name"* ]]
    [[ "$(module_get_post_install_message en)" == *"email"* ]]
    [[ -n "$(module_get_post_install_message zh-TW)" ]]
}

@test "git-config SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "git-config RISK_LEVEL=low, no reboot" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
    [[ "${REBOOT_REQUIRED}" == "false" ]]
}

@test "git-config is a user-home config drop (no sudo)" {
    _load_module
    [[ "${SUPPORTS_USER_HOME}" == "true" ]]
    [[ "${INSTALL_TARGET_DEFAULT}" == "user-home" ]]
}

@test "git-config archetype data targets ~/.gitconfig" {
    _load_module
    [[ "${CONFIG_DEST}" == "${HOME}/.gitconfig" ]]
}

@test "git-config template source lives in module/config/git_config and exists" {
    _load_module
    [[ "${CONFIG_TEMPLATE_SRC}" == *"/config/git_config" ]]
    [[ -f "${CONFIG_TEMPLATE_SRC}" ]]
}

@test "git-config template has no marker — archetype injects it at drop time" {
    _load_module
    [[ "${CONFIG_MARKER}" == "# init_ubuntu managed" ]]
    # Unlike JSON drops, '#' is a legal gitconfig comment, so the template
    # ships clean and _module_config_drop sed-injects the marker as line 1.
    run grep -qF "${CONFIG_MARKER}" "${CONFIG_TEMPLATE_SRC}"
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

@test "dry-run install writes nothing to HOME or the state dir" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ ! -e "${HOME}/.gitconfig" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/git-config" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "dry-run remove leaves the dropped file in place" {
    _load_module
    install
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    [[ -f "${HOME}/.gitconfig" ]]
}

@test "standalone dry-run install creates no files in a scratch HOME" {
    run _standalone_module install --dry-run
    assert_success
    local _leftover
    _leftover="$(find "${TEST_HOME}" -mindepth 1 2>/dev/null)"
    [[ -z "${_leftover}" ]]
}

# ── install drops ~/.gitconfig ───────────────────────────────────────────────

@test "install drops ~/.gitconfig with the marker injected as line 1" {
    _load_module
    run install
    assert_success
    [[ -f "${HOME}/.gitconfig" ]]
    [[ "$(head -n1 "${HOME}/.gitconfig")" == "${CONFIG_MARKER}" ]]
}

@test "install applies CONFIG_MODE=644 to the dropped file" {
    _load_module
    install
    [[ "$(stat -c '%a' "${HOME}/.gitconfig")" == "644" ]]
}

@test "dropped ~/.gitconfig parses as valid git config" {
    _load_module
    install
    run _in_home git config --file "${HOME}/.gitconfig" --list
    assert_success
}

@test "dropped config sets init.defaultBranch=main" {
    _load_module
    install
    run _in_home git config --file "${HOME}/.gitconfig" --get init.defaultBranch
    assert_success
    assert_output "main"
}

@test "dropped config wires delta as pager + nvim as editor" {
    _load_module
    install
    [[ "$(_in_home git config --file "${HOME}/.gitconfig" --get core.pager)" == "delta" ]]
    [[ "$(_in_home git config --file "${HOME}/.gitconfig" --get core.editor)" == "nvim" ]]
}

@test "dropped config carries the st alias (module template content)" {
    _load_module
    install
    run _in_home git config --file "${HOME}/.gitconfig" --get alias.st
    assert_success
    assert_output "status"
}

@test "install then is_installed returns 0" {
    _load_module
    install
    run is_installed
    assert_success
}

# ── Sidecar / state semantics (ADR-0001 / AC-23) ─────────────────────────────

@test "install via the invoker records the sidecar with VERSION_PROVIDED" {
    _load_module
    # New design (ADR-0001 refinement): install() drops ~/.gitconfig but does
    # NOT write the sidecar; the invoker module_standalone_main records it from
    # module_provided_version (config archetype → VERSION_PROVIDED).
    module_standalone_main install
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/git-config" ]]
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/git-config")" == "${VERSION_PROVIDED}" ]]
}

@test "bare install() drops the config but writes no sidecar (invoker owns it)" {
    _load_module
    install
    # A bare install() mutates the system (drops ~/.gitconfig) but leaves the
    # versions/ dir untouched — only the invoker writes the sidecar.
    [[ -f "${HOME}/.gitconfig" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/git-config" ]]
}

@test "install never touches state.json (ADR-0001 / AC-23 pattern)" {
    _load_module
    printf '{"schema_version":"0.1.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "standalone: install writes a sidecar; remove clears it, never state.json" {
    run _standalone_module install
    assert_success
    [[ -f "${TEST_HOME}/.gitconfig" ]]
    # The invoker (module_standalone_main install) records the sidecar.
    [[ -f "${TEST_HOME}/.local/state/init_ubuntu/versions/git-config" ]]
    run _standalone_module remove
    assert_success
    [[ ! -e "${TEST_HOME}/.gitconfig" ]]
    [[ ! -e "${TEST_HOME}/.local/state/init_ubuntu/state.json" ]]
    [[ ! -e "${TEST_HOME}/.local/state/init_ubuntu/versions/git-config" ]]
}

# ── upgrade ──────────────────────────────────────────────────────────────────

@test "upgrade restores a drifted ~/.gitconfig back to the template content" {
    _load_module
    install
    printf '[user]\n    name = Drifted\n' > "${HOME}/.gitconfig"
    BACKUP_DIR="${INIT_UBUNTU_TEST_SCRATCH}/backup" run upgrade
    assert_success
    grep -qF "${CONFIG_MARKER}" "${HOME}/.gitconfig"
    [[ "$(_in_home git config --file "${HOME}/.gitconfig" --get init.defaultBranch)" == "main" ]]
}

@test "upgrade backs up the pre-existing file into BACKUP_DIR first" {
    _load_module
    install
    printf '[user]\n    name = Keep Me\n' > "${HOME}/.gitconfig"
    BACKUP_DIR="${INIT_UBUNTU_TEST_SCRATCH}/backup" run upgrade
    assert_success
    [[ -f "${INIT_UBUNTU_TEST_SCRATCH}/backup/.gitconfig" ]]
    grep -qF "Keep Me" "${INIT_UBUNTU_TEST_SCRATCH}/backup/.gitconfig"
}

@test "upgrade works as initial drop when nothing is installed" {
    _load_module
    # No pre-existing ~/.gitconfig — the backup_file branch is skipped, so
    # no BACKUP_DIR is needed for a fresh drop.
    run upgrade
    assert_success
    [[ -f "${HOME}/.gitconfig" ]]
    grep -qF "${CONFIG_MARKER}" "${HOME}/.gitconfig"
}

# ── remove / purge ───────────────────────────────────────────────────────────

@test "remove deletes ~/.gitconfig" {
    _load_module
    install
    remove
    [[ ! -e "${HOME}/.gitconfig" ]]
}

@test "remove does not touch other dotfiles in HOME" {
    _load_module
    install
    printf 'user data\n' > "${HOME}/.bashrc"
    remove
    [[ -f "${HOME}/.bashrc" ]]
}

@test "purge deletes ~/.gitconfig (config drop: purge == remove)" {
    _load_module
    install
    purge
    [[ ! -e "${HOME}/.gitconfig" ]]
}

# ── Idempotency (AC-5 pattern) ───────────────────────────────────────────────

@test "install twice exits 0 both times and converges (AC-5)" {
    _load_module
    run install
    assert_success
    local _content1; _content1="$(cat "${HOME}/.gitconfig")"
    run install
    assert_success
    [[ "$(cat "${HOME}/.gitconfig")" == "${_content1}" ]]
}

@test "install short-circuits when already installed" {
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

@test "is_installed fails when ~/.gitconfig is absent" {
    _load_module
    run is_installed
    assert_failure
}

@test "is_installed fails on a foreign ~/.gitconfig without the marker" {
    _load_module
    printf '[user]\n    name = Someone Else\n' > "${HOME}/.gitconfig"
    run is_installed
    assert_failure
}

# ── verify ───────────────────────────────────────────────────────────────────

@test "verify fails when not installed" {
    _load_module
    run verify
    assert_failure
}

@test "verify passes after a real install (TEST_VERIFY_CMD parses the drop)" {
    _load_module
    install
    # TEST_VERIFY_CMD = `git config --global --list >/dev/null` — git reads
    # the dropped ${HOME}/.gitconfig, so this also proves the file parses.
    run _in_home verify
    assert_success
}

# ── detect / is_recommended ──────────────────────────────────────────────────

@test "detect succeeds when git is on PATH" {
    _load_module
    run detect
    assert_success
}

@test "detect fails when git is absent from PATH" {
    _load_module
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin" run detect
    assert_failure
}

@test "is_recommended is zero when the config is not yet dropped" {
    _load_module
    run is_recommended
    assert_success
}

@test "is_recommended is nonzero once installed" {
    _load_module
    install
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
    assert_output --partial "git-config"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module nope
    assert_failure 2
}

@test "standalone: info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        git-config"
    assert_output --partial "category:    recommended"
    assert_output --partial "dotfile"
    assert_output --partial "depends_on:  git"
}

@test "standalone: info --lang=zh-TW prints localized description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "設定"
}

@test "standalone: status reports installed + outdated fields" {
    # is_outdated is now wired (config default returns 1 = not outdated).
    run _standalone_module status
    assert_success
    assert_output --partial "installed:   no"
    assert_output --partial "outdated:    no"
}

@test "standalone: install -> verify -> remove full cycle" {
    run _standalone_module install
    assert_success
    [[ -f "${TEST_HOME}/.gitconfig" ]]
    run _standalone_module verify
    assert_success
    run _standalone_module remove
    assert_success
    [[ ! -e "${TEST_HOME}/.gitconfig" ]]
}

# ── AC-25: every implemented phase runnable; optional ones exit 2 cleanly ────

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

@test "standalone: is-outdated is implemented (config default; exit != 2)" {
    run _standalone_module is-outdated
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: doctor is implemented (default = is_installed; exit != 2)" {
    run _standalone_module doctor
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}
