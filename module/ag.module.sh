#!/usr/bin/env bash
# module/ag.module.sh — ag (the_silver_searcher): fast code search  [archetype: apt]
#
# Recursively searches directories for a regex pattern, much faster than a
# naive grep on large trees. Ubuntu ships the `silversearcher-ag` package; the
# binary is `ag`.
#
# Standalone usage:
#   bash module/ag.module.sh install [--dry-run]
#   bash module/ag.module.sh upgrade / remove / purge / verify / doctor
#   bash module/ag.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/ag.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install ag

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
NAME="ag"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("cli" "search")
HOMEPAGE="https://github.com/ggreer/the_silver_searcher"
declare -gA DESCRIPTION=(
    [en]="ag — the_silver_searcher: fast recursive code/text search (grep alternative)"
    [zh-TW]="ag — the_silver_searcher:快速遞迴程式碼／文字搜尋(grep 替代)"
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
TEST_VERIFY_CMD="command -v ag && ag --version | head -n1"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=("silversearcher-ag")
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

# doctor: real runtime health check — the ag binary must answer --version.
doctor() {
    is_installed || { log_warn "[${NAME}] doctor: not installed"; return 1; }
    ag --version >/dev/null 2>&1 || {
        log_warn "[${NAME}] doctor: 'ag --version' failed"
        return 1
    }
    return 0
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
