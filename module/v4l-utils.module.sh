#!/usr/bin/env bash
# module/v4l-utils.module.sh — v4l-utils — Video4Linux capture / control tools (apt v4l-utils package)  [archetype: apt]
#
# Part of the small-tools modularization program: each desktop tool is an
# independently installable / removable module. Ubuntu ships the `v4l-utils`
# package; the primary binary is `v4l2-ctl` (package name != binary name).
# Desktop-only (SUPPORTED_PLATFORMS): camera / capture tooling for a graphical
# workstation.
#
# Standalone usage:
#   bash module/v4l-utils.module.sh install [--dry-run]
#   bash module/v4l-utils.module.sh upgrade / remove / purge / verify / doctor
#   bash module/v4l-utils.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/v4l-utils.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install v4l-utils

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
NAME="v4l-utils"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("media" "hardware")
HOMEPAGE="https://linuxtv.org/wiki/index.php/V4l-utils"
declare -gA DESCRIPTION=(
    [en]="v4l-utils — Video4Linux tools to inspect and control cameras (binary: v4l2-ctl)"
    [zh-TW]="v4l-utils — Video4Linux 工具組,用於檢視與控制攝影機(執行檔:v4l2-ctl)"
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
TEST_VERIFY_CMD="command -v v4l2-ctl"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=("v4l-utils")
APT_PPA=""
CONFIG_PATHS=()
module_use_apt_archetype

# ── Required hooks (detect + is_recommended stay module-specific) ────────────
detect() {
    command -v apt-get >/dev/null 2>&1
}

# Desktop-only recommendation gate (module-spec.md §4.3.1): camera / capture
# tooling targets a graphical workstation, not headless / SBC form factors.
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

# doctor: real runtime health — the package must be installed AND its primary
# binary `v4l2-ctl` must actually resolve on PATH (package name differs from the
# binary, so this catches a partial install). Warns (read-only) on Sidecar
# drift (ADR-0001).
doctor() {
    module_dryrun_guard doctor "is_installed + command -v v4l2-ctl + Sidecar consistency" \
        && return 0
    is_installed || { log_warn "[${NAME}] doctor: v4l-utils is not installed"; return 1; }
    command -v v4l2-ctl >/dev/null 2>&1 \
        || { log_warn "[${NAME}] doctor: v4l-utils is present in dpkg but v4l2-ctl is not on PATH"; return 1; }
    if ! module_sidecar_get_version "${NAME}" >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: Sidecar missing (ADR-0001 drift; re-run install/upgrade to heal)"
    fi
    return 0
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
