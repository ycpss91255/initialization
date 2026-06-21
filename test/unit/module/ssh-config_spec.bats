#!/usr/bin/env bats
# test/unit/module/ssh-config_spec.bats — module/ssh-config.module.sh
#
# Per Q29: smoke / metadata / lifecycle dry-run / no-side-fx / sidecar
# semantics (ADR-0001) / idempotency (AC-5) / standalone CLI (AC-25) /
# module-specific (pure config-drop archetype: marker injection, SSH file
# modes 600/700, overwrite-with-backup upgrade, key files never touched).
#
# ssh-config wires the plain config-drop archetype with NO overrides, so
# 8 of the 10 lifecycle hooks exist (doctor / is_outdated are optional and
# absent); the standalone CLI must degrade gracefully for the missing two.

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
# CONFIG_DEST / TEST_VERIFY_CMD (computed at source time) land inside the
# test sandbox.
_load_module() {
    export HOME="${TEST_HOME}"
    # shellcheck source=../../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../../lib/general.sh
    source "${LIB_DIR}/general.sh"
    # shellcheck source=../../../lib/module_helper.sh
    source "${LIB_DIR}/module_helper.sh"
    # shellcheck source=../../../module/ssh-config.module.sh
    source "${MODULE_DIR}/ssh-config.module.sh"
}

# _standalone_module runs the module as a self-contained CLI inside the
# scratch HOME (the same entry users hit when they type
# `bash module/ssh-config.module.sh ...`).
_standalone_module() {
    # Drop the test-env state-dir override so any state lands under the
    # scratch XDG_STATE_HOME, exactly like a real user invocation.
    env -u INIT_UBUNTU_STATE_DIR \
        HOME="${TEST_HOME}" XDG_STATE_HOME="${TEST_HOME}/.local/state" \
        bash "${MODULE_DIR}/ssh-config.module.sh" "$@"
}

# Some upgrade paths route through backup_file (lib/general.sh), which
# log_fatals when BACKUP_DIR is unset. Helper (not inline in the @test
# bodies: shellcheck SC2030/SC2031 flag cross-test var modification).
_use_backup_dir() {
    export BACKUP_DIR="${INIT_UBUNTU_TEST_SCRATCH}/backup"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "ssh-config module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/ssh-config.module.sh"
    assert_success
}

@test "ssh-config sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "ssh-config defines the 8 implemented lifecycle functions" {
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

@test "ssh-config inherits doctor / is_outdated from the config macro (ADR-0002)" {
    # The macros now emit the full lifecycle: doctor (module_default_doctor)
    # and is_outdated (module_default_config_is_outdated).
    _load_module
    run declare -F doctor
    assert_success
    run declare -F is_outdated
    assert_success
}

# ── Metadata sanity ──────────────────────────────────────────────────────────

@test "ssh-config declares NAME=ssh-config" {
    _load_module
    [[ "${NAME}" == "ssh-config" ]]
}

@test "ssh-config CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "ssh-config TAGS are config ssh dotfile" {
    _load_module
    [[ "${TAGS[0]}" == "config" ]]
    [[ " ${TAGS[*]} " == *" ssh "* ]]
    [[ " ${TAGS[*]} " == *" dotfile "* ]]
}

@test "ssh-config has no dependencies or conflicts" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 0 ]]
    [[ "${#CONFLICTS_WITH[@]}" -eq 0 ]]
}

@test "ssh-config DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "ssh-config module_get_description returns language-specific text" {
    _load_module
    [[ "$(module_get_description en)" == *".ssh/config"* ]]
    [[ -n "$(module_get_description zh-TW)" ]]
    # Unknown language falls back to en.
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "ssh-config declares the overwrite WARN_MESSAGE and key-mode POST_INSTALL_MESSAGE" {
    _load_module
    [[ "$(module_get_warn_message en)" == *"overwritten"* ]]
    [[ "$(module_get_post_install_message en)" == *"600"* ]]
    [[ -n "$(module_get_warn_message zh-TW)" ]]
    [[ -n "$(module_get_post_install_message zh-TW)" ]]
}

@test "ssh-config SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "ssh-config RISK_LEVEL=low and no reboot required" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
    [[ "${REBOOT_REQUIRED}" == "false" ]]
}

@test "ssh-config is a user-home config drop (no sudo)" {
    _load_module
    [[ "${SUPPORTS_USER_HOME}" == "true" ]]
    [[ "${INSTALL_TARGET_DEFAULT}" == "user-home" ]]
}

