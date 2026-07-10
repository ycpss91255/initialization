#!/usr/bin/env bash
# module/glow.module.sh — glow markdown renderer (GitHub release archetype)
#
# New module (issue #314): glow is a yazi markdown-preview dependency but was
# not installed by any module. charmbracelet/glow ships versioned goreleaser
# tarballs (glow_<ver>_Linux_x86_64.tar.gz) that wrap their payload in a
# top-level dir (glow_<ver>_Linux_x86_64/glow), so install/upgrade resolve the
# latest tag first, then delegate to the archetype default fetch with
# STRIP_COMPONENTS=1 (super-call pattern, doc/guide/archetype-cookbook.md).
# Sidecar lifecycle per ADR-0001 / module-spec §4.7.4: written on
# install/upgrade success, deleted on remove/purge; state.json is engine-only.
#
# Standalone usage:
#   bash module/glow.module.sh install [--dry-run]
#   bash module/glow.module.sh upgrade / remove / purge / verify / doctor
#   bash module/glow.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/glow.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install glow

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
NAME="glow"
VERSION_PROVIDED="latest"
CATEGORY="optional"
TAGS=("cli-essentials")
HOMEPAGE="https://github.com/charmbracelet/glow"
declare -gA DESCRIPTION=(
    [en]="glow — render markdown on the CLI (yazi markdown-preview dependency)"
    [zh-TW]="glow — 在終端機渲染 markdown(yazi markdown 預覽依賴)"
)
declare -gA POST_INSTALL_MESSAGE=()
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=("curl")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v glow && glow --version | head -n1"

# ── Archetype B — GitHub release ────────────────────────────────────────────
GITHUB_REPO="charmbracelet/glow"
# Asset name is version-dependent; resolved at run time by
# _glow_resolve_asset_pattern (placeholder keeps the archetype data
# contract complete for `info` / dry-run output).
GITHUB_ASSET_PATTERN="glow_<latest>_Linux_x86_64.tar.gz"
INSTALL_DIR="/opt/glow"
BIN_NAME="glow"
# The goreleaser tarball wraps everything in glow_<ver>_Linux_x86_64/, so
# --strip-components=1 flattens that dir into INSTALL_DIR and the binary lands
# at INSTALL_DIR/glow (unlike lazygit's flat tarball).
BIN_PATH_IN_TAR="glow"
BIN_LINK="/usr/local/bin/glow"
STRIP_COMPONENTS=1
USE_SUDO=true
CONFIG_PATHS=(
    "${HOME}/.config/glow"
)
module_use_github_release_archetype

# Override install/upgrade: resolve the versioned asset name first, then
# super-call the archetype fetch. The phase-invocation wrapper writes the
# Sidecar via module_provided_version (ADR-0001); the resolver sets
# MODULE_GH_RESOLVED_VERSION so the wrapper records the resolved tag.
install() {
    module_dryrun_guard install \
        "fetch ${GITHUB_REPO} latest -> ${INSTALL_DIR}, symlink ${BIN_LINK}" \
        && return 0
    module_skip_if_installed && return 0
    _glow_resolve_asset_pattern || return $?
    _module_github_release_fetch_and_install || return $?
}

upgrade() {
    module_dryrun_guard upgrade "force re-download ${GITHUB_REPO} latest" \
        && return 0
    _glow_resolve_asset_pattern || return $?
    _module_github_release_fetch_and_install || return $?
}

# remove/purge: inherit macro defaults (module_default_github_release_*); the
# wrapper removes the Sidecar.

detect() {
    # Upstream ships a Linux_x86_64 tarball we can consume.
    [[ "$(uname -m)" == "x86_64" ]]
}

is_recommended() {
    ! is_installed
}

# is_outdated — compare Sidecar (or binary-reported) version against the
# latest GitHub release tag (doc/guide/archetype-cookbook.md, Archetype B).
is_outdated() {
    is_installed || return 1
    local _local="" _remote=""
    _local="$(_glow_installed_version)" || _local=""
    if declare -F get_github_pkg_latest_version >/dev/null 2>&1; then
        get_github_pkg_latest_version _remote "${GITHUB_REPO}" 2>/dev/null \
            || _remote=""
    fi
    [[ -n "${_remote}" && "${_local}" != "${_remote}" ]]
}

# doctor — metadata contract self-check + Sidecar invariant
# (module-spec §4.7.4: is_installed ⟷ Sidecar exists).
doctor() {
    local _ok=0
    if ! _glow_metadata_selfcheck; then
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

# Resolve the latest release tag and materialise the versioned asset name
# into GITHUB_ASSET_PATTERN for the archetype fetch.
_glow_resolve_asset_pattern() {
    local _ver=""
    if declare -F get_github_pkg_latest_version >/dev/null 2>&1; then
        get_github_pkg_latest_version _ver "${GITHUB_REPO}" || _ver=""
    fi
    if [[ -z "${_ver}" ]]; then
        log_error "[${NAME}] could not resolve latest ${GITHUB_REPO} version"
        return 1
    fi
    GITHUB_ASSET_PATTERN="glow_${_ver}_Linux_x86_64.tar.gz"
    # Feed the resolved tag to the phase-invocation wrapper (module_provided_version).
    MODULE_GH_RESOLVED_VERSION="${_ver}"
}

# Installed version: Sidecar first (fast, offline, module_sidecar_* shared
# helpers), fall back to parsing `glow --version` (pre-Sidecar installs).
_glow_installed_version() {
    if module_sidecar_get_version "${NAME}" 2>/dev/null; then
        return 0
    fi
    local _bin="${BIN_LINK:-/usr/local/bin/${BIN_NAME}}"
    [[ -x "${_bin}" ]] || _bin="${BIN_NAME}"
    "${_bin}" --version 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 \
        || true
}

# Engine-contract assertions (also exercised by `doctor`): every metadata
# field the engine consumes post-source must be declared and well-formed.
_glow_metadata_selfcheck() {
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
