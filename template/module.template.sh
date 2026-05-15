#!/usr/bin/env bash
# module/<NAME>.module.sh — <one-line summary>
#
# Authoring guide (doc/module-spec.md §3, §4):
#   1. cp template/module.template.sh module/<your-name>.module.sh
#   2. Fill metadata (NAME / DESCRIPTION / CATEGORY / DEPENDS_ON / ...).
#   3. Pick an ARCHETYPE (one line):
#         module_use_apt_archetype             — apt packages
#         module_use_github_release_archetype  — GitHub tarball
#         module_use_config_archetype          — config file drop
#      Or remove the archetype line and hand-write install/update/remove/purge.
#   4. Implement detect() and is_recommended() — these are always module-specific.
#   5. Optionally implement is_outdated() / doctor() for richer engine support.
#   6. cp template/test.template.bats test/unit/module/<your-name>_spec.bats
#   7. Run: make test-unit
#
# Standalone usage:
#   bash module/<x>.module.sh install [--dry-run]
#   bash module/<x>.module.sh update / remove / purge / verify
#   bash module/<x>.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/<x>.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install <x>
#   setup_ubuntu update  <x>
#   setup_ubuntu remove  <x>
#
# Standalone mode does NOT resolve DEPENDS_ON. If your tool needs other
# modules installed first, the user must run those manually, or use
# setup_ubuntu for the full flow.

# ── Dual-mode entry detection ───────────────────────────────────────────────
# When invoked directly (`bash module/<x>.module.sh ...`), MODULE_STANDALONE
# becomes "true": we bootstrap env + source lib helpers, then the footer
# below dispatches to module_standalone_main "$@".
# When source'd by lib/runner.sh into its sub-shell, MODULE_STANDALONE is
# "false": runner already sourced lib helpers, so we skip the bootstrap.

MODULE_STANDALONE="true"
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && MODULE_STANDALONE="false"

if [[ "${MODULE_STANDALONE}" == "true" ]]; then
    set -euo pipefail
    shopt -s inherit_errexit 2>/dev/null || true

    # Resolve paths. Env vars take precedence so tests + relocations work:
    # `LIB_DIR=/path/to/lib bash module/foo.module.sh install` is honored.
    MODULE_DIR="${MODULE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)}"
    REPO_ROOT="${REPO_ROOT:-$(cd -- "${MODULE_DIR}/.." && pwd -P)}"
    LIB_DIR="${LIB_DIR:-${REPO_ROOT}/lib}"
    export MODULE_DIR REPO_ROOT LIB_DIR

    # shellcheck disable=SC1091
    source "${LIB_DIR}/logger.sh"
    # shellcheck disable=SC1091
    source "${LIB_DIR}/general.sh"
    # shellcheck disable=SC1091
    source "${LIB_DIR}/module_helpers.sh"
fi

# ── Metadata ────────────────────────────────────────────────────────────────
#
# 1. Identity
NAME="<TODO-kebab-case-name>"
VERSION_PROVIDED="<TODO: apt-managed | latest | v1.2.3>"
CATEGORY="<TODO: base | recommended | optional | experimental>"
TAGS=("<TODO-primary-tag>")
HOMEPAGE=""                                  # upstream URL, e.g. "https://docs.docker.com/"

# 2. i18n — associative arrays keyed by lang code. Supported: en | zh-TW | zh-CN | ja.
#    Use `declare -gA` (global) so values survive being source'd from inside a
#    function (test fixtures, _load_module helpers, etc.).
#    Helpers: module_get_description / _post_install_message / _warn_message
#    fall back to [en] if the requested language is missing.
declare -gA DESCRIPTION=(
    [en]="<TODO: one-line English description (< 80 chars)>"
    [zh-TW]="<TODO: 一行繁中描述 (< 50 字元)>"
)
declare -gA POST_INSTALL_MESSAGE=(
    # Engine collects these at session end (e.g. "re-login to use docker").
    # Leave empty (no entries) if the module needs no post-install hint.
)
declare -gA WARN_MESSAGE=(
    # Pre-install warning for high-risk modules. Engine surfaces this before
    # install() runs when RISK_LEVEL=high.
)

# 3. Environment constraints
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")   # adjust per doc/module-spec.md §3.3
DEPENDS_ON=()                                     # e.g. ("apt-essentials" "fzf")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false                          # true if pure $HOME/.local install works

# 4. Risk / install behavior
RISK_LEVEL="low"                                  # low | medium | high
REBOOT_REQUIRED=false                             # bool — install needs a reboot
INSTALL_TARGET_DEFAULT="auto"                     # sudo | user-home | auto

