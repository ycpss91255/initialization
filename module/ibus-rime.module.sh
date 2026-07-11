#!/usr/bin/env bash
# module/ibus-rime.module.sh — Rime input method engine for IBus (apt ibus-rime package)  [archetype: apt]
#
# Part of the small-tools modularization program: each desktop tool is an
# independently installable / removable module. Ubuntu ships the `ibus-rime`
# package, which pulls in the `ibus` framework (binary: `ibus`) plus the Rime
# engine + data. `ibus-rime` itself is a data / engine package with no
# like-named binary, so the runtime probe targets `ibus` and the Rime data
# directory. Desktop-only (SUPPORTED_PLATFORMS): an input method needs a
# graphical session.
#
# Standalone usage:
#   bash module/ibus-rime.module.sh install [--dry-run]
#   bash module/ibus-rime.module.sh upgrade / remove / purge / verify / doctor
#   bash module/ibus-rime.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/ibus-rime.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install ibus-rime

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
NAME="ibus-rime"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("input-method" "desktop")
HOMEPAGE="https://rime.im/"
declare -gA DESCRIPTION=(
    [en]="Rime input method engine for IBus — pulls in the ibus framework (apt ibus-rime package)"
    [zh-TW]="IBus 的 Rime 輸入法引擎,會一併安裝 ibus 框架(apt ibus-rime 套件)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Add Rime as an input source (GNOME Settings > Keyboard) and restart IBus with 'ibus restart'."
    [zh-TW]="於「設定 > 鍵盤」新增 Rime 輸入來源,並執行 'ibus restart' 重新啟動 IBus。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v ibus"

# Rime engine data directory (shipped by ibus-rime / librime-data). Overridable
# so the doctor probe is deterministic under the unit harness.
RIME_DATA_DIR="${RIME_DATA_DIR:-/usr/share/rime-data}"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=("ibus-rime")
APT_PPA=""
CONFIG_PATHS=("${HOME}/.config/ibus/rime")
module_use_apt_archetype

# ── Required hooks (detect + is_recommended stay module-specific) ────────────
detect() {
    command -v apt-get >/dev/null 2>&1
}

# Desktop-only recommendation gate (module-spec.md §4.3.1): an input method
# needs a graphical session, so it is pointless on headless / SBC form factors.
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

# doctor: real runtime health — ibus-rime is a data / engine package (no
# like-named binary), so the probe checks (1) the package is installed, (2) the
# `ibus` framework binary it depends on actually resolves on PATH, and (3) the
# Rime engine data directory exists. Warns (read-only) on Sidecar drift
# (ADR-0001).
doctor() {
    module_dryrun_guard doctor "is_installed + command -v ibus + Rime data dir + Sidecar consistency" \
        && return 0
    is_installed || { log_warn "[${NAME}] doctor: ibus-rime is not installed"; return 1; }
    command -v ibus >/dev/null 2>&1 \
        || { log_warn "[${NAME}] doctor: the ibus framework binary is not runnable on PATH"; return 1; }
    [[ -d "${RIME_DATA_DIR}" ]] \
        || { log_warn "[${NAME}] doctor: Rime engine data dir missing (${RIME_DATA_DIR})"; return 1; }
    if ! module_sidecar_get_version "${NAME}" >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: Sidecar missing (ADR-0001 drift; re-run install/upgrade to heal)"
    fi
    return 0
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
