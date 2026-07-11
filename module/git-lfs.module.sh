#!/usr/bin/env bash
# module/git-lfs.module.sh — git-lfs: Git Large File Storage  [archetype: apt]
#
# Git extension that versions large files via pointers + a separate object
# store. Ubuntu ships the `git-lfs` package; the binary is `git-lfs`, invoked
# as `git lfs`. Requires git, and a one-time `git lfs install` to register the
# global smudge/clean filters — done here as an apt post-step.
#
# Standalone usage:
#   bash module/git-lfs.module.sh install [--dry-run]
#   bash module/git-lfs.module.sh upgrade / remove / purge / verify / doctor
#   bash module/git-lfs.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/git-lfs.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install git-lfs

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
NAME="git-lfs"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("git" "vcs")
HOMEPAGE="https://git-lfs.com/"
declare -gA DESCRIPTION=(
    [en]="git-lfs — Git Large File Storage (versions large files via pointers)"
    [zh-TW]="git-lfs — Git 大型檔案儲存(以指標管理大型檔案版本)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="git lfs global filters registered. Run 'git lfs install' inside any existing repo to enable its hooks."
    [zh-TW]="git lfs 全域過濾器已註冊。在既有 repo 內執行 'git lfs install' 即可啟用該 repo 的 hooks。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl" "container" "vm")
DEPENDS_ON=("git")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v git-lfs && git lfs version"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=("git-lfs")
APT_PPA=""
CONFIG_PATHS=()
module_use_apt_archetype

# Override install: archetype installs the apt package, then register the
# global git-lfs filters (the one-time `git lfs install` post-step).
install() {
    module_default_apt_install || return $?
    module_dryrun_guard install "git lfs install --skip-repo" && return 0
    _git_lfs_register_filters
}

# ── Required hooks (detect + is_recommended stay module-specific) ────────────
detect() {
    command -v apt-get >/dev/null 2>&1
}

is_recommended() {
    ! is_installed
}

# doctor: real runtime health check — `git lfs version` must succeed.
doctor() {
    is_installed || { log_warn "[${NAME}] doctor: not installed"; return 1; }
    git lfs version >/dev/null 2>&1 || {
        log_warn "[${NAME}] doctor: 'git lfs version' failed"
        return 1
    }
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────
# Register the global smudge/clean filters. `--skip-repo` sets up ~/.gitconfig
# without touching (or requiring) a current repo, so it is safe + idempotent.
_git_lfs_register_filters() {
    command -v git >/dev/null 2>&1 || {
        log_warn "[${NAME}] git not on PATH; run 'git lfs install' after installing git"
        return 0
    }
    if git lfs install --skip-repo >/dev/null 2>&1; then
        log_info "[${NAME}] git lfs global filters registered"
    else
        log_warn "[${NAME}] 'git lfs install' failed; run it manually"
    fi
    return 0
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