# 5. TUI / doctor hints
TEST_VERIFY_CMD=""                                # e.g. "docker run --rm hello-world"

# ── Archetype data + binding (PICK ONE) ─────────────────────────────────────
#
# Uncomment one archetype block and delete the others. Each block declares
# the archetype's data fields and then calls one macro that defines all
# lifecycle functions (is_installed / install / update / remove / purge /
# verify) in one line. You can still override individual lifecycle functions
# below the macro if your tool needs special handling.

# ── Archetype A: APT packages ───────────────────────────────────────────────
# APT_PKGS=(curl ssh keychain)
# APT_PPA=""                                       # e.g. "ppa:fish-shell/release-4"
# CONFIG_PATHS=()                                  # e.g. ("${HOME}/.config/<tool>")
# module_use_apt_archetype

# ── Archetype B: GitHub-release tarball ─────────────────────────────────────
# GITHUB_REPO="neovim/neovim"
# GITHUB_ASSET_PATTERN="nvim-linux-x86_64.tar.gz"
# INSTALL_DIR="/opt/nvim"
# BIN_NAME="nvim"
# # BIN_PATH_IN_TAR="bin/nvim"                     # default: bin/${BIN_NAME}
# # BIN_LINK="/usr/local/bin/nvim"                 # default: /usr/local/bin/${BIN_NAME}
# # STRIP_COMPONENTS=1
# # USE_SUDO=true
# CONFIG_PATHS=("${HOME}/.config/nvim")
# module_use_github_release_archetype

# ── Archetype C: Config-drop ────────────────────────────────────────────────
# CONFIG_TEMPLATE_SRC="${MODULE_DIR}/config/<tool>/<file>"
# CONFIG_DEST="${HOME}/.config/<tool>/<file>"
# # CONFIG_MARKER="# init_ubuntu managed"
# # CONFIG_MODE="600"
# # CONFIG_DIR_MODE="700"
# module_use_config_archetype

# ── Lifecycle: always hand-written ──────────────────────────────────────────
#
# detect() and is_recommended() depend on each module's environment logic.
# is_outdated() and doctor() are OPTIONAL — implement only if useful.

# detect: 0 = module can run on this host.
detect() {
    command -v lsb_release >/dev/null 2>&1 && \
        [[ "$(lsb_release -is 2>/dev/null)" == "Ubuntu" ]]
}

# is_recommended: 0 = include in Quick Setup for the current env.
# Use $INIT_UBUNTU_FORM_FACTOR (set by lib/detect.sh).
is_recommended() {
    is_installed && return 1
    # TODO: extra heuristics (e.g. only on desktop, skip in containers)
    return 0
}

# is_outdated: OPTIONAL. 0 = newer version available. Engine uses this for
# `setup_ubuntu status <m>` and to decide whether `update` actually does work.
# Delete this stub if your tool has no meaningful version concept.
# is_outdated() {
#     return 1
# }

# doctor: OPTIONAL. 0 = self-check passed (and any auto-fix succeeded).
# Engine calls this from `setup_ubuntu doctor`. Without it, doctor falls back
# to is_installed.
# doctor() {
#     is_installed
# }

# ── Custom lifecycle (only if you did NOT use an archetype macro) ───────────
#
# Delete this block entirely if you used module_use_*_archetype above. Keep
# it as a starting point for hand-written tools (docker, nvidia-driver,
# font, etc. where the archetype doesn't fit).

is_installed() {
    # TODO
    return 1
}

install() {
    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        log_info "[${NAME}] [DRY-RUN] would install ${NAME}"
        return 0
    fi
    if is_installed; then
        log_info "[${NAME}] already installed; skipping"
        return 0
    fi
    # TODO: real install steps
    log_info "[${NAME}] install complete"
}

update() {
    # Default: re-run install (idempotent). Override if your tool has a
    # cheaper update path (e.g. apt install --only-upgrade).
    install
}

remove() {
    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        log_info "[${NAME}] [DRY-RUN] would remove ${NAME}"
        return 0
    fi
    if ! is_installed; then
        log_info "[${NAME}] not installed; nothing to remove"
        return 0
    fi
    # TODO: real remove steps
    log_info "[${NAME}] removed"
}

purge() {
    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        log_info "[${NAME}] [DRY-RUN] would purge ${NAME} + config"
        return 0
    fi
    remove
    # TODO: wipe user/system config dirs
    log_info "[${NAME}] purged"
}

verify() {
    module_default_verify "$@"
}

# ── Standalone entry footer ─────────────────────────────────────────────────
# DO NOT REMOVE. Lets `bash module/<name>.module.sh install --dry-run` work
# as a self-contained command. Skipped automatically when source'd by
# lib/runner.sh.

if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
