#!/usr/bin/env bash
# module/gnome-shell-extension-manager.module.sh — Extension Manager — GNOME Shell extension browser / manager (apt gnome-shell-extension-manager package)  [archetype: apt]
#
# Part of the small-tools modularization program: each desktop tool is an
# independently installable / removable module. Ubuntu ships the
# `gnome-shell-extension-manager` package; the binary is `extension-manager`
# (package name != binary name). Desktop-only (SUPPORTED_PLATFORMS): a GNOME
# Shell tool has no meaning on headless / SBC form factors.
#
# Standalone usage:
#   bash module/gnome-shell-extension-manager.module.sh install [--dry-run]
#   bash module/gnome-shell-extension-manager.module.sh upgrade / remove / purge / verify / doctor
#   bash module/gnome-shell-extension-manager.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/gnome-shell-extension-manager.module.sh info / status    (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install gnome-shell-extension-manager

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
NAME="gnome-shell-extension-manager"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("gnome" "desktop")
HOMEPAGE="https://github.com/mjakeman/extension-manager"
declare -gA DESCRIPTION=(
    [en]="Extension Manager — browse and manage GNOME Shell extensions (binary: extension-manager)"
    [zh-TW]="Extension Manager — 瀏覽與管理 GNOME Shell 擴充功能(執行檔:extension-manager)"
)
declare -gA POST_INSTALL_MESSAGE=()
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v extension-manager"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=("gnome-shell-extension-manager")
APT_PPA=""
CONFIG_PATHS=()
module_use_apt_archetype

# ── Required hooks (detect + is_recommended stay module-specific) ────────────
detect() {
    command -v apt-get >/dev/null 2>&1
}

# Desktop-only recommendation gate (module-spec.md §4.3.1): a GNOME Shell tool
# is meaningless on headless / SBC form factors.
is_recommended() {
    case "${INIT_UBUNTU_FORM_FACTOR:-}" in
        desktop)
            ! is_installed
            ;;
        *)
            return 1
            ;;
    esac
}

# doctor: real runtime health — the package must be installed AND its binary
# `extension-manager` must actually resolve on PATH (package name differs from
# the binary, so this catches a partial install). Warns (read-only) on Sidecar
# drift (ADR-0001).
doctor() {
    module_dryrun_guard doctor "is_installed + command -v extension-manager + Sidecar consistency" \
        && return 0
    is_installed || { log_warn "[${NAME}] doctor: gnome-shell-extension-manager is not installed"; return 1; }
    command -v extension-manager >/dev/null 2>&1 \
        || { log_warn "[${NAME}] doctor: installed in dpkg but extension-manager is not on PATH"; return 1; }
    if ! module_sidecar_get_version "${NAME}" >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: Sidecar missing (ADR-0001 drift; re-run install/upgrade to heal)"
    fi
    return 0
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
