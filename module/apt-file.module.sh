#!/usr/bin/env bash
# module/apt-file.module.sh — apt-file: search which package provides a file  [archetype: apt]
#
# `apt-file` searches the apt package contents index to answer "which package
# provides <file>?" even for packages that are not installed. Ubuntu ships the
# `apt-file` apt package; the binary is `apt-file`. The contents cache is
# seeded once (best-effort) after install via `apt-file update`.
#
# Standalone usage:
#   bash module/apt-file.module.sh install [--dry-run]
#   bash module/apt-file.module.sh upgrade / remove / purge / verify / doctor
#   bash module/apt-file.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/apt-file.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install apt-file

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
NAME="apt-file"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("cli" "apt")
HOMEPAGE="https://wiki.debian.org/apt-file"
declare -gA DESCRIPTION=(
    [en]="apt-file — search which apt package provides a given file"
    [zh-TW]="apt-file — 查詢某檔案由哪個 apt 套件提供"
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
TEST_VERIFY_CMD="command -v apt-file"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=("apt-file")
APT_PPA=""
CONFIG_PATHS=()
module_use_apt_archetype

# Override install: archetype installs the package, then we seed the contents
# cache once so the very first `apt-file search` has data to work with.
install() {
    module_default_apt_install || return $?
    module_dryrun_guard install "apt-file update (seed contents cache)" && return 0
    _seed_apt_file_cache
}

# ── Required hooks (detect + is_recommended stay module-specific) ────────────
detect() {
    command -v apt-get >/dev/null 2>&1
}

is_recommended() {
    ! is_installed
}

# doctor: real runtime health check — the apt-file binary must resolve on PATH.
doctor() {
    is_installed || { log_warn "[${NAME}] doctor: not installed"; return 1; }
    command -v apt-file >/dev/null 2>&1 || {
        log_warn "[${NAME}] doctor: 'apt-file' not found on PATH"
        return 1
    }
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────
# Seed the apt-file contents cache. Best-effort: a missing binary or no network
# only warns — it must never abort install (the cache also self-populates on
# first `apt-file search`).
_seed_apt_file_cache() {
    command -v apt-file >/dev/null 2>&1 || {
        log_warn "[${NAME}] apt-file not on PATH yet; skipping cache seed"
        return 0
    }
    log_info "[${NAME}] seeding contents cache (apt-file update)..."
    if command -v sudo >/dev/null 2>&1; then
        sudo apt-file update >/dev/null 2>&1 || \
            log_warn "[${NAME}] 'apt-file update' failed (no network?); cache will populate on first search"
    else
        apt-file update >/dev/null 2>&1 || \
            log_warn "[${NAME}] 'apt-file update' failed (no network?); cache will populate on first search"
    fi
    return 0
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
