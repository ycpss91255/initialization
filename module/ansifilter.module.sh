#!/usr/bin/env bash
# module/ansifilter.module.sh — ansifilter: ANSI code filter  [archetype: apt]
#
# Strips or converts ANSI terminal escape codes (colours, cursor moves) into
# plain text or markup (HTML, LaTeX, RTF, ...). Ubuntu ships the `ansifilter`
# package; the binary is `ansifilter`.
#
# Standalone usage:
#   bash module/ansifilter.module.sh install [--dry-run]
#   bash module/ansifilter.module.sh upgrade / remove / purge / verify / doctor
#   bash module/ansifilter.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/ansifilter.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install ansifilter

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
NAME="ansifilter"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("cli" "text")
HOMEPAGE="https://gitlab.com/saalen/ansifilter"
declare -gA DESCRIPTION=(
    [en]="ansifilter — strip or convert ANSI terminal escape codes to text/markup"
    [zh-TW]="ansifilter — 移除或轉換 ANSI 終端跳脫碼為純文字／標記"
)
declare -gA POST_INSTALL_MESSAGE=()
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl" "container" "vm")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v ansifilter && ansifilter --version | head -n1"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=("ansifilter")
APT_PPA=""
CONFIG_PATHS=()
module_use_apt_archetype

# ── Required hooks (detect + is_recommended stay module-specific) ────────────
detect() {
    command -v apt-get >/dev/null 2>&1
}

is_recommended() {
    ! is_installed
}

# doctor: real runtime health check — the ansifilter binary must answer --version.
doctor() {
    is_installed || { log_warn "[${NAME}] doctor: not installed"; return 1; }
    ansifilter --version >/dev/null 2>&1 || {
        log_warn "[${NAME}] doctor: 'ansifilter --version' failed"
        return 1
    }
    return 0
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
