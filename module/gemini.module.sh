#!/usr/bin/env bash
# module/gemini.module.sh — Google Gemini CLI  [archetype: custom (npm)]
#
# New module per issue #74 / PRD §6.3.2 (agent CLIs, Batch C). The Gemini
# CLI is an npm-only distribution (@google/gemini-cli) — no apt package, no
# native GitHub-release binary — so archetype D (custom): `npm install -g`
# through the fnm-managed Node.js toolchain (DEPENDS_ON=("fnm"), Q39). When
# npm is not on PATH yet (fresh fnm install, shell hooks not sourced), the
# module falls back to `fnm exec --using=default npm ...` against the fnm
# module's install dir. Sidecar lifecycle per ADR-0001 / module-spec §4.7.4:
# written on install/upgrade success, deleted on remove/purge; state.json is
# engine-only.
#
# Standalone usage:
#   bash module/gemini.module.sh install [--dry-run]
#   bash module/gemini.module.sh upgrade / remove / purge / verify
#   bash module/gemini.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/gemini.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install gemini

# ── Dual-mode header ────────────────────────────────────────────────────────
MODULE_STANDALONE="true"
[[ "${BASH_SOURCE[0]:-}" != "${0:-}" ]] && MODULE_STANDALONE="false"
if [[ "${MODULE_STANDALONE}" == "true" ]]; then
    set -euo pipefail
    shopt -s inherit_errexit 2>/dev/null || true
    MODULE_DIR="${MODULE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-}")" && pwd -P)}"
    REPO_ROOT="${REPO_ROOT:-$(cd -- "${MODULE_DIR}/.." && pwd -P)}"
    LIB_DIR="${LIB_DIR:-${REPO_ROOT}/lib}"
    export MODULE_DIR REPO_ROOT LIB_DIR
    # shellcheck source=../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../lib/general.sh
    source "${LIB_DIR}/general.sh"
    # shellcheck source=../lib/module_helper.sh
    source "${LIB_DIR}/module_helper.sh"
fi

# ── Metadata (doc/module-spec.md §3, PRD §9.1) ──────────────────────────────
NAME="gemini"
VERSION_PROVIDED="latest"
CATEGORY="optional"
TAGS=("agent")
HOMEPAGE="https://github.com/google-gemini/gemini-cli"
declare -gA DESCRIPTION=(
    [en]="gemini — Google Gemini CLI coding agent (npm install via fnm-managed Node.js)"
    [zh-TW]="gemini — Google Gemini CLI 程式編寫代理(經 fnm 管理的 Node.js 以 npm 安裝)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Run 'gemini' once to sign in (Google account or GEMINI_API_KEY). Restart your shell if 'gemini' is not on PATH yet."
    [zh-TW]="首次執行 'gemini' 以登入(Google 帳號或 GEMINI_API_KEY)。若 'gemini' 尚未在 PATH 內,請重新開啟 shell。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=("fnm")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=true
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="user-home"
TEST_VERIFY_CMD="command -v gemini && gemini --version"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype D data — npm package via fnm-managed Node.js ──────────────────
GEMINI_NPM_PKG="@google/gemini-cli"
GEMINI_BIN_NAME="gemini"
# Where the fnm module installs the fnm binary (module/fnm.module.sh keeps
# the same default); used for the `fnm exec` fallback when npm is not on
# PATH. Overridable for tests / relocated installs.
GEMINI_FNM_DIR="${GEMINI_FNM_DIR:-${FNM_INSTALL_DIR:-${HOME}/.local/share/fnm}}"
CONFIG_PATHS=(                                # user config, purge-only
    "${HOME}/.gemini"
)

# ── Lifecycle (hand-written, ADR-0002: all mandatory) ───────────────────────

# is_installed: a gemini binary on PATH is authoritative; otherwise ask npm
# (global tree) — covers fresh installs whose npm bin dir is not on PATH yet.
is_installed() {
    command -v "${GEMINI_BIN_NAME}" >/dev/null 2>&1 && return 0
    _gemini_has_npm || return 1
    _gemini_npm ls -g "${GEMINI_NPM_PKG}" >/dev/null 2>&1
}

install() {
    module_dryrun_guard install \
        "npm install -g ${GEMINI_NPM_PKG}@latest (fnm-managed Node.js) + Sidecar" \
        && return 0
    module_skip_if_installed && return 0
    _gemini_pkg_install || return $?
    module_sidecar_write "${NAME}" "$(_gemini_version)"
}

# upgrade: npm install -g <pkg>@latest doubles as the upgrade path; falls
# through to install when nothing is installed yet.
upgrade() {
    module_dryrun_guard upgrade \
        "npm install -g ${GEMINI_NPM_PKG}@latest (refresh) + Sidecar" \
        && return 0
    if ! is_installed; then
        log_info "[${NAME}] not installed yet — running install instead"
        install
        return $?
    fi
    _gemini_pkg_install || return $?
    module_sidecar_write "${NAME}" "$(_gemini_version)"
}

# remove: npm uninstall the package + drop the Sidecar; user config
# (~/.gemini) is kept — purge wipes it.
remove() {
    module_dryrun_guard remove \
        "npm uninstall -g ${GEMINI_NPM_PKG} + Sidecar (config kept: ${CONFIG_PATHS[*]})" \
        && return 0
    module_skip_if_not_installed && return 0
    _gemini_pkg_uninstall || return $?
    module_sidecar_remove "${NAME}"
}

purge() {
    module_dryrun_guard purge \
        "npm uninstall -g ${GEMINI_NPM_PKG} + rm ${CONFIG_PATHS[*]} + Sidecar" \
        && return 0
    if is_installed; then
        _gemini_pkg_uninstall || return $?
    fi
    local _p
    for _p in "${CONFIG_PATHS[@]}"; do
        rm -rf "${_p}"
    done
    module_sidecar_remove "${NAME}"
}

verify() {
    module_default_verify
}

# detect: any arch with upstream Node.js builds (same set the fnm module
# accepts) — the npm payload itself is arch-independent JS.
detect() {
    case "$(uname -m)" in
        x86_64|aarch64|arm64|armv7l) return 0 ;;
        *) return 1 ;;
    esac
}

