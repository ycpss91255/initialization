#!/usr/bin/env bats
# test/unit/module/fish_spec.bats — module/fish.module.sh
#
# Per Q29 (issue #123 Batch-A backfill): smoke / metadata / lifecycle dry-run /
# no-side-fx / idempotency / standalone CLI / module-specific (apt+PPA
# archetype with overridden install/upgrade: config drop + fisher plugins +
# chsh; sidecar semantics per ADR-0001).

bats_require_minimum_version 1.5.0

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
    # shellcheck source=../../../module/fish.module.sh
    source "${MODULE_DIR}/fish.module.sh"
}

# _standalone_module runs the module as a self-contained CLI (the same
# entry users hit when they type `bash module/fish.module.sh ...`).
_standalone_module() {
    bash "${MODULE_DIR}/fish.module.sh" "$@"
}

# Point HOME at a scratch dir so config drops / purges never touch the real
# container HOME. Must run BEFORE _load_module when the test exercises
# CONFIG_PATHS (the module bakes ${HOME} into it at source time).
_scratch_home() {
    HOME="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${HOME}"
    export HOME
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
#   MOCK_DPKG_RC          nonzero = every query fails (nothing installed)
#   MOCK_DPKG_MISSING_PKG one package name that reports not-installed
_mock_dpkg() {
    dpkg() {
        [[ "${MOCK_DPKG_RC:-0}" -eq 0 ]] || return "${MOCK_DPKG_RC}"
        if [[ "${2:-}" == "${MOCK_DPKG_MISSING_PKG:-__none__}" ]]; then
            return 1
        fi
        printf 'ii  %s  4.0.0-1  amd64  mock package\n' "${2:-}"
    }
}

# apt archetype default mocks: MOCK_APT_<PHASE>_RC (default 0 = success).
_mock_apt_defaults() {
    module_default_apt_install() { return "${MOCK_APT_INSTALL_RC:-0}"; }
    module_default_apt_upgrade() { return "${MOCK_APT_UPGRADE_RC:-0}"; }
    module_default_apt_remove()  { return "${MOCK_APT_REMOVE_RC:-0}"; }
    module_default_apt_purge()   { return "${MOCK_APT_PURGE_RC:-0}"; }
}

# apt mock for module_default_apt_is_outdated: MOCK_APT_UPGRADABLE
# (full `apt list --upgradable` output to emit; empty = no output).
_mock_apt_list() {
    apt() { printf '%s' "${MOCK_APT_UPGRADABLE:-}"; }
}

# fish binary mock (functions shadow PATH lookup AND satisfy `command -v`):
# MOCK_FISH_RC (default 0); each invocation echoes its args for assertions.
_mock_fish() {
    fish() {
        printf 'fish-called: %s\n' "$*"
        return "${MOCK_FISH_RC:-0}"
    }
}

# sudo mock: records the command line, MOCK_SUDO_RC (default 0).
_mock_sudo() {
    sudo() {
        printf 'sudo: %s\n' "$*"
        return "${MOCK_SUDO_RC:-0}"
    }
}

# have_sudo_access mock: MOCK_SUDO_ACCESS_RC (0 = has sudo).
_mock_have_sudo() {
    have_sudo_access() { return "${MOCK_SUDO_ACCESS_RC:-0}"; }
}

# backup_file mock: records the call (real one log_fatals without BACKUP_DIR).
_mock_backup_file() {
    backup_file() { printf 'backup-called: %s\n' "$*"; }
}

# Neutralize the network/system-touching post-install steps while keeping the
# config drop real; each prints a marker so chaining can be asserted.
_mock_fisher_and_chsh() {
    _install_fisher_plugins()      { printf 'fisher-plugins-run\n'; }
    _switch_default_shell_to_fish() { printf 'chsh-run\n'; }
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "fish module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/fish.module.sh"
    assert_success
}

@test "fish module sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "fish module defines the 9 implemented lifecycle functions" {
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

@test "fish module inherits doctor from the apt archetype macro (ADR-0002)" {
    # The macros now emit the full lifecycle incl. doctor (module_default_doctor).
    _load_module
    run declare -F doctor
    assert_success
}

@test "fish module ships its config payload at module/config/fish" {
    [[ -d "${MODULE_DIR}/config/fish" ]]
    [[ -f "${MODULE_DIR}/config/fish/config.fish" ]]
    [[ -f "${MODULE_DIR}/config/fish/fish_plugins" ]]
}

# ── ctop.fish tool wrapper (issue #271) ──────────────────────────────────────
# The Ubuntu-packaged ctop is broken on this host (cgroup v2 lookup + a
# termbox panic under tmux-256color). The repo ships a fish function that
# wraps the upstream binary and overrides $TERM for the call only.

@test "fish module ships the ctop.fish tool function" {
    [[ -f "${MODULE_DIR}/config/fish/functions/ctop.fish" ]]
}

@test "ctop.fish defines a ctop function wrapping ctop" {
    local _f="${MODULE_DIR}/config/fish/functions/ctop.fish"
    grep -Eq '^function ctop' "${_f}"
    grep -q -- '--wraps' "${_f}"
    grep -Eq 'end[[:space:]]*$' "${_f}"
}

@test "ctop.fish overrides TERM to a termbox-safe value for the call" {
    local _f="${MODULE_DIR}/config/fish/functions/ctop.fish"
    grep -q 'TERM=screen-256color' "${_f}"
}

@test "ctop.fish escalates with sudo -E to preserve the TERM override" {
    local _f="${MODULE_DIR}/config/fish/functions/ctop.fish"
    grep -q 'sudo -E' "${_f}"
}

@test "ctop.fish dispatches to the absolute binary path (not 'command ctop')" {
    # sudo has no concept of the fish `command` builtin; `sudo -E command
    # ctop` fails with 'command: command not found'. The absolute path also
    # avoids the function recursing into itself.
    local _f="${MODULE_DIR}/config/fish/functions/ctop.fish"
    grep -q '/usr/local/bin/ctop' "${_f}"
    run grep -q 'command ctop' "${_f}"
    assert_failure
}

@test "ctop.fish forwards caller arguments via \$argv" {
    local _f="${MODULE_DIR}/config/fish/functions/ctop.fish"
    grep -q "\$argv" "${_f}"
}

# ── Issue #164: disable focus reporting during commands ──────────────────────
# fish injects focus-event sequences (ESC[I / ESC[O, shown as ^[[I) into
# external commands under tmux (focus-events on) + fish 4.x (fish-shell#12232).
# A conf.d snippet disables focus reporting on fish_preexec so the sequences
# stop leaking into interactive scripts, while nvim's FocusGained autoread
# still works (tmux focus-events stays on).

@test "fish ships the focus-reporting workaround conf.d snippet (#164)" {
    [[ -f "${MODULE_DIR}/config/fish/conf.d/disable_focus_during_commands.fish" ]]
}

@test "focus workaround disables focus reporting on fish_preexec (#164)" {
    local _f="${MODULE_DIR}/config/fish/conf.d/disable_focus_during_commands.fish"
    run grep -F -- '--on-event fish_preexec' "${_f}"
    [[ "${status}" -eq 0 ]]
    run grep -F -- '\e[?1004l' "${_f}"
    [[ "${status}" -eq 0 ]]
}

@test "focus workaround references upstream fish-shell#12232 (#164)" {
    run grep -F -- 'fish-shell/issues/12232' \
        "${MODULE_DIR}/config/fish/conf.d/disable_focus_during_commands.fish"
    [[ "${status}" -eq 0 ]]
}

# ── Metadata sanity ──────────────────────────────────────────────────────────

@test "fish module declares NAME=fish" {
    _load_module
    [[ "${NAME}" == "fish" ]]
}

@test "fish module CATEGORY=recommended" {
    _load_module
    [[ "${CATEGORY}" == "recommended" ]]
}

@test "fish module TAGS contains shell" {
    _load_module
    [[ " ${TAGS[*]} " == *" shell "* ]]
}

@test "fish DEPENDS_ON is exactly curl + shell" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 2 ]]
    [[ " ${DEPENDS_ON[*]} " == *" curl "* ]]
    [[ " ${DEPENDS_ON[*]} " == *" shell "* ]]
}

