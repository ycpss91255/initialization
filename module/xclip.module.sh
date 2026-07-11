#!/usr/bin/env bash
# module/xclip.module.sh — xclip: X11 clipboard CLI  [archetype: apt]
#
# Pipes stdin to (or dumps) the X11 selection/clipboard from the command line.
# Requires a running X display, hence the desktop-only platform constraint.
# Ubuntu ships the `xclip` package; the binary is `xclip`.
#
# Standalone usage:
#   bash module/xclip.module.sh install [--dry-run]
#   bash module/xclip.module.sh upgrade / remove / purge / verify / doctor
#   bash module/xclip.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/xclip.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install xclip

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
NAME="xclip"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("cli" "clipboard")
HOMEPAGE="https://github.com/astrand/xclip"
declare -gA DESCRIPTION=(
    [en]="xclip — command-line interface to the X11 clipboard/selection"
    [zh-TW]="xclip — X11 剪貼簿／選取的命令列介面"
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
TEST_VERIFY_CMD="command -v xclip"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=("xclip")
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

# doctor: real runtime health check — the xclip binary must be on PATH. xclip
# needs a live X display to actually exchange data, so a presence probe (not a
# --version call that would still touch the display) is the honest check here.
doctor() {
    is_installed || { log_warn "[${NAME}] doctor: not installed"; return 1; }
    command -v xclip >/dev/null 2>&1 || {
        log_warn "[${NAME}] doctor: 'xclip' not on PATH"
        return 1
    }
    return 0
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
