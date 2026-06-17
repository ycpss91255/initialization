#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata vars (NAME / DESCRIPTION / CATEGORY / TAGS / ...) consumed by engine post-source — https://www.shellcheck.net/wiki/SC2034
# module/<NAME>.module.sh — <one-line summary>  [archetype: github-release]
#
# Authoring guide (doc/module-spec.md §3, §4; cookbook: doc/guide/archetype-cookbook.md):
#   1. cp template/module-github-release.template.sh module/<your-name>.module.sh
#   2. Fill metadata (NAME / DESCRIPTION / CATEGORY / DEPENDS_ON / ...).
#   3. Fill GITHUB_REPO / GITHUB_ASSET_PATTERN / INSTALL_DIR / BIN_NAME in the
#      archetype block below.
#   4. Implement detect() and is_recommended() — these are always module-specific.
#   5. Optionally implement is_outdated() / doctor() for richer engine support.
#   6. cp template/test.template.bats test/unit/module/<your-name>_spec.bats
#   7. Run: just -f justfile.ci test-unit   (Docker-only; see ADR-0004)
#
# Standalone usage:
#   bash module/<x>.module.sh install [--dry-run]
#   bash module/<x>.module.sh upgrade / remove / purge / verify
#   bash module/<x>.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/<x>.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install <x>
#   setup_ubuntu upgrade <x>
#   setup_ubuntu remove  <x>
#
# Standalone mode does NOT resolve DEPENDS_ON. If your tool needs other
# modules installed first, the user must run those manually, or use
# setup_ubuntu for the full flow.

# ── BEGIN: shared-bootstrap ─────────────────────────────────────────────────
# Dual-mode entry detection.
# When invoked directly (`bash module/<x>.module.sh ...`), MODULE_STANDALONE
# becomes "true": we bootstrap env + source lib helpers, then the footer
# below dispatches to module_standalone_main "$@".
# When source'd by lib/runner.sh into its sub-shell, MODULE_STANDALONE is
# "false": runner already sourced lib helpers, so we skip the bootstrap.

MODULE_STANDALONE="true"
[[ "${BASH_SOURCE[0]:-}" != "${0:-}" ]] && MODULE_STANDALONE="false"

if [[ "${MODULE_STANDALONE}" == "true" ]]; then
    set -euo pipefail
    shopt -s inherit_errexit 2>/dev/null || true

    # Resolve paths. Env vars take precedence so tests + relocations work:
    # `LIB_DIR=/path/to/lib bash module/foo.module.sh install` is honored.
    MODULE_DIR="${MODULE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-}")" && pwd -P)}"
    REPO_ROOT="${REPO_ROOT:-$(cd -- "${MODULE_DIR}/.." && pwd -P)}"
    LIB_DIR="${LIB_DIR:-${REPO_ROOT}/lib}"
    export MODULE_DIR REPO_ROOT LIB_DIR

    # shellcheck source=/dev/null  # template — source path resolved per-module-instance
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=/dev/null  # template — source path resolved per-module-instance
    source "${LIB_DIR}/general.sh"
    # shellcheck source=/dev/null  # template — source path resolved per-module-instance
    source "${LIB_DIR}/module_helper.sh"
fi
# ── END: shared-bootstrap ───────────────────────────────────────────────────

# ── BEGIN: shared-metadata ──────────────────────────────────────────────────
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
TEST_VERIFY_CMD=""                                # e.g. "command -v <tool>" (see cookbook for archetype examples)
# ── END: shared-metadata ────────────────────────────────────────────────────

# ── BEGIN: archetype-data ───────────────────────────────────────────────────
# Archetype B: GitHub-release tarball
GITHUB_REPO="<TODO: owner/repo, e.g. neovim/neovim>"
GITHUB_ASSET_PATTERN="<TODO: e.g. nvim-linux-x86_64.tar.gz>"
INSTALL_DIR="<TODO: e.g. /opt/nvim>"
BIN_NAME="<TODO: e.g. nvim>"
# BIN_PATH_IN_TAR="bin/nvim"                     # default: bin/${BIN_NAME}
# BIN_LINK="/usr/local/bin/nvim"                 # default: /usr/local/bin/${BIN_NAME}
# STRIP_COMPONENTS=1
# USE_SUDO=true
CONFIG_PATHS=()                                   # e.g. ("${HOME}/.config/<tool>")
module_use_github_release_archetype
# ── END: archetype-data ─────────────────────────────────────────────────────

# ── BEGIN: shared-lifecycle-stubs ───────────────────────────────────────────
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
# `setup_ubuntu status <m>` and to decide whether `upgrade` actually does work.
# See doc/guide/archetype-cookbook.md for archetype-specific examples.
# is_outdated() {
#     return 1
# }

# doctor: OPTIONAL. 0 = self-check passed (and any auto-fix succeeded).
# Engine calls this from `setup_ubuntu doctor`. Without it, doctor falls back
# to is_installed.
# doctor() {
#     is_installed
# }
# ── END: shared-lifecycle-stubs ─────────────────────────────────────────────

# ── BEGIN: shared-footer ────────────────────────────────────────────────────
# Standalone entry footer — DO NOT REMOVE.
# Lets `bash module/<name>.module.sh install --dry-run` work as a
# self-contained command. Skipped automatically when source'd by lib/runner.sh.

if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
# ── END: shared-footer ──────────────────────────────────────────────────────