@test "fish DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "fish module_get_description returns language-specific text + en fallback" {
    _load_module
    [[ "$(module_get_description en)" == *"fish shell"* ]]
    [[ -n "$(module_get_description zh-TW)" ]]
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "fish SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "fish SUPPORTED_PLATFORMS targets interactive hosts (no container)" {
    _load_module
    [[ " ${SUPPORTED_PLATFORMS[*]} " == *" desktop "* ]]
    [[ " ${SUPPORTED_PLATFORMS[*]} " == *" wsl "* ]]
    [[ " ${SUPPORTED_PLATFORMS[*]} " != *" container "* ]]
}

@test "fish module RISK_LEVEL=medium (chsh changes the login shell)" {
    _load_module
    [[ "${RISK_LEVEL}" == "medium" ]]
}

@test "fish module VERSION_PROVIDED=ppa-managed" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "ppa-managed" ]]
}

@test "fish HOMEPAGE points at fishshell.com" {
    _load_module
    [[ "${HOMEPAGE}" == *"fishshell.com"* ]]
}

@test "fish archetype data installs fish + xclip apt packages" {
    _load_module
    [[ " ${APT_PKGS[*]} " == *" fish "* ]]
    [[ " ${APT_PKGS[*]} " == *" xclip "* ]]
}