@test "ssh-config archetype data targets ~/.ssh/config with SSH-safe modes" {
    _load_module
    [[ "${CONFIG_DEST}" == "${HOME}/.ssh/config" ]]
    [[ "${CONFIG_MARKER}" == "# init_ubuntu managed" ]]
    [[ "${CONFIG_MODE}" == "600" ]]
    [[ "${CONFIG_DIR_MODE}" == "700" ]]
}

@test "ssh-config template source lives in module/config/ssh_config and exists" {
    _load_module
    [[ "${CONFIG_TEMPLATE_SRC}" == *"/config/ssh_config" ]]
    [[ -f "${CONFIG_TEMPLATE_SRC}" ]]
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
    [[ ! -e "${HOME}/.ssh" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/ssh-config" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "dry-run remove leaves the dropped config in place" {
    _load_module
    install
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    [[ -f "${HOME}/.ssh/config" ]]
}

@test "standalone dry-run install creates no files in a scratch HOME" {
    run _standalone_module install --dry-run
    assert_success
    local _leftover
    _leftover="$(find "${TEST_HOME}" -mindepth 1 2>/dev/null)"
    [[ -z "${_leftover}" ]]
}

# ── install drops the config ─────────────────────────────────────────────────

@test "install drops ~/.ssh/config with the marker injected on line 1" {
    _load_module
    run install
    assert_success
    [[ -f "${HOME}/.ssh/config" ]]
    # Template ships without the marker; the archetype must inject it first.
    [[ "$(head -n 1 "${HOME}/.ssh/config")" == "${CONFIG_MARKER}" ]]
}

@test "install preserves the template content after the marker" {
    _load_module
    install
    # Line 2 of the drop is line 1 of the shipped template.
    [[ "$(sed -n '2p' "${HOME}/.ssh/config")" == "$(head -n 1 "${CONFIG_TEMPLATE_SRC}")" ]]
    grep -q "^Host github$" "${HOME}/.ssh/config"
}

@test "install sets mode 600 on config and 700 on ~/.ssh" {
    _load_module
    install
    [[ "$(stat -c '%a' "${HOME}/.ssh/config")" == "600" ]]
    [[ "$(stat -c '%a' "${HOME}/.ssh")" == "700" ]]
}

@test "install overwrites a foreign unmanaged ~/.ssh/config (per WARN_MESSAGE)" {
    _load_module
    mkdir -p "${HOME}/.ssh"
    printf 'Host foreign\n' > "${HOME}/.ssh/config"
    install
    [[ "$(head -n 1 "${HOME}/.ssh/config")" == "${CONFIG_MARKER}" ]]
    run ! grep -q "^Host foreign$" "${HOME}/.ssh/config"
}

@test "install then is_installed returns 0" {
    _load_module
    install
    run is_installed
    assert_success
}

# ── Sidecar semantics (ADR-0001) ─────────────────────────────────────────────

@test "install never touches state.json (ADR-0001 / AC-23 pattern)" {
    _load_module
    printf '{"schema_version":"0.1.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "install via the invoker records the sidecar with VERSION_PROVIDED" {
    # New design (ADR-0001 refinement): install() drops ~/.ssh/config but does
    # NOT write the sidecar; the invoker module_standalone_main records it from
    # module_provided_version (config archetype → VERSION_PROVIDED).
    _load_module
    module_standalone_main install
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/ssh-config" ]]
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/ssh-config")" == "${VERSION_PROVIDED}" ]]
}

