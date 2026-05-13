#!/usr/bin/env bash
# module/<NAME>.module.sh — <short description>
#
# Skeleton for a new module that follows docs/module-spec.md.
#
# Quick start:
#   1. cp template/module.template.sh module/<your-name>.module.sh
#   2. Search for <TODO> markers and fill them in.
#   3. cp template/test.template.bats test/unit/modules/<your-name>_spec.bats
#   4. Run: make test-unit
#
# Notes:
#   - NO top-level `set -euo pipefail` in this file. Engine wraps each
#     module in a sub-shell that already runs strict mode (see lib/runner.sh).
#   - Helpers log_info / log_warn / log_error / exec_cmd / have_sudo_access /
#     apt_pkg_manager / get_github_pkg_latest_version are pre-loaded by the
#     runner sub-shell (it sources lib/logger.sh + lib/general.sh before us).
#   - Honor INIT_UBUNTU_DRY_RUN=true by short-circuiting all side-effectful
#     paths to log_info "[<name>] [DRY-RUN] would ..." and returning 0.

# ===========================================================
# Metadata (docs/module-spec.md §3)
# ===========================================================

NAME="<TODO-kebab-case-name>"
VERSION_PROVIDED="<TODO: apt-managed | latest | v1.2.3>"
DESCRIPTION_EN="<TODO: one-line English description (< 80 chars)>"
DESCRIPTION_ZH_TW="<TODO: 一行繁中描述 (< 50 字元)>"
CATEGORY="<TODO: base | recommended | optional | experimental>"
TAGS=("<TODO-primary-tag>")
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")    # adjust per docs/module-spec.md §3.3
DEPENDS_ON=()                                     # e.g. ("apt-essentials" "fzf")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false                          # true if pure $HOME/.local install works
RISK_LEVEL="low"                                  # low | medium | high (see §9.3)
PARALLEL_GROUP="apt"                              # apt | download | config | custom
HOMEPAGE=""                                       # upstream project URL (optional)

# ===========================================================
# Lifecycle (docs/module-spec.md §4)
# ===========================================================

# detect: 0 = this module is runnable on the current host.
# Be conservative — only return 0 for environments you've actually tested.
detect() {
    # TODO: replace with a real check, e.g.:
    #   command -v lsb_release >/dev/null 2>&1 && \
    #       [[ "$(lsb_release -is)" == "Ubuntu" ]]
    return 0
}

# is_recommended: 0 = recommend this in Quick Setup for the current env.
# Use $INIT_UBUNTU_FORM_FACTOR (set by lib/detect.sh in Phase 3+).
is_recommended() {
    # Example: skip when already installed.
    is_installed && return 1
    # TODO: extra heuristics
    return 0
}

# is_installed: 0 = installed and good. NO side effects.
is_installed() {
    # TODO: replace with a real probe, e.g.:
    #   dpkg -l <pkg> 2>/dev/null | grep -q '^ii'
    #   command -v <binary> >/dev/null 2>&1
    #   [[ -x "/opt/<name>/bin/<name>" ]]
    return 1
}

# install: idempotent. Re-running on an already-installed system MUST exit 0.
install() {
    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        log_info "[${NAME}] [DRY-RUN] would install ${NAME}"
        return 0
    fi

    if is_installed; then
        log_info "[${NAME}] already installed; skipping"
        return 0
    fi

    # TODO: real install steps. Examples:
    #   sudo apt-get install -y <pkg>
    #   curl -fsSL <release-url> | tar -xz -C /opt/<name>
    #   sudo ln -sfn /opt/<name>/bin/<name> /usr/local/bin/<name>

    log_info "[${NAME}] install complete"
}

# remove: idempotent. Keeps user config; only removes packages/binaries.
remove() {
    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        log_info "[${NAME}] [DRY-RUN] would remove ${NAME}"
        return 0
    fi

    if ! is_installed; then
        log_info "[${NAME}] not installed; nothing to remove"
        return 0
    fi

    # TODO: real remove steps. Examples:
    #   sudo apt-get remove -y <pkg>
    #   sudo rm -f /usr/local/bin/<name>
    #   sudo rm -rf /opt/<name>

    log_info "[${NAME}] removed"
}

# purge: remove() + wipe user config / state. Idempotent.
purge() {
    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        log_info "[${NAME}] [DRY-RUN] would purge ${NAME} and its config"
        return 0
    fi

    remove

    # TODO: wipe user/system config dirs. Examples:
    #   sudo rm -rf /etc/<name>
    #   rm -rf "${HOME}/.config/<name>"
    #   rm -rf "${HOME}/.local/share/<name>"

    log_info "[${NAME}] purged"
}