@test "fish archetype data pins the fish-shell release-4 PPA" {
    _load_module
    [[ "${APT_PPA}" == "ppa:fish-shell/release-4" ]]
}

@test "fish WARN_MESSAGE warns about chsh (en + zh-TW)" {
    _load_module
    [[ "$(module_get_warn_message en)" == *"chsh"* ]]
    [[ -n "$(module_get_warn_message zh-TW)" ]]
}

@test "fish POST_INSTALL_MESSAGE tells the user to open a new terminal" {
    _load_module
    [[ "$(module_get_post_install_message en)" == *"new terminal"* ]]
    [[ -n "$(module_get_post_install_message zh-TW)" ]]
}

@test "fish CONFIG_PATHS covers ~/.config/fish (purged on purge only)" {
    _scratch_home
    _load_module
    [[ " ${CONFIG_PATHS[*]} " == *"/.config/fish "* ]]
}

# ── is_installed: requires every APT_PKGS entry ──────────────────────────────

@test "is_installed returns nonzero when dpkg reports nothing installed" {
    _load_module
    MOCK_DPKG_RC=1
    _mock_dpkg
    run is_installed
    assert_failure
}

@test "is_installed returns zero when dpkg reports fish and xclip as ii" {
    _load_module
    _mock_dpkg
    run is_installed
    assert_success
}

@test "is_installed fails when xclip is missing (both packages required)" {
    _load_module
    MOCK_DPKG_MISSING_PKG="xclip"
    _mock_dpkg
    run is_installed
    assert_failure
}

# ── Lifecycle dry-run (AC-12 pattern) ────────────────────────────────────────

@test "install in dry-run mode is a no-op naming the fish-specific steps" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    assert_output --partial "DRY-RUN"
    assert_output --partial "chsh"
}

@test "upgrade in dry-run mode is a no-op naming the fisher re-install" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run upgrade
    assert_success
    assert_output --partial "DRY-RUN"
    assert_output --partial "fisher"
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
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/fish" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "dry-run install does not drop config into HOME" {
    _scratch_home
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ ! -e "${HOME}/.config/fish" ]]
}

