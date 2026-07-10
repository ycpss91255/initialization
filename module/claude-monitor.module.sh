#!/usr/bin/env bash
# module/claude-monitor.module.sh — Claude Code usage monitor (pipx)  [archetype: custom]
#
# New module per issue #315 / TODO.md ("ADD items" -> claude code ->
# claude-monitor). `claude-monitor` is a Python TUI that tracks Claude
# Code token/cost usage against plan limits. It ships on PyPI and its
# sanctioned install path is pipx (isolated venv + a shim on PATH), so it
# is a user-scoped tool with no apt package and no GitHub-release tarball —
# archetype D (custom, doc/guide/archetype-cookbook.md §D).
#
# pipx runs as the invoking user and drops the launcher under
# ~/.local/bin, so every phase is user-home (no sudo). The only privileged
# step is bootstrapping pipx itself when it is absent (apt-get install
# pipx), mirroring jetson-stats' pipx fallback.
#
# Standalone usage:
#   bash module/claude-monitor.module.sh install [--dry-run]
#   bash module/claude-monitor.module.sh upgrade / remove / purge / verify
#   bash module/claude-monitor.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/claude-monitor.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install claude-monitor

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
NAME="claude-monitor"
VERSION_PROVIDED="pipx-managed"
CATEGORY="optional"
TAGS=("agent" "cli")
HOMEPAGE="https://pypi.org/project/claude-monitor/"
declare -gA DESCRIPTION=(
    [en]="claude-monitor — real-time Claude Code token/cost usage monitor TUI (pipx)"
    [zh-TW]="claude-monitor — 即時 Claude Code token/費用使用量監控 TUI(pipx)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Run 'claude-monitor' to launch the usage TUI. Ensure ~/.local/bin is on your PATH (the pipx shim lives there)."
    [zh-TW]="執行 'claude-monitor' 啟動使用量 TUI。請確認 ~/.local/bin 在 PATH 內(pipx shim 位於該處)。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=true
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="user-home"
TEST_VERIFY_CMD="command -v claude-monitor && claude-monitor --version"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# Version recorded in the Sidecar by the phase-invocation wrapper after a
# successful install/upgrade (overrides the generic VERSION_PROVIDED default).
module_provided_version() { _claude_monitor_version; }

# ── Archetype D data ────────────────────────────────────────────────────────
PIPX_PKG="claude-monitor"          # PyPI distribution + pipx venv name
CLAUDE_MONITOR_BIN="claude-monitor" # launcher shim dropped on PATH
CONFIG_PATHS=(                      # user config, purge-only
    "${XDG_CONFIG_HOME:-${HOME}/.config}/claude-monitor"
)

# ── Lifecycle ───────────────────────────────────────────────────────────────

# is_installed: the shim on PATH is authoritative; fall back to the pipx
# venv listing (covers a stale/ unlinked shim after a PATH change).
is_installed() {
    command -v "${CLAUDE_MONITOR_BIN}" >/dev/null 2>&1 && return 0
    _claude_monitor_pipx list 2>/dev/null | grep -q "${PIPX_PKG}"
}

# detect: pure-Python pipx tool — no arch/hardware constraint.
detect() {
    return 0
}

is_recommended() {
    ! is_installed
}

install() {
    module_dryrun_guard install \
        "pipx install ${PIPX_PKG} (bootstraps pipx via apt if absent)" \
        && return 0
    module_skip_if_installed && return 0
    _claude_monitor_pkg_install || return $?
}

# upgrade: pipx-managed venv upgrade. Falls through to install when nothing
# is installed yet.
upgrade() {
    module_dryrun_guard upgrade "pipx upgrade ${PIPX_PKG}" \
        && return 0
    if ! is_installed; then
        log_info "[${NAME}] not installed yet — running install instead"
        install
        return $?
    fi
    _claude_monitor_pipx upgrade "${PIPX_PKG}" || {
        log_error "[${NAME}] 'pipx upgrade ${PIPX_PKG}' failed"
        return 1
    }
}

# remove: drop the pipx venv + shim, keep user config (purge-only).
remove() {
    module_dryrun_guard remove "pipx uninstall ${PIPX_PKG}" \
        && return 0
    module_skip_if_not_installed && return 0
    _claude_monitor_pipx uninstall "${PIPX_PKG}" || {
        log_error "[${NAME}] 'pipx uninstall ${PIPX_PKG}' failed"
        return 1
    }
}

purge() {
    module_dryrun_guard purge \
        "pipx uninstall ${PIPX_PKG} + rm ${CONFIG_PATHS[*]}" \
        && return 0
    if is_installed; then
        _claude_monitor_pipx uninstall "${PIPX_PKG}" || {
            log_error "[${NAME}] 'pipx uninstall ${PIPX_PKG}' failed"
            return 1
        }
    fi
    local _p
    for _p in "${CONFIG_PATHS[@]}"; do
        rm -rf "${_p}"
    done
}

verify() {
    module_default_verify
}

# is_outdated: query the package's own pip inside the pipx venv. Degrades
# gracefully when pipx is missing (empty output means "not outdated").
is_outdated() {
    _claude_monitor_pipx runpip "${PIPX_PKG}" list --outdated 2>/dev/null \
        | grep -q "^${PIPX_PKG} "
}

# doctor: health check — installed, launcher answers --version, sidecar
# consistent (warn-only: a missing sidecar = installed outside init_ubuntu).
doctor() {
    if ! is_installed; then
        log_warn "[${NAME}] doctor: claude-monitor is not installed"
        return 1
    fi
    local _bin
    _bin="$(command -v "${CLAUDE_MONITOR_BIN}" 2>/dev/null)" || {
        log_warn "[${NAME}] doctor: ${CLAUDE_MONITOR_BIN} not found on PATH — is ~/.local/bin on PATH?"
        return 1
    }
    if ! "${_bin}" --version >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: ${_bin} --version failed"
        return 1
    fi
    module_sidecar_get_version "${NAME}" >/dev/null 2>&1 \
        || log_warn "[${NAME}] doctor: sidecar missing (installed outside init_ubuntu?)"
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Single pipx-execution seam. Tests intercept it by shadowing `pipx`;
# routing every pipx call through one indirection keeps the mock surface
# small and lets is_installed / is_outdated share it.
_claude_monitor_pipx() {
    pipx "$@"
}

# Ensure pipx is available. pipx itself is a system prerequisite; when it is
# absent bootstrap it via apt (the one privileged step). Overridable seam:
# tests shadow `sudo` / `apt-get` and stub `command`.
_claude_monitor_ensure_pipx() {
    command -v pipx >/dev/null 2>&1 && return 0
    log_info "[${NAME}] pipx not found — installing via apt"
    have_sudo_access 2>/dev/null \
        || { log_error "[${NAME}] pipx is missing and sudo is unavailable to install it"; return 1; }
    sudo apt-get install -y pipx \
        || { log_error "[${NAME}] failed to install pipx via apt"; return 1; }
}

_claude_monitor_pkg_install() {
    _claude_monitor_ensure_pipx || return $?
    log_info "[${NAME}] pipx install ${PIPX_PKG}"
    _claude_monitor_pipx install "${PIPX_PKG}" || {
        log_error "[${NAME}] 'pipx install ${PIPX_PKG}' failed"
        return 1
    }
}

# Version string for the Sidecar: parse `pipx list --short` (one
# "<pkg> <version>" line per venv), falling back to the literal
# "pipx-managed" when pipx has no answer.
_claude_monitor_version() {
    local _ver=""
    _ver="$(_claude_monitor_pipx list --short 2>/dev/null \
        | awk -v p="${PIPX_PKG}" '$1==p {print $2; exit}')" || _ver=""
    printf '%s' "${_ver:-pipx-managed}"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
