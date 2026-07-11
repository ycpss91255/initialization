#!/usr/bin/env bash
# module/sshfs.module.sh — sshfs: mount remote filesystems over SSH  [archetype: apt]
#
# FUSE client that mounts a remote directory over SFTP/SSH. Ubuntu ships the
# `sshfs` package; the binary is `sshfs`.
#
# Standalone usage:
#   bash module/sshfs.module.sh install [--dry-run]
#   bash module/sshfs.module.sh upgrade / remove / purge / verify / doctor
#   bash module/sshfs.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/sshfs.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install sshfs

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
NAME="sshfs"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("network" "filesystem")
HOMEPAGE="https://github.com/libfuse/sshfs"
declare -gA DESCRIPTION=(
    [en]="sshfs — mount a remote filesystem over SSH (FUSE)"
    [zh-TW]="sshfs — 透過 SSH 掛載遠端檔案系統(FUSE)"
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
TEST_VERIFY_CMD="command -v sshfs"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=("sshfs")
APT_PPA=""
CONFIG_PATHS=()
module_use_apt_archetype

# ── Required hooks (detect + is_recommended stay module-specific) ────────────
detect() {
    command -v apt-get >/dev/null 2>&1
}

is_recommended() {
    ! is_installed
}

# doctor: real runtime health check — sshfs must be resolvable on PATH.
# sshfs --version needs FUSE present to exit cleanly on some hosts, so the
# canonical health probe is presence-on-PATH (doc/module-spec.md §3.4 allows
# a command -v probe).
doctor() {
    is_installed || { log_warn "[${NAME}] doctor: not installed"; return 1; }
    command -v sshfs >/dev/null 2>&1 || {
        log_warn "[${NAME}] doctor: 'sshfs' not found on PATH"
        return 1
    }
    return 0
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
