#!/usr/bin/env bash
# module/apt-essentials.module.sh — minimal apt baseline for the rest of the catalog
#
# Per-package fallback strategy (PRD §18.1 Q-A12 / A-N6):
#   - Already installed + OK   -> skip this pkg, continue
#   - Missing, sudo available  -> apt-get install
#   - Missing, no sudo         -> skip this pkg, warn user
#   - End-of-run summary       -> log_info / log_warn with ok / skipped / failed
# One missing pkg doesn't kill the whole batch (vs. "all or nothing").

# ── Dual-mode header ────────────────────────────────────────────────────────
MODULE_STANDALONE="true"
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && MODULE_STANDALONE="false"
if [[ "${MODULE_STANDALONE}" == "true" ]]; then
    set -euo pipefail
    shopt -s inherit_errexit 2>/dev/null || true
    MODULE_DIR="${MODULE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)}"
    REPO_ROOT="${REPO_ROOT:-$(cd -- "${MODULE_DIR}/.." && pwd -P)}"
    LIB_DIR="${LIB_DIR:-${REPO_ROOT}/lib}"
    # shellcheck disable=SC1091
    source "${LIB_DIR}/logger.sh"
    # shellcheck disable=SC1091
    source "${LIB_DIR}/general.sh"
    # shellcheck disable=SC1091
    source "${LIB_DIR}/module_helpers.sh"
fi

# ── Metadata (doc/module-spec.md §3) ───────────────────────────────────────
NAME="apt-essentials"
VERSION_PROVIDED="apt-managed"
CATEGORY="base"
TAGS=("core" "apt")
HOMEPAGE=""
declare -gA DESCRIPTION=(
    [en]="Universal apt baseline (git, vim, curl, wget, ca-certificates, jq)"
    [zh-TW]="apt 通用基底套件(git / vim / curl / wget / ca-certificates / jq)"
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
TEST_VERIFY_CMD="command -v git && command -v curl && command -v jq"

# Universal package list. Per-platform expansion lives in form_factor profiles
# (see lib/platform.sh), not here.
APT_PKGS=(
    "git"
    "vim"
    "curl"
    "wget"
    "ca-certificates"
    "jq"
)
APT_PPA=""
CONFIG_PATHS=()

# ── Lifecycle ───────────────────────────────────────────────────────────────
# We DO NOT use module_use_apt_archetype because remove/purge are intentionally
# non-destructive for baseline tools. is_installed() reuses the helper.

is_installed() {
    module_default_apt_is_installed
}

# install: per-pkg fallback (continue on missing sudo / single failure).
install() {
    module_dryrun_guard install "ensure pkgs installed: ${APT_PKGS[*]}" && return 0

    local _have_sudo="false"
    have_sudo_access 2>/dev/null && _have_sudo="true"

    if [[ "${_have_sudo}" == "true" ]]; then
        log_info "[${NAME}] apt-get update"
        sudo apt-get update -qq \
            || log_warn "[${NAME}] apt-get update failed; will try per-pkg install anyway"
    else
        log_warn "[${NAME}] no sudo access detected — will skip any missing pkg"
    fi

    local -a _ok=() _skipped=() _failed=()
    local _pkg
    for _pkg in "${APT_PKGS[@]}"; do
        if dpkg -l "${_pkg}" 2>/dev/null | grep -q '^ii'; then
            _ok+=("${_pkg}"); continue
        fi
        if [[ "${_have_sudo}" != "true" ]]; then
            _skipped+=("${_pkg}")
            log_warn "[${NAME}] no sudo: please install '${_pkg}' manually"
            continue
        fi
        if sudo apt-get install -y --no-install-recommends "${_pkg}"; then
            _ok+=("${_pkg}")
        else
            _failed+=("${_pkg}")
            log_error "[${NAME}] apt-get install '${_pkg}' failed"
        fi
    done

    log_info "[${NAME}] summary: ok=${#_ok[@]} skipped=${#_skipped[@]} failed=${#_failed[@]}"
    [[ "${#_skipped[@]}" -gt 0 ]] && log_warn "[${NAME}] manually install: ${_skipped[*]}"
    [[ "${#_failed[@]}" -gt 0 ]]  && log_error "[${NAME}] failed: ${_failed[*]}"

    # Hard fail only if nothing succeeded AND nothing was skipped — i.e. every
    # attempted install failed (skipped pkgs are not a fatal failure here).
    if [[ "${#_failed[@]}" -gt 0 && "${#_ok[@]}" -eq 0 && "${#_skipped[@]}" -eq 0 ]]; then
        return 1
    fi
    return 0
}

# update: same path as install (apt-get update + per-pkg install handles upgrades).
update() {
    install
}

# remove: intentionally non-destructive. Baseline tools stay; only mark them
# auto-installed so a future `apt autoremove` could drop them if nothing else
# depends on them.
remove() {
    module_dryrun_guard remove "apt-mark auto ${APT_PKGS[*]} (no apt-remove)" && return 0
    log_info "[${NAME}] marking pkgs as auto-installed (no apt-remove for baseline)"
    if have_sudo_access 2>/dev/null; then
        sudo apt-mark auto "${APT_PKGS[@]}" 2>/dev/null || true
    fi
    log_warn "[${NAME}] baseline left in place. Run 'sudo apt autoremove' manually to drop unused."
}

# purge: same as remove (no destructive apt-purge for baseline).
purge() {
    module_dryrun_guard purge "same as remove (no destructive purge)" && return 0
    remove
}

verify() {
    module_default_verify
}

detect() {
    command -v lsb_release >/dev/null 2>&1 && \
        [[ "$(lsb_release -is 2>/dev/null)" == "Ubuntu" ]]
}

is_recommended() {
    return 0
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
