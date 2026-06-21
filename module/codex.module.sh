#!/usr/bin/env bash
# module/codex.module.sh — OpenAI Codex CLI (GitHub release archetype)
#
# New module (issue #58, PRD §6.3.2 Batch C). Upstream ships stable-named
# native binaries per arch (codex-<arch>-unknown-linux-musl.tar.gz), so the
# archetype default fetch works against the /releases/latest/download URL
# without resolving a versioned asset name. Release tags look like
# rust-v0.99.0; the module normalises that to 0.99.0 for the Sidecar and
# is_outdated comparisons. Sidecar lifecycle per ADR-0001 / module-spec
# §4.7.4: written on install/upgrade success, deleted on remove/purge;
# state.json is engine-only.

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
NAME="codex"
VERSION_PROVIDED="latest"
CATEGORY="optional"
TAGS=("agent")
HOMEPAGE="https://github.com/openai/codex"
declare -gA DESCRIPTION=(
    [en]="codex — OpenAI Codex CLI coding agent"
    [zh-TW]="codex — OpenAI Codex CLI 程式編寫代理"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Run 'codex' once to sign in (ChatGPT account or API key)."
    [zh-TW]="首次執行 'codex' 以登入(ChatGPT 帳號或 API key)。"
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
TEST_VERIFY_CMD="command -v codex && codex --version | head -n1"

# ── Archetype B — GitHub release ────────────────────────────────────────────
GITHUB_REPO="openai/codex"
# Upstream asset names embed the Rust target triple and stay stable across
# releases — pick the musl build for the current arch at source time.
_CODEX_ARCH="$(uname -m)"
GITHUB_ASSET_PATTERN="codex-${_CODEX_ARCH}-unknown-linux-musl.tar.gz"
INSTALL_DIR="/opt/codex"
BIN_NAME="codex"
BIN_PATH_IN_TAR="codex-${_CODEX_ARCH}-unknown-linux-musl"  # flat tarball
BIN_LINK="/usr/local/bin/codex"
STRIP_COMPONENTS=0
USE_SUDO=true
CONFIG_PATHS=(
    "${HOME}/.codex"
)
module_use_github_release_archetype

# Override install/upgrade: the asset URL is version-independent, so the
# latest-tag lookup is best-effort, only feeding the Sidecar (ADR-0001).
install() {
    module_dryrun_guard install \
        "fetch ${GITHUB_REPO} latest -> ${INSTALL_DIR}, symlink ${BIN_LINK}" \
        && return 0
    module_skip_if_installed && return 0
    _codex_resolve_target_version
    _module_github_release_fetch_and_install || return $?
    module_sidecar_write "${NAME}" "${_CODEX_TARGET_VERSION:-unknown}"
}

upgrade() {
    module_dryrun_guard upgrade "force re-download ${GITHUB_REPO} latest" \
        && return 0
    _codex_resolve_target_version
    _module_github_release_fetch_and_install || return $?
    module_sidecar_write "${NAME}" "${_CODEX_TARGET_VERSION:-unknown}"
}

remove() {
    module_dryrun_guard remove \
        "rm ${INSTALL_DIR} + ${BIN_LINK} + Sidecar" \
        && return 0
    module_default_github_release_remove || return $?
    module_sidecar_remove "${NAME}"
}

purge() {
    module_dryrun_guard purge \
        "rm ${INSTALL_DIR} + ${BIN_LINK} + Sidecar + CONFIG_PATHS" \
        && return 0
    module_default_github_release_purge || return $?
    module_sidecar_remove "${NAME}"
}

detect() {
    # Upstream ships Linux musl tarballs for x86_64 and aarch64 only.
    case "$(uname -m)" in
        x86_64|aarch64) return 0 ;;
        *) return 1 ;;
    esac
}

is_recommended() {
    ! is_installed
}

