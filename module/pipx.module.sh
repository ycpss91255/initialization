#!/usr/bin/env bash
# module/pipx.module.sh — pipx: isolated Python-app installer (apt)  [archetype: apt]
#
# Foundation module for the small-tools modularization program. pipx installs
# Python CLI apps into isolated virtualenvs and drops a launcher on PATH; it is
# the sanctioned install path for user-scoped Python tools (tmuxp,
# claude-monitor, the qmk CLI, ...). Those higher-level modules DEPEND ON this
# one, so the engine installs pipx first and they can assume it is present
# instead of each bootstrapping it inline. pipx itself is apt-managed
# (`apt-get install pipx`), with the standard `pipx ensurepath` follow-up so
# ~/.local/bin lands on PATH. DEPENDS_ON=("python3") — pipx needs the Python 3
# runtime the python3 module provides.
#
# Standalone usage:
#   bash module/pipx.module.sh install [--dry-run]
#   bash module/pipx.module.sh upgrade / remove / purge / verify / doctor
#   bash module/pipx.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/pipx.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install pipx

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
NAME="pipx"
VERSION_PROVIDED="apt-managed"
CATEGORY="base"
TAGS=("python" "cli")
HOMEPAGE="https://pipx.pypa.io/"
declare -gA DESCRIPTION=(
    [en]="pipx — install and run Python CLI apps in isolated virtualenvs (apt-managed)"
    [zh-TW]="pipx — 於隔離的虛擬環境安裝並執行 Python CLI 應用(以 apt 管理)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="pipx drops app launchers under ~/.local/bin. If pipx-installed tools are not on PATH, run 'pipx ensurepath' and restart your shell."
    [zh-TW]="pipx 會將應用啟動器放在 ~/.local/bin。若 pipx 安裝的工具不在 PATH 中,請執行 'pipx ensurepath' 後重開 shell。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl" "container" "vm")
DEPENDS_ON=("python3")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v pipx && pipx --version"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=("pipx")
APT_PPA=""
CONFIG_PATHS=()
module_use_apt_archetype

# ── Super-call overrides ─────────────────────────────────────────────────────
# The apt archetype installs the pipx package; on top of that we run the
# standard `pipx ensurepath` so ~/.local/bin is wired onto PATH for future
# pipx-installed tools. upgrade re-runs it too (idempotent).
install() {
    module_default_apt_install || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    _pipx_ensurepath
}

upgrade() {
    module_default_apt_upgrade || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    _pipx_ensurepath
}

# ── Required hooks (detect + is_recommended stay module-specific) ────────────
detect() {
    command -v apt-get >/dev/null 2>&1
}

is_recommended() {
    ! is_installed
}

# doctor: dpkg state alone is not health — pipx must actually run. Verify the
# binary answers `pipx --version` after confirming it is installed.
doctor() {
    if ! is_installed; then
        log_warn "[${NAME}] doctor: pipx is not installed"
        return 1
    fi
    if ! pipx --version >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: pipx is present but 'pipx --version' failed"
        return 1
    fi
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Single pipx-execution seam (user-level, no sudo). Tests shadow this to record
# argv without a real pipx on PATH.
_pipx() {
    pipx "$@"
}

# Run `pipx ensurepath` best-effort: wire ~/.local/bin onto PATH. A missing
# pipx (e.g. apt install skipped in a constrained env) or a failed ensurepath
# warns and continues — install() has already succeeded by this point.
_pipx_ensurepath() {
    command -v pipx >/dev/null 2>&1 || return 0
    log_info "[${NAME}] pipx ensurepath"
    _pipx ensurepath >/dev/null 2>&1 \
        || log_warn "[${NAME}] 'pipx ensurepath' failed (continuing)"
    return 0
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
