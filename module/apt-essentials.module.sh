#!/usr/bin/env bash
# module/apt-essentials.module.sh — minimal apt baseline for the rest of the catalog
#
# Phase 2 batch C — second reference module. Designed as the universal
# base-layer dep so every other module can `DEPENDS_ON=("apt-essentials")`
# without re-listing curl/git/etc.
#
# Per-package fallback strategy (PRD §18.1 Q-A12 / A-N6):
#   - Already installed + OK   -> skip this pkg, continue
#   - Missing, sudo available  -> apt-get install
#   - Missing, no sudo         -> skip this pkg, warn user
#   - End-of-run summary       -> log_info / log_warn with ok / skipped / failed
# This way one missing pkg doesn't kill the whole batch (unlike "all or
# nothing"). The summary lets reviewers verify which pkgs landed.
#
# Phase 3 will expand the pkg list per platform (desktop vs server vs SBC,
# PRD §13 Q1). For Phase 2 we ship the minimal universal set.

# ===========================================================
# Metadata (docs/module-spec.md §3)
# ===========================================================

NAME="apt-essentials"
VERSION_PROVIDED="apt-managed"
DESCRIPTION_EN="Universal apt baseline (git, vim, curl, wget, ca-certificates)"
DESCRIPTION_ZH_TW="apt 通用基底套件(git / vim / curl / wget / ca-certificates)"
CATEGORY="base"
TAGS=("core" "apt")
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl" "container" "vm")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false   # apt-get install requires sudo
RISK_LEVEL="low"
PARALLEL_GROUP="apt"
HOMEPAGE=""

# The minimal universal package list. Phase 3 will branch on form factor
# (desktop adds htop / build-essential / unzip / jq / software-properties-common;
#  server keeps the minimum).
APT_PKGS=(
    "git"
    "vim"
    "curl"
    "wget"
    "ca-certificates"
)

# ===========================================================
# Lifecycle (docs/module-spec.md §4)
# ===========================================================

detect() {
    command -v lsb_release >/dev/null 2>&1 && \
        [[ "$(lsb_release -is 2>/dev/null)" == "Ubuntu" ]]
}

is_recommended() {
    # Always recommended — every other module quietly assumes these tools.
    return 0
}

# is_installed: every pkg in APT_PKGS is dpkg-installed.
is_installed() {
    local _pkg
    for _pkg in "${APT_PKGS[@]}"; do
        if ! dpkg -l "${_pkg}" 2>/dev/null | grep -q '^ii'; then
            return 1
        fi
    done
    return 0
}

# install: per-pkg fallback strategy (see header).
install() {
    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        log_info "[apt-essentials] [DRY-RUN] would ensure these pkgs are installed: ${APT_PKGS[*]}"
        return 0
    fi

    local _have_sudo="false"
    if have_sudo_access 2>/dev/null; then
        _have_sudo="true"
    fi

    # Refresh apt index once up front if we have sudo.
    if [[ "${_have_sudo}" == "true" ]]; then
        log_info "[apt-essentials] apt-get update"
        sudo apt-get update -qq || {
            log_warn "[apt-essentials] apt-get update failed; will try per-pkg install anyway"
        }
    else
        log_warn "[apt-essentials] no sudo access detected — will skip any missing pkg"
    fi

    local -a _ok=() _skipped=() _failed=()
    local _pkg
    for _pkg in "${APT_PKGS[@]}"; do
        if dpkg -l "${_pkg}" 2>/dev/null | grep -q '^ii'; then
            _ok+=("${_pkg}")
            continue
        fi

        if [[ "${_have_sudo}" != "true" ]]; then
            _skipped+=("${_pkg}")
            log_warn "[apt-essentials] no sudo: please install '${_pkg}' manually"
            continue
        fi

        if sudo apt-get install -y --no-install-recommends "${_pkg}"; then
            _ok+=("${_pkg}")
        else
            _failed+=("${_pkg}")
            log_error "[apt-essentials] apt-get install '${_pkg}' failed"
        fi
    done

    log_info "[apt-essentials] summary: ok=${#_ok[@]} skipped=${#_skipped[@]} failed=${#_failed[@]}"
    [[ "${#_skipped[@]}" -gt 0 ]] && log_warn "[apt-essentials] manually install: ${_skipped[*]}"
    [[ "${#_failed[@]}" -gt 0 ]]  && log_error "[apt-essentials] failed: ${_failed[*]}"

    # Treat partial success as success (skipped pkgs are user's problem to
    # resolve, not a fatal error per A-N6). Hard fail only if every pkg
    # failed and nothing succeeded or was skipped.
    if [[ "${#_failed[@]}" -gt 0 && "${#_ok[@]}" -eq 0 && "${#_skipped[@]}" -eq 0 ]]; then
        return 1
    fi
    return 0
}

# remove: explicitly DOES NOT apt-remove these pkgs.
#
# These are universal baseline tools (git/vim/curl/wget/ca-certificates).
# Removing them via apt would break unrelated parts of the system. We instead
# mark them as auto-installed so a future `apt autoremove` could drop them
# if nothing else depends on them — but in practice nothing does, so this is
# basically a no-op. PRD §6.1 / §17 treats apt-essentials as a foundation
# that stays even after every consumer module is purged.
remove() {
    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        log_info "[apt-essentials] [DRY-RUN] would mark pkgs as auto-installed (no apt-remove)"
        return 0
    fi

    log_info "[apt-essentials] marking pkgs as auto-installed (no apt-remove for baseline tools)"
    if have_sudo_access 2>/dev/null; then
        sudo apt-mark auto "${APT_PKGS[@]}" 2>/dev/null || true
    fi
    log_warn "[apt-essentials] baseline tools left in place. Use 'sudo apt autoremove' manually if you truly want them gone."
}

# purge: same as remove (no destructive apt-purge for baseline).
purge() {
    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        log_info "[apt-essentials] [DRY-RUN] purge is the same as remove for apt-essentials (no destructive purge)"
        return 0
    fi
    remove
}