# is_outdated — compare Sidecar (or binary-reported) version against the
# latest GitHub release tag (doc/guide/archetype-cookbook.md, Archetype B).
is_outdated() {
    is_installed || return 1
    local _local="" _remote=""
    _local="$(_codex_installed_version)" || _local=""
    if declare -F get_github_pkg_latest_version >/dev/null 2>&1; then
        get_github_pkg_latest_version _remote "${GITHUB_REPO}" 2>/dev/null \
            || _remote=""
    fi
    _remote="$(_codex_normalize_version "${_remote}")"
    [[ -n "${_remote}" && "${_local}" != "${_remote}" ]]
}

# doctor — metadata contract self-check + Sidecar invariant
# (module-spec §4.7.4: is_installed ⟷ Sidecar exists).
doctor() {
    local _ok=0
    if ! _codex_metadata_selfcheck; then
        log_warn "[${NAME}] doctor: metadata contract check failed"
        _ok=1
    fi
    local _sidecar
    _sidecar="$(module_sidecar_path "${NAME}")"
    if is_installed; then
        if [[ ! -f "${_sidecar}" ]]; then
            log_warn "[${NAME}] doctor: installed but Sidecar missing (ADR-0001 drift; re-run install/upgrade to heal)"
            _ok=1
        fi
    else
        if [[ -e "${_sidecar}" ]]; then
            log_warn "[${NAME}] doctor: Sidecar present but ${BIN_NAME} not installed (ADR-0001 drift; rm ${_sidecar} or reinstall)"
            _ok=1
        fi
    fi
    return "${_ok}"
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Strip the upstream tag decoration (rust-v0.99.0 / v0.99.0 -> 0.99.0).
_codex_normalize_version() {
    local _v="${1:-}"
    _v="${_v#rust-}"
    _v="${_v#v}"
    printf '%s' "${_v}"
}

# Best-effort latest-tag lookup for the Sidecar; the download itself uses
# the stable /releases/latest/download asset URL, so failure is non-fatal.
_codex_resolve_target_version() {
    local _ver=""
    if declare -F get_github_pkg_latest_version >/dev/null 2>&1; then
        get_github_pkg_latest_version _ver "${GITHUB_REPO}" 2>/dev/null \
            || _ver=""
    fi
    _CODEX_TARGET_VERSION="$(_codex_normalize_version "${_ver}")"
    [[ -n "${_CODEX_TARGET_VERSION}" ]] \
        || log_warn "[${NAME}] could not resolve latest ${GITHUB_REPO} tag (Sidecar will record 'unknown')"
    return 0
}

# Installed version: Sidecar first (fast, offline, module_sidecar_* shared
# helpers), fall back to parsing `codex --version` (pre-Sidecar installs).
_codex_installed_version() {
    if module_sidecar_get_version "${NAME}" 2>/dev/null; then
        return 0
    fi
    local _bin="${BIN_LINK:-/usr/local/bin/${BIN_NAME}}"
    [[ -x "${_bin}" ]] || _bin="${BIN_NAME}"
    "${_bin}" --version 2>/dev/null \
        | sed -n 's/^codex[^ ]* \([0-9][0-9.]*\).*/\1/p' \
        || true
}

# Engine-contract assertions (also exercised by `doctor`): every metadata
# field the engine consumes post-source must be declared and well-formed.
_codex_metadata_selfcheck() {
    [[ -n "${DESCRIPTION[en]:-}" ]] || return 1
    [[ "${#POST_INSTALL_MESSAGE[@]}" -ge 0 ]] || return 1
    [[ "${#WARN_MESSAGE[@]}" -ge 0 ]] || return 1
    [[ "${SUPPORTS_USER_HOME}" == "true" || "${SUPPORTS_USER_HOME}" == "false" ]] || return 1
    [[ "${INSTALL_TARGET_DEFAULT}" == "sudo" || "${INSTALL_TARGET_DEFAULT}" == "user-home" || "${INSTALL_TARGET_DEFAULT}" == "auto" ]] || return 1
    return 0
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
