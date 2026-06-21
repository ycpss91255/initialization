#!/usr/bin/env bash
# module/zoxide.module.sh — zoxide smarter cd (GitHub release) + shell-rc init
#
# Migrated from module/submodule/zoxide.sh to the v2 contract (issue #52).
# Archetype B (github-release) with overrides: the release asset name embeds
# the version (zoxide-<ver>-<arch>-unknown-linux-musl.tar.gz), so install /
# upgrade resolve the latest version first, then super-call the archetype
# default. Both also wire `zoxide init` + the cd->z alias into bash/zsh rc
# files and write the version Sidecar (ADR-0001).

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
NAME="zoxide"
VERSION_PROVIDED="latest"
CATEGORY="optional"
TAGS=("cli-essentials")
HOMEPAGE="https://github.com/ajeetdsouza/zoxide"
declare -gA DESCRIPTION=(
    [en]="zoxide smarter cd command (cd is aliased to z)"
    [zh-TW]="zoxide 智慧 cd 指令(cd 會 alias 成 z)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Restart your shell (or source ~/.bashrc) to activate zoxide."
    [zh-TW]="重新開啟 shell(或 source ~/.bashrc)後 zoxide 才會生效。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v zoxide && zoxide --version"
# Consumed post-source by the engine (registry / runner / TUI) or via nameref
# lookups (module_i18n_get) that ShellCheck cannot trace; export marks the
# external use (SC2034 wiki-recommended fix, no disable needed).
export DESCRIPTION POST_INSTALL_MESSAGE WARN_MESSAGE \
       SUPPORTS_USER_HOME INSTALL_TARGET_DEFAULT

# ── Archetype B — GitHub release ────────────────────────────────────────────
GITHUB_REPO="ajeetdsouza/zoxide"
# Placeholder: the real asset name embeds the version and is resolved by
# _zoxide_resolve_asset_pattern right before install/upgrade.
GITHUB_ASSET_PATTERN="zoxide-<ver>-$(uname -m)-unknown-linux-musl.tar.gz"
INSTALL_DIR="/opt/zoxide"
BIN_NAME="zoxide"
BIN_LINK="/usr/local/bin/zoxide"
BIN_PATH_IN_TAR="zoxide"     # tarball root holds the binary directly
STRIP_COMPONENTS=0
USE_SUDO=true
CONFIG_PATHS=("${HOME}/.local/share/zoxide")
module_use_github_release_archetype

# Override install: resolve versioned asset, super-call the archetype
# default, then wire shell rc. The phase-invocation wrapper writes the
# Sidecar via module_provided_version (ADR-0001); _zoxide_resolve_asset_pattern
# sets MODULE_GH_RESOLVED_VERSION so the wrapper records the resolved tag.
install() {
    module_dryrun_guard install \
        "fetch ${GITHUB_REPO} latest -> ${INSTALL_DIR}, symlink ${BIN_LINK}, shell-rc init" \
        && return 0
    module_skip_if_installed && return 0
    _zoxide_resolve_asset_pattern || return 1
    module_default_github_release_install || return $?
    _zoxide_shell_init
}

upgrade() {
    module_dryrun_guard upgrade \
        "force re-download ${GITHUB_REPO} latest" \
        && return 0
    _zoxide_resolve_asset_pattern || return 1
    module_default_github_release_upgrade || return $?
    _zoxide_shell_init
}

# remove: inherit macro default (the wrapper removes the Sidecar).

# purge keeps the shell-rc cleanup; the wrapper removes the Sidecar.
purge() {
    module_default_github_release_purge || return $?
    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        return 0
    fi
    _zoxide_shell_rc_cleanup
}

detect() {
    # musl release assets exist for x86_64 + aarch64 (covers rpi4/5, jetson).
    case "$(uname -m)" in
        x86_64|aarch64) return 0 ;;
        *) return 1 ;;
    esac
}

is_recommended() {
    ! is_installed
}

