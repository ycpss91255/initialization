#!/usr/bin/env bash
# module/bpytop.module.sh — bpytop: resource monitor (pipx-managed)  [archetype: custom]
#
# New module for the small-tools modularization program. bpytop is a Python
# terminal resource monitor (CPU / memory / disk / network / processes). It
# ships on PyPI and its sanctioned install path is pipx (isolated venv + a
# launcher on PATH), so it is a user-scoped tool with no clean apt package and
# no GitHub-release tarball — archetype D (custom).
#
# pipx runs as the invoking user and drops the launcher under ~/.local/bin, so
# every phase is user-home (no sudo). pipx is DEPENDS_ON (foundation program):
# the engine installs the pipx module first, so this module assumes pipx is
# present rather than bootstrapping it inline.
#
# Standalone usage:
#   bash module/bpytop.module.sh install [--dry-run]
#   bash module/bpytop.module.sh upgrade / remove / purge / verify / doctor
#   bash module/bpytop.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/bpytop.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install bpytop

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
NAME="bpytop"
VERSION_PROVIDED="pipx-managed"
CATEGORY="optional"
TAGS=("monitoring" "cli")
HOMEPAGE="https://github.com/aristocratos/bpytop"
declare -gA DESCRIPTION=(
    [en]="bpytop — terminal resource monitor (CPU / memory / disk / network / processes), pipx-managed"
    [zh-TW]="bpytop — 終端機資源監控器(CPU / 記憶體 / 磁碟 / 網路 / 行程),以 pipx 管理"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="bpytop is installed via pipx (~/.local/bin). Ensure ~/.local/bin is on PATH ('pipx ensurepath', then restart your shell)."
    [zh-TW]="bpytop 已透過 pipx 安裝(~/.local/bin)。請確認 ~/.local/bin 在 PATH 中(執行 'pipx ensurepath' 後重開 shell)。"
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
TEST_VERIFY_CMD="command -v bpytop && bpytop --version"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# Version recorded in the Sidecar by the phase-invocation wrapper after a
# successful install/upgrade (overrides the generic VERSION_PROVIDED default).
module_provided_version() { _bpytop_version; }

# ── Archetype D — custom (pipx install, user-level) ─────────────────────────
PIPX_PKG="bpytop"          # PyPI distribution + pipx venv name
BPYTOP_BIN="bpytop"        # launcher shim dropped on PATH

# ── Lifecycle ───────────────────────────────────────────────────────────────

# is_installed: pipx ownership is authoritative (`pipx list --short` prints
# "<pkg> <version>" per venv).
is_installed() {
    _bpytop_pipx_owns
}

# install: pipx install. pipx is a declared dependency (DEPENDS_ON), so the
# engine installs it first — no inline pipx bootstrap here.
install() {
    module_dryrun_guard install "pipx install ${PIPX_PKG}" && return 0
    module_skip_if_installed && return 0
    _bpytop_pipx_install || return $?
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
    _bpytop_pipx_upgrade || return $?
}

# remove: pipx uninstall (leaves user config under ~/.config/bpytop).
remove() {
    module_dryrun_guard remove "pipx uninstall ${PIPX_PKG}" && return 0
    module_skip_if_not_installed && return 0
    _bpytop_pipx_uninstall || return $?
}

# purge: same uninstall path. bpytop keeps no init_ubuntu-managed system
# config; user config under ~/.config/bpytop is user data and is intentionally
# preserved (remove vs purge differ only by that promise).
purge() {
    module_dryrun_guard purge "pipx uninstall ${PIPX_PKG} (user config kept)" && return 0
    if is_installed; then
        _bpytop_pipx_uninstall || return $?
    fi
}

verify() {
    module_default_verify
}

# detect: any apt-based Ubuntu host — pipx is apt-installable and bpytop is
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

# doctor: health check — pipx-managed, then the bpytop binary answers
# --version, then Sidecar presence (warn-only: an out-of-band pipx install has
# no Sidecar).
doctor() {
    if ! is_installed; then
        log_warn "[${NAME}] doctor: bpytop is not pipx-managed"
        return 1
    fi
    local _bin
    _bin="$(command -v "${BPYTOP_BIN}" 2>/dev/null)" || {
        log_warn "[${NAME}] doctor: ${BPYTOP_BIN} not found on PATH (run 'pipx ensurepath')"
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
_bpytop_pipx() {
    pipx "$@"
}

# pipx ownership: `pipx list --short` prints "<pkg> <version>" per venv.
_bpytop_pipx_owns() {
    _bpytop_pipx list --short 2>/dev/null | grep -q "^${PIPX_PKG} "
}

_bpytop_pipx_install() {
    log_info "[${NAME}] pipx install ${PIPX_PKG}"
    _bpytop_pipx install "${PIPX_PKG}" || return 1
}

_bpytop_pipx_upgrade() {
    log_info "[${NAME}] pipx upgrade ${PIPX_PKG}"
    _bpytop_pipx upgrade "${PIPX_PKG}" || return 1
}

_bpytop_pipx_uninstall() {
    log_info "[${NAME}] pipx uninstall ${PIPX_PKG}"
    _bpytop_pipx uninstall "${PIPX_PKG}" || return 1
}

# Version string for the Sidecar: parse `pipx list --short` (one
# "<pkg> <version>" line per venv), falling back to the literal "pipx-managed"
# when pipx has no answer.
_bpytop_version() {
    local _ver=""
    _ver="$(_bpytop_pipx list --short 2>/dev/null \
        | awk -v p="${PIPX_PKG}" '$1==p {print $2; exit}')" || _ver=""
    printf '%s' "${_ver:-pipx-managed}"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
