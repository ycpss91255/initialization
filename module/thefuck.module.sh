#!/usr/bin/env bash
# module/thefuck.module.sh — thefuck: command corrector (pipx-managed)  [archetype: custom]
#
# New module for the small-tools modularization program. thefuck is a Python
# CLI that suggests corrections for the previous mistyped console command. It
# ships on PyPI and its sanctioned install path is pipx (isolated venv + a
# launcher on PATH), so it is a user-scoped tool with no clean apt package and
# no GitHub-release tarball — archetype D (custom).
#
# pipx runs as the invoking user and drops the launcher under ~/.local/bin, so
# every phase is user-home (no sudo). pipx is DEPENDS_ON (foundation program):
# the engine installs the pipx module first, so this module assumes pipx is
# present rather than bootstrapping it inline.
#
# thefuck is only useful after wiring a shell alias (eval "$(thefuck --alias)")
# into the user's shell rc — a manual step surfaced via POST_INSTALL_MESSAGE.
# Because `thefuck --version` needs that alias/shell context to behave, the
# doctor()/verify() probes use `command -v thefuck` (presence on PATH), which is
# the reliable, side-effect-free health signal for this tool.
#
# Standalone usage:
#   bash module/thefuck.module.sh install [--dry-run]
#   bash module/thefuck.module.sh upgrade / remove / purge / verify / doctor
#   bash module/thefuck.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/thefuck.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install thefuck

# ── Dual-mode header ────────────────────────────────────────────────────────
MODULE_STANDALONE="true"
[[ "${BASH_SOURCE[0]:-}" != "${0:-}" ]] && MODULE_STANDALONE="false"
if [[ "${MODULE_STANDALONE}" == "true" ]]; then
    # shellcheck source=../lib/module_bootstrap.sh
    source "${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)}/module_bootstrap.sh"
    module_bootstrap
fi
# Static-analysis hint (never executed: the guard is always false; wrapped in
# kcov-exclude so the dead line is not counted against coverage). module_bootstrap
# sources the lib helpers at runtime, but shellcheck cannot trace that 2-level
# dynamic source — this guarded line lets `shellcheck -x` follow module_helper.sh
# so it sees the metadata + archetype vars below are used externally (avoids SC2034).
# kcov-exclude-start
# shellcheck source=../lib/module_helper.sh
[[ -n "${__module_lint_hint:-}" ]] && source "${LIB_DIR}/module_helper.sh"
# kcov-exclude-end