# is_outdated: compare Sidecar version against latest GitHub release.
is_outdated() {
    is_installed || return 1
    local _local="" _remote=""
    _local="$(module_sidecar_get_version "${NAME}" 2>/dev/null || true)"
    if declare -F get_github_pkg_latest_version >/dev/null 2>&1; then
        get_github_pkg_latest_version _remote "${GITHUB_REPO}" 2>/dev/null || true
    fi
    [[ -n "${_remote}" && "${_local}" != "${_remote}" ]]
}

# doctor: binary runnable + Sidecar consistency (module-spec §4.7.4:
# installed without Sidecar = drift; re-run install/upgrade to heal — the
# phase-invocation wrapper owns Sidecar writes now, so doctor only warns).
doctor() {
    module_dryrun_guard doctor "is_installed + ${BIN_NAME} --version + Sidecar consistency" \
        && return 0
    is_installed || { log_warn "[${NAME}] doctor: zoxide not installed"; return 1; }
    "${BIN_NAME}" --version >/dev/null 2>&1 \
        || { log_warn "[${NAME}] doctor: zoxide binary not runnable"; return 1; }
    if ! module_sidecar_get_version "${NAME}" >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: Sidecar missing (ADR-0001 drift; re-run install/upgrade to heal)"
    fi
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Resolve the latest release version and rewrite GITHUB_ASSET_PATTERN with it
# (zoxide asset names embed the version, unlike e.g. neovim's stable name).
_zoxide_resolve_asset_pattern() {
    local _ver=""
    if declare -F get_github_pkg_latest_version >/dev/null 2>&1; then
        get_github_pkg_latest_version _ver "${GITHUB_REPO}" 2>/dev/null || true
    fi
    if [[ -z "${_ver}" ]]; then
        log_error "[${NAME}] cannot resolve latest ${GITHUB_REPO} release version"
        return 1
    fi
    # Feed the resolved tag to the phase-invocation wrapper (module_provided_version).
    MODULE_GH_RESOLVED_VERSION="${_ver}"
    GITHUB_ASSET_PATTERN="zoxide-${_ver}-$(uname -m)-unknown-linux-musl.tar.gz"
    log_info "[${NAME}] resolved asset: ${GITHUB_ASSET_PATTERN}"
}

# Append `zoxide init` + the cd->z alias to existing bash/zsh rc files.
# Idempotent: each line is added once (grep -F guard). Shells without an
# rc file are skipped (never create one).
_zoxide_shell_init() {
    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        return 0
    fi
    local _shell _rc _init_line _alias_line
    _alias_line="command -v z &>/dev/null && alias cd='z'"
    for _shell in bash zsh; do
        _rc="${HOME}/.${_shell}rc"
        [[ -f "${_rc}" ]] || continue
        _init_line="eval \"\$(zoxide init ${_shell})\""
        if ! grep -Fq "${_init_line}" "${_rc}"; then
            log_info "[${NAME}] add zoxide init to ${_rc}"
            printf '%s\n' "${_init_line}" >> "${_rc}"
        fi
        if ! grep -Fq "${_alias_line}" "${_rc}"; then
            log_info "[${NAME}] add cd->z alias to ${_rc}"
            printf '%s\n' "${_alias_line}" >> "${_rc}"
        fi
    done
    return 0
}

# Strip the lines _zoxide_shell_init added (fixed-string filter, keeps
# everything else untouched). Used by purge only.
_zoxide_shell_rc_cleanup() {
    local _shell _rc _tmp
    for _shell in bash zsh; do
        _rc="${HOME}/.${_shell}rc"
        [[ -f "${_rc}" ]] || continue
        if grep -Fq "zoxide init" "${_rc}" || grep -Fq "alias cd='z'" "${_rc}"; then
            _tmp="$(mktemp)"
            grep -Fv "zoxide init" "${_rc}" | grep -Fv "alias cd='z'" > "${_tmp}" || true
            cat "${_tmp}" > "${_rc}"   # cat-over keeps perms + inode
            rm -f "${_tmp}"
            log_info "[${NAME}] removed zoxide lines from ${_rc}"
        fi
    done
    return 0
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
