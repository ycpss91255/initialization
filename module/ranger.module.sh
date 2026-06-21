#!/usr/bin/env bash
# module/ranger.module.sh — ranger: console file manager + managed rifle.conf
#   [archetype: apt + config-drop hybrid]
#
# Batch C (issue #61, PRD §6.3.3): apt installs the `ranger` package, then a
# super-call chain (archetype-cookbook "Hybrid: chain to the macro's default")
# drops the repo-managed rifle.conf — ranger's file-opener rules — to
# ~/.config/ranger/rifle.conf via the config-drop defaults. is_installed
# requires BOTH the apt package and the marked config, so a deleted
# rifle.conf re-triggers the drop while a user-customized (still-marked)
# file is never clobbered. Sidecar per ADR-0001: written on install/upgrade,
# removed on remove/purge; standalone mode never touches state.json.
#
# Standalone usage:
#   bash module/ranger.module.sh install [--dry-run]
#   bash module/ranger.module.sh upgrade / remove / purge / verify / doctor
#   bash module/ranger.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/ranger.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install ranger

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
NAME="ranger"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("filemgr")
HOMEPAGE="https://github.com/ranger/ranger"
declare -gA DESCRIPTION=(
    [en]="ranger — console file manager with vi key bindings + managed rifle.conf opener rules"
    [zh-TW]="ranger — vi 操作風格的終端機檔案管理器(附託管的 rifle.conf 開檔規則)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Managed rifle.conf dropped at ~/.config/ranger/rifle.conf. Run 'ranger --copy-config=rc' if you also want a local rc.conf."
    [zh-TW]="託管的 rifle.conf 已放到 ~/.config/ranger/rifle.conf。若還需要本地 rc.conf,可執行 'ranger --copy-config=rc'。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl" "container" "vm")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v ranger && ranger --version"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt (lifecycle skeleton) ──────────────────────────────────
APT_PKGS=("ranger")
APT_PPA=""
CONFIG_PATHS=("${HOME}/.config/ranger")
module_use_apt_archetype

# ── Archetype C data — consumed by the module_default_config_* super-calls ──
CONFIG_TEMPLATE_SRC="${MODULE_DIR:-${BASH_SOURCE[0]%/*}}/config/ranger/rifle.conf"
CONFIG_DEST="${HOME}/.config/ranger/rifle.conf"
CONFIG_MARKER="# init_ubuntu managed"
CONFIG_MODE="644"

# Hybrid is_installed: apt package AND marked rifle.conf. A missing config
# re-runs the drop on the next install; a user-edited file that keeps the
# marker counts as installed and is left untouched (config archetype skip).
is_installed() {
    module_default_apt_is_installed && module_default_config_is_installed
}

# Override install/upgrade (super-call pattern, archetype-cookbook §A):
# chain apt default -> config-drop default, then record the version Sidecar
# (ADR-0001; module_sidecar_* helpers are dry-run-safe, the explicit guard
# just skips the pointless dpkg-query).
install() {
    module_default_apt_install || return $?
    module_default_config_install || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    module_sidecar_write "${NAME}" "$(_ranger_pkg_version)"
}

upgrade() {
    module_default_apt_upgrade || return $?
    module_default_config_upgrade || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    module_sidecar_write "${NAME}" "$(_ranger_pkg_version)"
}

# Override remove: apt default removes the package but keeps user config
# (rifle.conf stays, doc/module-spec.md §4.7.4); the Sidecar is state, not
# config, so it goes.
remove() {
    module_default_apt_remove || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    module_sidecar_remove "${NAME}"
}

# Override purge: apt default purges the package AND rm -rf's CONFIG_PATHS
# (~/.config/ranger, rifle.conf included), then drop the Sidecar.
purge() {
    module_default_apt_purge || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    module_sidecar_remove "${NAME}"
}

detect() {
    command -v apt-get >/dev/null 2>&1
}

is_recommended() {
    ! is_installed
}

# doctor: health check — package + config installed, binary runnable,
# Sidecar present (warn-only: may have been installed outside init_ubuntu).
doctor() {
    if ! is_installed; then
        log_warn "[${NAME}] doctor: ranger package or managed rifle.conf missing"
        return 1
    fi
    if ! command -v ranger >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: ranger binary not found on PATH"
        return 1
    fi
    if ! ranger --version >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: ranger --version failed"
        return 1
    fi
    module_sidecar_get_version "${NAME}" >/dev/null 2>&1 \
        || log_warn "[${NAME}] doctor: sidecar missing (installed outside init_ubuntu?)"
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Version string for the Sidecar: dpkg-reported package version, falling
# back to the literal "apt-managed" when dpkg has no answer.
_ranger_pkg_version() {
    local _ver=""
    _ver="$(dpkg-query -W -f='${Version}' ranger 2>/dev/null)" || _ver=""
    printf '%s' "${_ver:-apt-managed}"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
