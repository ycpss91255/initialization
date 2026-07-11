#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata vars (NAME / DESCRIPTION / CATEGORY / TAGS / ...) consumed by engine post-source — https://www.shellcheck.net/wiki/SC2034
# module/git-config.module.sh — personal ~/.gitconfig drop

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

# ── Metadata ────────────────────────────────────────────────────────────────
NAME="git-config"
VERSION_PROVIDED="1.0"
CATEGORY="recommended"
TAGS=("config" "git" "dotfile")
HOMEPAGE=""
declare -gA DESCRIPTION=(
    [en]="Personal ~/.gitconfig (aliases, delta diff, rebase pull, ...)"
    [zh-TW]="個人 ~/.gitconfig 設定(alias / delta diff / rebase pull...)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Edit ~/.gitconfig and set [user] name + email before committing."
    [zh-TW]="首次使用前請編輯 ~/.gitconfig 加入 [user] 的 name 與 email。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl" "container" "vm")
DEPENDS_ON=("git")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=true
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="user-home"
TEST_VERIFY_CMD="git config --global --list >/dev/null"

# ── Archetype C — config drop ────────────────────────────────────────────────
# Issue #278 assessment: the tracked template module/config/git_config carries
# NO personal data — it is a generic dotfile (defaultBranch, editor/pager,
# delta + alias defaults) with no [user] name/email, no hosts, no credentials.
# So it does NOT get the ssh-config treatment (untrack + gitignore + placeholder)
# and keeps the shared repo-wins archetype semantics unchanged, deliberately
# scoping the #278 fix to ssh-config so git-config's behavior is not altered
# incidentally. If a [user] block or any secret is ever added here, revisit.
CONFIG_TEMPLATE_SRC="${MODULE_DIR:-${BASH_SOURCE[0]%/*}}/config/git_config"
CONFIG_DEST="${HOME}/.gitconfig"
CONFIG_MARKER="# init_ubuntu managed"
CONFIG_MODE="644"
module_use_config_archetype

# ── Required hooks ───────────────────────────────────────────────────────────
detect() {
    command -v git >/dev/null 2>&1
}
is_recommended() {
    ! is_installed
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
