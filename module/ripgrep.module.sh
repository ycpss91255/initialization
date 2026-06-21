#!/usr/bin/env bash
# module/ripgrep.module.sh — ripgrep (rg): fast grep alternative  [archetype: apt]
#
# New module (PRD §6.3.1, Q41): referenced by the neovim dep chain
# (telescope live-grep) but previously missing from the catalog. Ubuntu
# ships the `ripgrep` package in universe; the binary is `rg`.
#
# Standalone usage:
#   bash module/ripgrep.module.sh install [--dry-run]
#   bash module/ripgrep.module.sh upgrade / remove / purge / verify
#   bash module/ripgrep.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/ripgrep.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install ripgrep

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
NAME="ripgrep"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("cli-essentials")
HOMEPAGE="https://github.com/BurntSushi/ripgrep"
declare -gA DESCRIPTION=(
    [en]="ripgrep (rg) — fast, recursive grep alternative (apt ripgrep package)"
    [zh-TW]="ripgrep(rg)— 快速的遞迴 grep 替代工具(apt ripgrep 套件)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="The binary is 'rg'. Optional config: set RIPGREP_CONFIG_PATH to a ripgreprc file."
    [zh-TW]="執行檔名為 'rg'。選用設定:將 RIPGREP_CONFIG_PATH 指向 ripgreprc 檔案。"
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
TEST_VERIFY_CMD="command -v rg && rg --version"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=("ripgrep")
APT_PPA=""
CONFIG_PATHS=("${HOME}/.config/ripgrep")
module_use_apt_archetype

# ── Required hooks (detect + is_recommended stay module-specific) ────────────
detect() {
    command -v apt-get >/dev/null 2>&1
}

is_recommended() {
    ! is_installed
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