@test "bare install() drops the config but writes no sidecar (invoker owns it)" {
    _load_module
    install
    # A bare install() mutates the system but leaves versions/ untouched —
    # only the invoker writes the sidecar.
    [[ -f "${HOME}/.ssh/config" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/ssh-config" ]]
}

@test "invoker remove clears the sidecar it wrote at install" {
    _load_module
    module_standalone_main install
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/ssh-config" ]]
    module_standalone_main remove
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/ssh-config" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

# ── upgrade ──────────────────────────────────────────────────────────────────

@test "upgrade works as initial drop when nothing is installed" {
    _load_module
    run upgrade
    assert_success
    [[ -f "${HOME}/.ssh/config" ]]
    [[ "$(head -n 1 "${HOME}/.ssh/config")" == "${CONFIG_MARKER}" ]]
}

@test "upgrade restores drifted config back to the template content" {
    _load_module
    _use_backup_dir
    install
    printf '# init_ubuntu managed\nHost drifted\n' > "${HOME}/.ssh/config"
    upgrade
    grep -q "^Host github$" "${HOME}/.ssh/config"
    run ! grep -q "^Host drifted$" "${HOME}/.ssh/config"
}

@test "upgrade backs up the pre-existing config into BACKUP_DIR" {
    _load_module
    _use_backup_dir
    install
    upgrade
    [[ -f "${BACKUP_DIR}/config" ]]
}

@test "upgrade over an existing config fails fatally when BACKUP_DIR is unset" {
    # backup_file (lib/general.sh) log_fatals without BACKUP_DIR; the
    # archetype's `|| true` cannot catch an exit. Documents the current
    # contract: standalone upgrades need BACKUP_DIR when a config exists.
    _load_module
    install
    BACKUP_DIR='' run upgrade
    assert_failure
    assert_output --partial "BACKUP_DIR is not set"
}

# ── remove / purge ───────────────────────────────────────────────────────────

@test "remove deletes the dropped config" {
    _load_module
    install
    remove
    [[ ! -e "${HOME}/.ssh/config" ]]
}

@test "remove never touches private keys in ~/.ssh" {
    _load_module
    install
    printf 'FAKE KEY MATERIAL\n' > "${HOME}/.ssh/id_ed25519"
    remove
    [[ -f "${HOME}/.ssh/id_ed25519" ]]
}

@test "purge deletes the config but never touches private keys (purge == remove)" {
    _load_module
    install
    printf 'FAKE KEY MATERIAL\n' > "${HOME}/.ssh/id_ed25519"
    purge
    [[ ! -e "${HOME}/.ssh/config" ]]
    [[ -f "${HOME}/.ssh/id_ed25519" ]]
}

# ── Idempotency (AC-5 pattern) ───────────────────────────────────────────────

@test "install twice exits 0 both times and converges (AC-5)" {
    _load_module
    run install
    assert_success
    local _content1; _content1="$(cat "${HOME}/.ssh/config")"
    run install
    assert_success
    [[ "$(cat "${HOME}/.ssh/config")" == "${_content1}" ]]
}

@test "install short-circuits the drop when already installed" {
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

@test "is_installed fails when ~/.ssh/config is absent" {
    _load_module
    run is_installed
    assert_failure
}

@test "is_installed fails when ~/.ssh/config exists without the marker" {
    _load_module
    mkdir -p "${HOME}/.ssh"
    printf 'Host foreign\n' > "${HOME}/.ssh/config"
    run is_installed
    assert_failure
}

# ── verify ───────────────────────────────────────────────────────────────────

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

# ── detect / is_recommended ──────────────────────────────────────────────────

@test "detect always succeeds (config drop has no platform precondition)" {
    _load_module
    run detect
    assert_success
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
    assert_output --partial "ssh-config"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module nope
    assert_failure 2
}

@test "standalone: info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        ssh-config"
    assert_output --partial "category:    optional"
    assert_output --partial "config ssh dotfile"
    # No deps: the depends_on line must be omitted entirely.
    refute_output --partial "depends_on:"
}

@test "standalone: info --lang=zh-TW prints localized description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "個人"
}

@test "standalone: status reports installed + outdated fields" {
    # is_outdated is now wired (config default returns 1 = not outdated).
    run _standalone_module status
    assert_success
    assert_output --partial "installed:   no"
    assert_output --partial "outdated:    no"
}

# ── Standalone full cycle (AC-23: state.json never touched) ──────────────────

@test "standalone: install -> remove cycle never creates state.json" {
    run _standalone_module install
    assert_success
    [[ -f "${TEST_HOME}/.ssh/config" ]]
    run _standalone_module remove
    assert_success
    [[ ! -e "${TEST_HOME}/.ssh/config" ]]
    [[ ! -e "${TEST_HOME}/.local/state/init_ubuntu/state.json" ]]
}

@test "standalone: install applies SSH-safe modes in a real user HOME" {
    run _standalone_module install
    assert_success
    [[ "$(stat -c '%a' "${TEST_HOME}/.ssh/config")" == "600" ]]
    [[ "$(stat -c '%a' "${TEST_HOME}/.ssh")" == "700" ]]
}

# ── AC-25: every phase runnable; optional hooks degrade gracefully ───────────

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
