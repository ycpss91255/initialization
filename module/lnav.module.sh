#!/usr/bin/env bash
# module/lnav.module.sh — lnav: log file navigator  [archetype: custom]
#
# Migrated from the v1 `module/config/lnav_pkg/` packaging (config bundle
# loaded ad-hoc via `lnav -I <lnav_pkg_path>`) to the v2 contract
# (doc/module-spec.md). Custom archetype D: the install is two halves —
# the apt `lnav` package (binary) plus the legacy lnav_pkg config bundle
# (theme/UI settings + custom log formats) deployed to ~/.config/lnav so
# lnav picks it up without the -I flag. The package half reuses the
# module_default_apt_* helpers; the bundle half is hand-written.
#
# Standalone usage:
#   bash module/lnav.module.sh install [--dry-run]
#   bash module/lnav.module.sh upgrade / remove / purge / verify
#   bash module/lnav.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/lnav.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install lnav

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
NAME="lnav"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("logs")
HOMEPAGE="https://lnav.org"
declare -gA DESCRIPTION=(
    [en]="lnav — log file navigator for the terminal (apt package + lnav_pkg config bundle)"
    [zh-TW]="lnav — 終端機日誌檢視器(apt 套件 + lnav_pkg 設定包)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Personal config bundle (theme, UI settings, custom log formats) deployed to ~/.config/lnav — lnav loads it automatically, no -I flag needed."
    [zh-TW]="個人 config 設定包(主題、UI 設定、自訂日誌格式)已部署到 ~/.config/lnav — lnav 會自動載入,無需 -I 參數。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl" "container" "vm")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v lnav && lnav -V"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype D — custom (apt package + lnav_pkg config bundle) ─────────────
# The package half delegates to the apt defaults (lib/module_helper.sh §4);
# the config-bundle half (deploy on install/upgrade, wipe on purge) is
# hand-written below. The bundle is the legacy v1 packaging, kept in-tree.
APT_PKGS=("lnav")
LNAV_CONFIG_SRC="${MODULE_DIR:-${BASH_SOURCE[0]%/*}}/config/lnav_pkg"
LNAV_CONFIG_DEST="${HOME}/.config/lnav"

is_installed() {
    module_default_apt_is_installed
}

is_outdated() {
    module_default_apt_is_outdated
}

verify() {
    module_default_verify
}

# install: apt package, then deploy the config bundle, then record the
# version Sidecar (ADR-0001; module_sidecar_* helpers are dry-run-safe).
install() {
    module_dryrun_guard install \
        "apt-install ${APT_PKGS[*]} + deploy lnav_pkg config bundle -> ${LNAV_CONFIG_DEST}" \
        && return 0
    module_default_apt_install || return $?
    _lnav_deploy_config || return $?
    module_sidecar_write "${NAME}" "$(_lnav_pkg_version)"
}

# upgrade: apt --only-upgrade, then re-deploy the bundle so config changes
# shipped with the repo reach ~/.config/lnav, then refresh the Sidecar.
upgrade() {
    module_dryrun_guard upgrade \
        "apt-upgrade ${APT_PKGS[*]} + re-deploy lnav_pkg config bundle" \
        && return 0
    module_default_apt_upgrade || return $?
    _lnav_deploy_config || return $?
    module_sidecar_write "${NAME}" "$(_lnav_pkg_version)"
}

# remove: drop the package but KEEP ~/.config/lnav (remove vs purge
# semantics), then drop the Sidecar — installed-version is state, not config.
remove() {
    module_dryrun_guard remove \
        "apt-remove ${APT_PKGS[*]} (config bundle kept: ${LNAV_CONFIG_DEST})" \
        && return 0
    module_default_apt_remove || return $?
    module_sidecar_remove "${NAME}"
}

# purge: package + the deployed config bundle + Sidecar.
purge() {
    module_dryrun_guard purge \
        "apt-purge ${APT_PKGS[*]} + rm -rf ${LNAV_CONFIG_DEST}" \
        && return 0
    module_default_apt_purge || return $?
    rm -rf "${LNAV_CONFIG_DEST}"
    module_sidecar_remove "${NAME}"
}

detect() {
    command -v apt-get >/dev/null 2>&1
}

is_recommended() {
    ! is_installed
}

# doctor: health check — package installed, binary runnable, config bundle
# and Sidecar present (the latter two warn-only).
doctor() {
    if ! is_installed; then
        log_warn "[${NAME}] doctor: lnav is not installed"
        return 1
    fi
    local _bin
    _bin="$(command -v lnav 2>/dev/null)" || {
        log_warn "[${NAME}] doctor: lnav binary not found on PATH"
        return 1
    }
    if ! "${_bin}" -V >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: ${_bin} -V failed"
        return 1
    fi
    [[ -f "${LNAV_CONFIG_DEST}/config.json" ]] \
        || log_warn "[${NAME}] doctor: config bundle missing at ${LNAV_CONFIG_DEST} (run install/upgrade to deploy)"
    module_sidecar_get_version "${NAME}" >/dev/null 2>&1 \
        || log_warn "[${NAME}] doctor: sidecar missing (installed outside init_ubuntu?)"
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Copy the legacy lnav_pkg bundle into ~/.config/lnav (idempotent; existing
# user-added files are kept, bundle files are overwritten with repo copies).
_lnav_deploy_config() {
    if [[ ! -d "${LNAV_CONFIG_SRC}" ]]; then
        log_warn "[${NAME}] config bundle missing: ${LNAV_CONFIG_SRC} (skipping deploy)"
        return 0
    fi
    mkdir -p "${LNAV_CONFIG_DEST}" || {
        log_error "[${NAME}] cannot create ${LNAV_CONFIG_DEST}"
        return 1
    }
    cp -r "${LNAV_CONFIG_SRC}/." "${LNAV_CONFIG_DEST}/" || {
        log_error "[${NAME}] config bundle deploy failed -> ${LNAV_CONFIG_DEST}"
        return 1
    }
    log_info "[${NAME}] config bundle deployed -> ${LNAV_CONFIG_DEST}"
}

# Version string for the Sidecar: dpkg-reported package version, falling
# back to the literal "apt-managed" when dpkg has no answer.
_lnav_pkg_version() {
    local _ver=""
    _ver="$(dpkg-query -W -f='${Version}' lnav 2>/dev/null)" || _ver=""
    printf '%s' "${_ver:-apt-managed}"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