@test "dry-run purge leaves an existing fish config dir in place" {
    _scratch_home
    _load_module
    mkdir -p "${HOME}/.config/fish"
    INIT_UBUNTU_DRY_RUN=true run purge
    assert_success
    [[ -d "${HOME}/.config/fish" ]]
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

# ── install: config drop + fisher + chsh chain ───────────────────────────────

@test "install drops the repo fish config into ~/.config/fish" {
    _scratch_home
    _load_module
    _mock_apt_defaults
    _mock_fisher_and_chsh
    run install
    assert_success
    [[ -d "${HOME}/.config/fish" ]]
    [[ -f "${HOME}/.config/fish/config.fish" ]]
}

@test "install chains config drop -> fisher plugins -> chsh" {
    _scratch_home
    _load_module
    _mock_apt_defaults
    _mock_fisher_and_chsh
    run install
    assert_success
    assert_output --partial "dropped fish config"
    assert_output --partial "fisher-plugins-run"
    assert_output --partial "chsh-run"
}

@test "_install_fish_config backs up an existing fish config first" {
    _scratch_home
    _load_module
    _mock_backup_file
    mkdir -p "${HOME}/.config/fish"
    run _install_fish_config
    assert_success
    assert_output --partial "backup-called"
}

@test "_install_fish_config degrades to warn + rc 0 when the payload is missing" {
    _scratch_home
    _load_module
    MODULE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/no-such-module-dir" \
        run _install_fish_config
    assert_success
    assert_output --partial "config dir missing"
}

@test "failed apt install aborts before any config drop (ADR-0015 pattern)" {
    _scratch_home
    _load_module
    MOCK_APT_INSTALL_RC=1
    _mock_apt_defaults
    run install
    assert_failure
    [[ ! -e "${HOME}/.config/fish" ]]
}

# ── Sidecar semantics (ADR-0001) ─────────────────────────────────────────────

@test "install never touches state.json (ADR-0001 / AC-23 pattern)" {
    _scratch_home
    _load_module
    printf '{"schema_version":"0.1.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    _mock_apt_defaults
    _mock_fisher_and_chsh
    run install
    assert_success
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "install records no version sidecar (current behavior: ppa-managed, no sidecar wiring)" {
    # Documents the as-is contract: unlike ripgrep (super-call + sidecar),
    # fish does not call module_sidecar_write. If sidecar wiring is added
    # later, flip this assertion to match ripgrep_spec.bats.
    _scratch_home
    _load_module
    _mock_apt_defaults
    _mock_fisher_and_chsh
    run install
    assert_success
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/fish" ]]
}

# ── fisher plugins ───────────────────────────────────────────────────────────

@test "_install_fisher_plugins degrades to warn + rc 0 when fish is not on PATH" {
    _load_module
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-path" run _install_fisher_plugins
    assert_success
    assert_output --partial "not on PATH"
}

@test "_install_fisher_plugins bootstraps fisher then pins the plugin set" {
    _load_module
    _mock_fish
    run _install_fisher_plugins
    assert_success
    assert_output --partial "fisher install jorgebucaran/fisher"
    assert_output --partial "IlanCosman/tide@v6"
    assert_output --partial "PatrickF1/fzf.fish"
}

@test "_install_fisher_plugins degrades to warn + rc 0 when bootstrap fails" {
    _load_module
    MOCK_FISH_RC=1
    _mock_fish
    run _install_fisher_plugins
    assert_success
    assert_output --partial "fisher bootstrap failed"
}

@test "upgrade re-installs fisher plugins after the apt upgrade" {
    _load_module
    _mock_apt_defaults
    _mock_fisher_and_chsh
    run upgrade
    assert_success
    assert_output --partial "fisher-plugins-run"
}

@test "upgrade does not re-run chsh (install-only step)" {
    _load_module
    _mock_apt_defaults
    _mock_fisher_and_chsh
    run upgrade
    assert_success
    refute_output --partial "chsh-run"
}

# ── chsh (default shell switch) ──────────────────────────────────────────────

@test "_switch_default_shell_to_fish warns + rc 0 when fish is missing" {
    _load_module
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-path" \
        run _switch_default_shell_to_fish
    assert_success
    assert_output --partial "cannot chsh"
}

@test "_switch_default_shell_to_fish runs sudo chsh -s with the fish path" {
    _load_module
    _mock_have_sudo
    _mock_sudo
    local _bin="${INIT_UBUNTU_TEST_SCRATCH}/bin"
    mkdir -p "${_bin}"
    printf '#!/bin/sh\nexit 0\n' > "${_bin}/fish"
    chmod +x "${_bin}/fish"
    PATH="${_bin}:${PATH}" run _switch_default_shell_to_fish
    assert_success
    assert_output --partial "chsh -s ${_bin}/fish"
}

@test "_switch_default_shell_to_fish without sudo instructs a manual chsh" {
    _load_module
    MOCK_SUDO_ACCESS_RC=1
    _mock_have_sudo
    local _bin="${INIT_UBUNTU_TEST_SCRATCH}/bin"
    mkdir -p "${_bin}"
    printf '#!/bin/sh\nexit 0\n' > "${_bin}/fish"
    chmod +x "${_bin}/fish"
    PATH="${_bin}:${PATH}" run _switch_default_shell_to_fish
    assert_success
    assert_output --partial "manually"
}

@test "_switch_default_shell_to_fish degrades to warn + rc 0 when chsh fails" {
    _load_module
    _mock_have_sudo
    MOCK_SUDO_RC=1
    _mock_sudo
    local _bin="${INIT_UBUNTU_TEST_SCRATCH}/bin"
    mkdir -p "${_bin}"
    printf '#!/bin/sh\nexit 0\n' > "${_bin}/fish"
    chmod +x "${_bin}/fish"
    PATH="${_bin}:${PATH}" run _switch_default_shell_to_fish
    assert_success
    assert_output --partial "chsh failed"
}

# ── remove / purge (spec §4.7.4 split) ───────────────────────────────────────

@test "remove keeps the user fish config in place (spec §4.7.4)" {
    _scratch_home
    _load_module
    mkdir -p "${HOME}/.config/fish"
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_sudo
    run remove
    assert_success
    [[ -d "${HOME}/.config/fish" ]]
}

@test "purge removes the PPA and deletes the fish config dir" {
    _scratch_home
    _load_module
    mkdir -p "${HOME}/.config/fish"
    _mock_have_sudo
    _mock_sudo
    run purge
    assert_success
    assert_output --partial "--remove ppa:fish-shell/release-4"
    [[ ! -e "${HOME}/.config/fish" ]]
}

# ── Idempotency (AC-5 pattern) ───────────────────────────────────────────────

@test "install with package already present still (re-)drops the config" {
    _scratch_home
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    _mock_fisher_and_chsh
    run install
    assert_success
    assert_output --partial "already installed"
    [[ -d "${HOME}/.config/fish" ]]
}

@test "install twice with apt mocked exits 0 both times" {
    _scratch_home
    _load_module
    _mock_apt_defaults
    _mock_fisher_and_chsh
    # Second pass sees the config dir from the first and takes the
    # backup path; the real backup_file log_fatals without BACKUP_DIR.
    _mock_backup_file
    run install
    assert_success
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

@test "is_outdated returns zero when apt reports fish upgradable" {
    _load_module
    MOCK_APT_UPGRADABLE='fish/jammy 4.0.0-1 amd64 [upgradable from: 3.7.0-1]'
    _mock_apt_list
    run is_outdated
    assert_success
}

@test "is_outdated returns zero when only xclip is upgradable (any APT_PKGS member)" {
    _load_module
    MOCK_APT_UPGRADABLE='xclip/jammy 0.13-3 amd64 [upgradable from: 0.13-2]'
    _mock_apt_list
    run is_outdated
    assert_success
}

@test "is_outdated returns nonzero when neither package is upgradable" {
    _load_module
    MOCK_APT_UPGRADABLE='some-other-pkg/jammy 1.0 amd64 [upgradable from: 0.9]'
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

# ── is_recommended / detect ──────────────────────────────────────────────────

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

@test "detect succeeds when apt-get is available" {
    _load_module
    local _bin="${INIT_UBUNTU_TEST_SCRATCH}/bin"
    mkdir -p "${_bin}"
    printf '#!/bin/sh\nexit 0\n' > "${_bin}/apt-get"
    chmod +x "${_bin}/apt-get"
    PATH="${_bin}:${PATH}" run detect
    assert_success
}

@test "detect fails when apt-get is not on PATH" {
    _load_module
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-path" run detect
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
    assert_output --partial "fish"
    assert_output --partial "ppa-managed"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module nope
    assert_failure 2
}

@test "standalone: info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        fish"
    assert_output --partial "category:    recommended"
    assert_output --partial "curl"
}

@test "standalone: info --lang=zh-TW prints localized description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "個人設定"
}

@test "standalone: status reports installed + outdated fields" {
    run _standalone_module status
    assert_success
    assert_output --partial "installed:"
    assert_output --partial "outdated:"
}

# ── AC-25: implemented phases runnable; optional doctor fails gracefully ─────

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
    local _bin="${INIT_UBUNTU_TEST_SCRATCH}/bin"
    mkdir -p "${_bin}"
    printf '#!/bin/sh\nexit 0\n' > "${_bin}/apt"
    chmod +x "${_bin}/apt"
    PATH="${_bin}:${PATH}" run _standalone_module is-outdated
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: doctor is implemented (default = is_installed; exit != 2)" {
    # doctor is now the archetype default (module_default_doctor): in the test
    # env fish is not installed, so it returns 1 (not the old "exit 2 not
    # implemented").
    run _standalone_module doctor
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

# ── claude-rm customTitle match on fork / resumed sessions (issue #33) ────────
# The claude-rm helper (config payload dropped by this module) resolves a
# customTitle to its session file. Fork / resumed sessions put customTitle on a
# LATER line (line 1 is a leafUuid / permissionMode / file-history snapshot), so
# a first-line-only scan misses them and reports "No session matched" even
# though Tab completion — backed by _claude_sessions.py, which scans the first
# 50 lines — shows the title. The resolver must use the SAME 50-line window as
# the completion helper. Verified via tracked-config-content assertions
# (precedent: codex_spec / yazi_spec / qmk-firmware_spec), since the runtime
# match path depends on python3 (a user-host dependency absent from the
# Docker test-tools image).

_CLAUDE_RM_FN="${MODULE_DIR}/config/fish/functions/claude-rm.fish"
_CLAUDE_SESSIONS_PY="${MODULE_DIR}/config/fish/_claude_sessions.py"

@test "claude-rm ships the customTitle resolver function (issue #33)" {
    [[ -f "${_CLAUDE_RM_FN}" ]]
    grep -Fq 'function claude-rm' "${_CLAUDE_RM_FN}"
}

@test "claude-rm scans the first 50 lines for customTitle, not just line 1 (issue #33)" {
    # The resolver must widen its customTitle scan to the first 50 lines and
    # select the customTitle line explicitly, so fork / resumed sessions whose
    # line 1 is leafUuid / permissionMode / a snapshot are still matched.
    grep -Fq 'head -50 ' "${_CLAUDE_RM_FN}"
    grep -Fq "grep -m1 '\"customTitle\"'" "${_CLAUDE_RM_FN}"
}

@test "claude-rm no longer reads only the first line for customTitle (issue #33 regression)" {
    # Regression guard: the customTitle branch must not pipe a bare
    # `head -1 $f` straight into the JSON parser (the pre-fix behavior).
    run grep -F 'head -1 ' "${_CLAUDE_RM_FN}"
    assert_failure
}

@test "claude-rm customTitle window matches _claude_sessions.py (issue #33)" {
    # The completion helper scans the first 50 lines (`if i > 50: break`);
    # the resolver must stay aligned or completion and resolution disagree —
    # exactly the issue #33 symptom.
    grep -Fq 'i > 50' "${_CLAUDE_SESSIONS_PY}"
}