# ── Metadata (doc/module-spec.md §3) ────────────────────────────────────────
NAME="thefuck"
VERSION_PROVIDED="pipx-managed"
CATEGORY="optional"
TAGS=("shell" "cli")
HOMEPAGE="https://github.com/nvbn/thefuck"
declare -gA DESCRIPTION=(
    [en]="thefuck — corrects your previous mistyped console command, pipx-managed"
    [zh-TW]="thefuck — 修正你上一個打錯的終端機命令,以 pipx 管理"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="thefuck is installed via pipx (~/.local/bin). Ensure ~/.local/bin is on PATH ('pipx ensurepath'), then add the shell alias so it works: put eval \"\$(thefuck --alias)\" in your ~/.bashrc (or ~/.config/fish/config.fish: thefuck --alias | source) and restart your shell."
    [zh-TW]="thefuck 已透過 pipx 安裝(~/.local/bin)。請確認 ~/.local/bin 在 PATH 中(執行 'pipx ensurepath'),再加入 shell alias 才能使用:在 ~/.bashrc 加入 eval \"\$(thefuck --alias)\"(fish 於 ~/.config/fish/config.fish:thefuck --alias | source)後重開 shell。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=("pipx")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=true
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="user-home"
TEST_VERIFY_CMD="command -v thefuck"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# Version recorded in the Sidecar by the phase-invocation wrapper after a
# successful install/upgrade (overrides the generic VERSION_PROVIDED default).
module_provided_version() { _thefuck_version; }

# ── Archetype D — custom (pipx install, user-level) ─────────────────────────
PIPX_PKG="thefuck"          # PyPI distribution + pipx venv name
THEFUCK_BIN="thefuck"       # launcher shim dropped on PATH

# ── Lifecycle ───────────────────────────────────────────────────────────────

# is_installed: pipx ownership is authoritative (`pipx list --short` prints
# "<pkg> <version>" per venv).
is_installed() {
    _thefuck_pipx_owns
}

# install: pipx install. pipx is a declared dependency (DEPENDS_ON), so the
# engine installs it first — no inline pipx bootstrap here.
install() {
    module_dryrun_guard install "pipx install ${PIPX_PKG}" && return 0
    module_skip_if_installed && return 0
    _thefuck_pipx_install || return $?
}

# upgrade: pipx upgrade in place; fall through to install when nothing is
# pipx-managed yet (e.g. first run).
upgrade() {
    module_dryrun_guard upgrade "pipx upgrade ${PIPX_PKG}" && return 0
    if ! is_installed; then
        log_info "[${NAME}] not pipx-managed yet — running install instead"
        install
        return $?
    fi
    _thefuck_pipx_upgrade || return $?
}

# remove: pipx uninstall. The shell alias the user added to their rc is left
# in place (user data); removing it is the user's call.
remove() {
    module_dryrun_guard remove "pipx uninstall ${PIPX_PKG}" && return 0
    module_skip_if_not_installed && return 0
    _thefuck_pipx_uninstall || return $?
}

# purge: same uninstall path. thefuck keeps no init_ubuntu-managed system
# config; the user's rc alias is user data and is intentionally preserved
# (remove vs purge differ only by that promise).
purge() {
    module_dryrun_guard purge "pipx uninstall ${PIPX_PKG} (user shell alias kept)" && return 0
    if is_installed; then
        _thefuck_pipx_uninstall || return $?
    fi
}

verify() {
    module_default_verify
}

# detect: any apt-based Ubuntu host — pipx is apt-installable and thefuck is
# pure-Python (arch-independent).
detect() {
    command -v apt-get >/dev/null 2>&1
}

# is_recommended: yes when not yet installed; the engine still gates it behind
# CATEGORY=optional for Quick Setup.
is_recommended() {
    ! is_installed
}

# is_outdated: pipx exposes no cheap offline "outdated" query, and pipx upgrade
# is idempotent, so this defers to upgrade rather than probing PyPI. Never
# reports known-outdated (returns nonzero); `upgrade` still refreshes to latest.
is_outdated() {
    return 1
}

# doctor: health check — pipx-managed, then the thefuck launcher is on PATH.
# `thefuck --version` needs the shell alias/context to behave, so presence on
# PATH (command -v) is the reliable, side-effect-free probe here. Sidecar
# presence is warn-only (an out-of-band pipx install has no Sidecar).
doctor() {
    if ! is_installed; then
        log_warn "[${NAME}] doctor: thefuck is not pipx-managed"
        return 1
    fi
    if ! command -v "${THEFUCK_BIN}" >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: ${THEFUCK_BIN} not found on PATH (run 'pipx ensurepath')"
        return 1
    fi
    module_sidecar_get_version "${NAME}" >/dev/null 2>&1 \
        || log_warn "[${NAME}] doctor: sidecar missing (installed outside init_ubuntu?)"
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Single pipx-execution seam (user-level, no sudo). Tests shadow this to record
# argv without a real pipx on PATH.
_thefuck_pipx() {
    pipx "$@"
}

# pipx ownership: `pipx list --short` prints "<pkg> <version>" per venv.
_thefuck_pipx_owns() {
    _thefuck_pipx list --short 2>/dev/null | grep -q "^${PIPX_PKG} "
}

_thefuck_pipx_install() {
    log_info "[${NAME}] pipx install ${PIPX_PKG}"
    _thefuck_pipx install "${PIPX_PKG}" || return 1
}

_thefuck_pipx_upgrade() {
    log_info "[${NAME}] pipx upgrade ${PIPX_PKG}"
    _thefuck_pipx upgrade "${PIPX_PKG}" || return 1
}

_thefuck_pipx_uninstall() {
    log_info "[${NAME}] pipx uninstall ${PIPX_PKG}"
    _thefuck_pipx uninstall "${PIPX_PKG}" || return 1
}

# Version string for the Sidecar: parse `pipx list --short` (one
# "<pkg> <version>" line per venv), falling back to the literal "pipx-managed"
# when pipx has no answer.
_thefuck_version() {
    local _ver=""
    _ver="$(_thefuck_pipx list --short 2>/dev/null \
        | awk -v p="${PIPX_PKG}" '$1==p {print $2; exit}')" || _ver=""
    printf '%s' "${_ver:-pipx-managed}"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
