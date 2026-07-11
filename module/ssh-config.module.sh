#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata vars (NAME / DESCRIPTION / CATEGORY / TAGS / ...) consumed by engine post-source — https://www.shellcheck.net/wiki/SC2034
# module/ssh-config.module.sh — personal ~/.ssh/config drop

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
NAME="ssh-config"
VERSION_PROVIDED="1.0"
CATEGORY="optional"
TAGS=("config" "ssh" "dotfile")
HOMEPAGE=""
declare -gA DESCRIPTION=(
    [en]="Personal ~/.ssh/config templates (per-host alias and key map)"
    [zh-TW]="個人 ~/.ssh/config(各 host alias 與金鑰對應)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Place private keys under ~/.ssh/ and verify file modes are 600."
    [zh-TW]="請將私鑰放入 ~/.ssh/ 並確認檔案權限為 600。"
)
declare -gA WARN_MESSAGE=(
    [en]="An existing ~/.ssh/config is treated as authoritative and left untouched; the stub is dropped only when none exists."
    [zh-TW]="既有 ~/.ssh/config 視為權威來源、不會被覆寫;僅在不存在時才寫入範本。"
)
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl" "container" "vm")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=true
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="user-home"
TEST_VERIFY_CMD="[ -r \"${HOME}/.ssh/config\" ]"

# ── Archetype C — config drop ────────────────────────────────────────────────
# Ships ONLY a safe placeholder stub (no real host data). The live
# ~/.ssh/config is host/person-specific and version-controlled nowhere — the
# real per-machine file used to be tracked in this public repo and leaked IPs,
# usernames, and a credential (issue #278). CONFIG_TEMPLATE_SRC points at the
# tracked stub; the real file stays gitignored.
CONFIG_TEMPLATE_SRC="${MODULE_DIR:-${BASH_SOURCE[0]%/*}}/config/ssh_config.template"
CONFIG_DEST="${HOME}/.ssh/config"
CONFIG_MARKER="# init_ubuntu managed"
CONFIG_MODE="600"
CONFIG_DIR_MODE="700"
module_use_config_archetype

# ── Non-clobbering overrides (issue #278) ────────────────────────────────────
# Flip the sync direction for ~/.ssh/config: the local file is authoritative.
# It accumulates real per-host entries over a machine's life, so neither
# install() nor upgrade() may overwrite an existing one. Both bootstrap the
# safe stub ONLY when ~/.ssh/config is absent (fresh machine); otherwise they
# are a no-op and local edits always survive. This overrides the generic
# archetype's repo-wins-on-upgrade semantics without touching lib/module_helper.sh
# (so git-config's behavior is unchanged).
install() {
    : "${CONFIG_DEST:?[${NAME}] CONFIG_DEST required}"
    module_dryrun_guard install "bootstrap ${CONFIG_DEST} (only if absent)" && return 0
    if [[ -e "${CONFIG_DEST}" ]]; then
        log_info "[${NAME}] ${CONFIG_DEST} already exists; leaving it untouched (authoritative)"
        return 0
    fi
    _module_config_drop || return $?
    return 0
}
upgrade() {
    : "${CONFIG_DEST:?[${NAME}] CONFIG_DEST required}"
    module_dryrun_guard upgrade "bootstrap ${CONFIG_DEST} (only if absent; never overwrite)" && return 0
    if [[ -e "${CONFIG_DEST}" ]]; then
        log_info "[${NAME}] ${CONFIG_DEST} present; treating as authoritative, not overwriting"
        return 0
    fi
    _module_config_drop
}

# ── Required hooks ───────────────────────────────────────────────────────────
detect() {
    return 0
}
is_recommended() {
    ! is_installed
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
