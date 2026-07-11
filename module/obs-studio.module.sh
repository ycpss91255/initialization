#!/usr/bin/env bash
# module/obs-studio.module.sh — OBS Studio screen recorder / streamer  [archetype: apt (PPA)]
#
# Installs OBS Studio via the upstream `ppa:obsproject/obs-studio` (small-tools
# modularization program). Explicit repository choice: the OBS Project PPA is
# preferred over the distro archive package so the desktop tracks the current
# OBS releases the project publishes, rather than the older version frozen into
# a given Ubuntu release. The apt archetype adds the PPA before install; remove
# and purge drop it again for a clean uninstall (whatever a module adds, it
# removes).
#
# Desktop-only (SUPPORTED_PLATFORMS / is_recommended, GUI gate): a screen
# recorder / streamer is pointless on headless server / WSL / SBC form factors.
#
# Standalone usage:
#   bash module/obs-studio.module.sh install [--dry-run]
#   bash module/obs-studio.module.sh upgrade / remove / purge / verify / doctor
#   bash module/obs-studio.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/obs-studio.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install obs-studio

# ── BEGIN: shared-bootstrap ─────────────────────────────────────────────────
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
# ── END: shared-bootstrap ───────────────────────────────────────────────────

# ── Metadata (doc/module-spec.md §3) ────────────────────────────────────────
NAME="obs-studio"
VERSION_PROVIDED="ppa-managed"
CATEGORY="optional"
TAGS=("media" "gui")
HOMEPAGE="https://obsproject.com/"
declare -gA DESCRIPTION=(
    [en]="OBS Studio — screen recorder / live streamer (ppa:obsproject/obs-studio)"
    [zh-TW]="OBS Studio — 螢幕錄製 / 直播串流工具(ppa:obsproject/obs-studio)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Launch OBS Studio from your desktop menu. First run offers an auto-configuration wizard."
    [zh-TW]="從桌面選單啟動 OBS Studio。首次啟動會提供自動設定精靈。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v obs"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt (PPA) ─────────────────────────────────────────────────
# APT_PPA is added by module_default_apt_install before the package install;
# remove() and purge() drop it again (clean uninstall). CONFIG_PATHS is cleared
# on purge only.
APT_PKGS=("obs-studio")
APT_PPA="ppa:obsproject/obs-studio"
CONFIG_PATHS=("${HOME}/.config/obs-studio")
module_use_apt_archetype

# ── Hand-written required hooks ─────────────────────────────────────────────
detect() {
    command -v apt-get >/dev/null 2>&1
}

# Desktop-only recommendation gate (GUI recorder): never pre-tick on headless /
# SBC form factors (doc/module-spec.md §4.3.1).
is_recommended() {
    case "${INIT_UBUNTU_FORM_FACTOR:-}" in
        desktop)
            ! is_installed
            ;;
        *)
            return 1
            ;;
    esac
}

# Override remove: the apt archetype default keeps the PPA on remove; the
# contract here is a clean uninstall, so drop the PPA too (idempotent — a
# second remove is a no-op).
remove() {
    module_dryrun_guard remove "apt-remove ${APT_PKGS[*]} + drop ${APT_PPA}" && return 0
    module_default_apt_remove || return $?
    _obs_studio_remove_ppa
}

# purge inherits the apt archetype (apt-purge + remove PPA + rm CONFIG_PATHS);
# module_default_apt_purge already tears the PPA down, so no override is needed.

# doctor: a real runtime check — the tool must actually be on PATH, not just
# dpkg-registered (the archetype default only checks is_installed).
doctor() {
    if ! command -v obs >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: obs binary not found on PATH"
        return 1
    fi
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Drop the OBS Project PPA (remove + purge). Best effort: without sudo we leave
# the PPA in place and keep the exit code at 0.
_obs_studio_remove_ppa() {
    if ! have_sudo_access 2>/dev/null; then
        log_warn "[${NAME}] no sudo: leaving ${APT_PPA} in place"
        return 0
    fi
    log_info "[${NAME}] removing ${APT_PPA}"
    sudo apt-add-repository -y --remove "${APT_PPA}" || true
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
