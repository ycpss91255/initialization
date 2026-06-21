#!/usr/bin/env bash
# module/fdfind.module.sh — fd (fdfind): fast find alternative  [archetype: apt]
#
# Migrated from module/submodule/fdfind.sh (v1 GitHub tarball install) to the
# v2 contract (doc/module-spec.md) on the apt archetype: Ubuntu ships fd as
# the `fd-find` package whose binary is `fdfind` (the `fd` name is taken by
# another package). Also a neovim dependency (telescope file finding).
#
# Standalone usage:
#   bash module/fdfind.module.sh install [--dry-run]
#   bash module/fdfind.module.sh upgrade / remove / purge / verify
#   bash module/fdfind.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/fdfind.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install fdfind

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
NAME="fdfind"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("cli-essentials")
HOMEPAGE="https://github.com/sharkdp/fd"
declare -gA DESCRIPTION=(
    [en]="fd (fdfind) — fast, user-friendly alternative to find (apt fd-find)"
    [zh-TW]="fd(fdfind)— 快速好用的 find 替代工具(apt fd-find 套件)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Ubuntu names the binary 'fdfind' ('fd' is taken by another package). Add 'alias fd=fdfind' to your shell rc for the short name."
    [zh-TW]="Ubuntu 將執行檔命名為 'fdfind'('fd' 已被其他套件占用)。想用短名稱可在 shell rc 加上 'alias fd=fdfind'。"
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
TEST_VERIFY_CMD="command -v fdfind && fdfind --version"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=("fd-find")
APT_PPA=""
CONFIG_PATHS=("${HOME}/.config/fd")
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