is_recommended() {
    ! is_installed
}

# is_outdated: compare Sidecar (or binary-reported) version against the npm
# registry's latest. Not installed / registry unreachable = not outdated.
is_outdated() {
    is_installed || return 1
    local _local="" _remote=""
    _local="$(module_sidecar_get_version "${NAME}" 2>/dev/null)" \
        || _local="$(_gemini_version)"
    _remote="$(_gemini_npm view "${GEMINI_NPM_PKG}" version 2>/dev/null)" \
        || _remote=""
    [[ -n "${_remote}" && "${_local}" != "${_remote}" ]]
}

# doctor: binary runnable (when on PATH) + Sidecar invariant (module-spec
# §4.7.4: is_installed ⟷ Sidecar exists). Read-only — flags drift, never heals.
doctor() {
    local _ok=0 _sidecar
    _sidecar="$(module_sidecar_path "${NAME}")"
    if is_installed; then
        if command -v "${GEMINI_BIN_NAME}" >/dev/null 2>&1 \
            && ! "${GEMINI_BIN_NAME}" --version >/dev/null 2>&1; then
            log_warn "[${NAME}] doctor: ${GEMINI_BIN_NAME} binary not runnable"
            _ok=1
        fi
        if [[ ! -f "${_sidecar}" ]]; then
            log_warn "[${NAME}] doctor: installed but Sidecar missing (ADR-0001 drift; re-run install/upgrade to heal)"
            _ok=1
        fi
    else
        if [[ -e "${_sidecar}" ]]; then
            log_warn "[${NAME}] doctor: Sidecar present but ${GEMINI_BIN_NAME} not installed (ADR-0001 drift; rm ${_sidecar} or reinstall)"
            _ok=1
        fi
    fi
    return "${_ok}"
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Print the fnm binary path (fnm-module install dir first, PATH fallback);
# 1 if absent.
_gemini_fnm_bin() {
    if [[ -x "${GEMINI_FNM_DIR}/fnm" ]]; then
        printf '%s' "${GEMINI_FNM_DIR}/fnm"
        return 0
    fi
    command -v fnm 2>/dev/null
}

# Quiet capability probe: can this environment reach an npm at all?
_gemini_has_npm() {
    command -v npm >/dev/null 2>&1 && return 0
    _gemini_fnm_bin >/dev/null
}

# Single npm seam. PATH npm first (shell hooks active); otherwise route
# through `fnm exec --using=default` against the fnm module's install dir.
# Tests intercept this one function (or drop a fake npm on PATH).
_gemini_npm() {
    if command -v npm >/dev/null 2>&1; then
        npm "$@"
        return $?
    fi
    local _fnm
    _fnm="$(_gemini_fnm_bin)" || {
        log_error "[${NAME}] npm not found and fnm is missing — install the 'fnm' module first (DEPENDS_ON)"
        return 1
    }
    FNM_DIR="${GEMINI_FNM_DIR}" "${_fnm}" exec --using=default npm "$@"
}

# install/upgrade share one npm invocation: @latest is idempotent and
# doubles as the refresh path.
_gemini_pkg_install() {
    _gemini_has_npm || {
        log_error "[${NAME}] no npm available — install the 'fnm' module first (DEPENDS_ON)"
        return 1
    }
    log_info "[${NAME}] npm install -g ${GEMINI_NPM_PKG}@latest"
    _gemini_npm install -g "${GEMINI_NPM_PKG}@latest" || {
        log_error "[${NAME}] npm install -g ${GEMINI_NPM_PKG}@latest failed"
        return 1
    }
}

_gemini_pkg_uninstall() {
    _gemini_has_npm || {
        log_error "[${NAME}] no npm available — cannot uninstall ${GEMINI_NPM_PKG}"
        return 1
    }
    log_info "[${NAME}] npm uninstall -g ${GEMINI_NPM_PKG}"
    _gemini_npm uninstall -g "${GEMINI_NPM_PKG}" || {
        log_error "[${NAME}] npm uninstall -g ${GEMINI_NPM_PKG} failed"
        return 1
    }
}

# Version string for the Sidecar: gemini binary first (fast, offline), npm
# global tree second; falls back to the literal "latest".
_gemini_version() {
    local _ver=""
    if command -v "${GEMINI_BIN_NAME}" >/dev/null 2>&1; then
        _ver="$("${GEMINI_BIN_NAME}" --version 2>/dev/null \
            | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)" || _ver=""
    fi
    if [[ -z "${_ver}" ]] && _gemini_has_npm; then
        _ver="$(_gemini_npm ls -g --depth=0 "${GEMINI_NPM_PKG}" 2>/dev/null \
            | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)" || _ver=""
    fi
    printf '%s' "${_ver:-latest}"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
