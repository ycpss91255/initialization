#!/usr/bin/env bash
# module/tmuxp.module.sh — tmuxp: tmux session manager (pipx-managed)  [archetype: custom]
#
# New module per issue #313: tmuxp used to ride along as an apt package in the
# legacy module/setup_small_tools.sh flow (apt `tmuxp` + `python3-libtmux`).
# apt lags well behind upstream, so this module moves tmuxp to a pipx-managed
# install for a newer release and clean venv isolation. Custom archetype:
# user-level `pipx install tmuxp` (no sudo for the tool itself); install() also
# migrates a pre-existing apt tmuxp away (`sudo apt-get remove tmuxp
# python3-libtmux`) when apt owns it and sudo is available, so the two never
# fight over the `tmuxp` name on PATH.
#
# Standalone usage:
#   bash module/tmuxp.module.sh install [--dry-run]
#   bash module/tmuxp.module.sh upgrade / remove / purge / verify
#   bash module/tmuxp.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/tmuxp.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install tmuxp

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
NAME="tmuxp"
VERSION_PROVIDED="pipx-managed"
CATEGORY="optional"
TAGS=("terminal" "session")
HOMEPAGE="https://github.com/tmux-python/tmuxp"
declare -gA DESCRIPTION=(
    [en]="tmuxp — tmux session manager (freeze/restore sessions from YAML), pipx-managed"
    [zh-TW]="tmuxp — tmux session 管理器(從 YAML 凍結/還原 session),以 pipx 管理"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="tmuxp is installed via pipx (~/.local/bin). Ensure ~/.local/bin is on PATH ('pipx ensurepath', then restart your shell)."
    [zh-TW]="tmuxp 已透過 pipx 安裝(~/.local/bin)。請確認 ~/.local/bin 在 PATH 中(執行 'pipx ensurepath' 後重開 shell)。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=("tmux")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=true
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="user-home"
TEST_VERIFY_CMD="command -v tmuxp && tmuxp --version"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# Version recorded in the Sidecar by the phase-invocation wrapper after a
# successful install/upgrade (overrides the generic VERSION_PROVIDED default).
module_provided_version() { _tmuxp_version; }

# ── Archetype D — custom (pipx install, user-level) ─────────────────────────
PIPX_PKG="tmuxp"
# apt package names the migration path removes when it detects an apt-owned
# tmuxp (issue #313: "apt remove tmuxp python3-libtmux").
APT_LEGACY_PKGS=("tmuxp" "python3-libtmux")

# is_installed: pipx ownership is authoritative. A tmuxp that apt still owns
# is deliberately NOT counted here so install() proceeds and migrates it.
is_installed() {
    _tmuxp_pipx_owns
}

# install: migrate an apt-owned tmuxp away, ensure pipx, then pipx install.
install() {
    module_dryrun_guard install \
        "apt remove ${APT_LEGACY_PKGS[*]} (if apt-owned) -> pipx install ${PIPX_PKG}" \
        && return 0
    module_skip_if_installed && return 0
    _tmuxp_migrate_apt
    _tmuxp_ensure_pipx || return $?
    _tmuxp_pipx_install || return $?
}

# upgrade: pipx upgrade in place; fall through to install when nothing is
# pipx-managed yet (e.g. first run, or still apt-owned).
upgrade() {
    module_dryrun_guard upgrade "pipx upgrade ${PIPX_PKG}" && return 0
    if ! is_installed; then
        log_info "[${NAME}] not pipx-managed yet — running install instead"
        install
        return $?
    fi
    _tmuxp_pipx_upgrade || return $?
}

# remove: pipx uninstall (leaves user session YAMLs under ~/.config/tmuxp).
remove() {
    module_dryrun_guard remove "pipx uninstall ${PIPX_PKG}" && return 0
    module_skip_if_not_installed && return 0
    _tmuxp_pipx_uninstall || return $?
}

# purge: same uninstall path. tmuxp keeps no init_ubuntu-managed system config;
# user session templates under ~/.config/tmuxp and ~/.tmuxp are user data and
# are intentionally preserved (remove vs purge differ only by that promise).
purge() {
    module_dryrun_guard purge "pipx uninstall ${PIPX_PKG} (user session YAMLs kept)" && return 0
    if is_installed; then
        _tmuxp_pipx_uninstall || return $?
    fi
}

verify() {
    module_default_verify
}

# detect: any apt-based Ubuntu host — pipx is apt-installable and tmuxp is
# pure-Python (arch-independent).
detect() {
    command -v apt-get >/dev/null 2>&1
}

# is_recommended: yes when not yet installed (optional tmux companion); the
# engine still gates it behind CATEGORY=optional for Quick Setup.
is_recommended() {
    ! is_installed
}

# is_outdated: pipx exposes no cheap offline "outdated" query, and pipx upgrade
# is idempotent, so this defers to upgrade rather than probing PyPI. Never
# reports known-outdated (returns nonzero); `upgrade` still refreshes to latest.
is_outdated() {
    return 1
}

# doctor: health check — pipx-managed, then the tmuxp binary answers --version,
# then Sidecar presence (warn-only: an out-of-band pipx install has no Sidecar).
doctor() {
    if ! is_installed; then
        log_warn "[${NAME}] doctor: tmuxp is not pipx-managed"
        return 1
    fi
    local _bin
    _bin="$(command -v tmuxp 2>/dev/null)" || {
        log_warn "[${NAME}] doctor: tmuxp binary not found on PATH (run 'pipx ensurepath')"
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

# Single pipx-execution seam (user-level, no sudo). Tests shadow this to record
# argv without a real pipx on PATH.
_tmuxp_pipx() {
    pipx "$@"
}

# Privileged seam for the apt migration only. Routing `sudo apt-get` through one
# indirection keeps shellcheck from pairing a literal `sudo` with the spec's
# mock (SC2032 — functions cannot cross the sudo boundary anyway).
_tmuxp_sudo() {
    sudo "$@"
}

# pipx ownership: `pipx list --short` prints "<pkg> <version>" per venv.
_tmuxp_pipx_owns() {
    _tmuxp_pipx list --short 2>/dev/null | grep -q "^${PIPX_PKG} "
}

# Migrate a pre-existing apt tmuxp to pipx: only fires when dpkg reports the
# package installed AND sudo is available. Best-effort — a failed apt remove
# warns and continues (pipx install still supersedes it on PATH).
_tmuxp_migrate_apt() {
    command -v dpkg-query >/dev/null 2>&1 || return 0
    dpkg-query -W -f='${Status}' "${PIPX_PKG}" 2>/dev/null \
        | grep -q 'install ok installed' || return 0
    if ! have_sudo_access 2>/dev/null; then
        log_warn "[${NAME}] apt-managed tmuxp detected but no sudo — leaving it; pipx install will shadow it on PATH"
        return 0
    fi
    log_info "[${NAME}] migrating: sudo apt-get remove -y ${APT_LEGACY_PKGS[*]}"
    _tmuxp_sudo apt-get remove -y "${APT_LEGACY_PKGS[@]}" \
        || log_warn "[${NAME}] apt removal failed (continuing to pipx install)"
}

# Ensure pipx exists; apt-install it (sudo) when missing.
_tmuxp_ensure_pipx() {
    command -v pipx >/dev/null 2>&1 && return 0
    if ! have_sudo_access 2>/dev/null; then
        log_error "[${NAME}] pipx not found and no sudo to install it"
        return 1
    fi
    log_info "[${NAME}] installing pipx via apt"
    _tmuxp_sudo apt-get install -y pipx \
        || { log_error "[${NAME}] failed to install pipx"; return 1; }
}

_tmuxp_pipx_install() {
    log_info "[${NAME}] pipx install ${PIPX_PKG}"
    _tmuxp_pipx install "${PIPX_PKG}" || return 1
}

_tmuxp_pipx_upgrade() {
    log_info "[${NAME}] pipx upgrade ${PIPX_PKG}"
    _tmuxp_pipx upgrade "${PIPX_PKG}" || return 1
}

_tmuxp_pipx_uninstall() {
    log_info "[${NAME}] pipx uninstall ${PIPX_PKG}"
    _tmuxp_pipx uninstall "${PIPX_PKG}" || return 1
}

# Version string for the Sidecar: parsed from `tmuxp --version`
# ("tmuxp X.Y.Z, libtmux ...") -> X.Y.Z, falling back to "pipx-managed".
_tmuxp_version() {
    local _ver=""
    _ver="$(tmuxp --version 2>/dev/null | awk '{print $2}' | tr -d ',')" \
        || _ver=""
    printf '%s' "${_ver:-pipx-managed}"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
