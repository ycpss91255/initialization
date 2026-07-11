#!/usr/bin/env bash
# module/thunderbird.module.sh — Thunderbird email client  [archetype: apt (PPA + pin)]
#
# Installs Thunderbird as a real .deb from the Mozilla Team PPA
# (`ppa:mozillateam/ppa`) instead of the snap transition package Ubuntu ships
# from 24.04 onward. install() adds the PPA and writes an apt pin
# (/etc/apt/preferences.d) that prefers the PPA build over the archive's
# snap-transition stub, then chains to the apt default (small-tools
# modularization program). Whatever a module adds it removes: remove() drops the
# PPA + pin (clean uninstall); purge() additionally clears the user profile.
# Desktop-only (SUPPORTED_PLATFORMS): a GUI mail client is pointless on headless
# form factors.
#
# Standalone usage:
#   bash module/thunderbird.module.sh install [--dry-run]
#   bash module/thunderbird.module.sh upgrade / remove / purge / verify / doctor
#   bash module/thunderbird.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/thunderbird.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install thunderbird

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
NAME="thunderbird"
VERSION_PROVIDED="ppa-managed"
CATEGORY="optional"
TAGS=("email" "gui")
HOMEPAGE="https://www.thunderbird.net/"
declare -gA DESCRIPTION=(
    [en]="Thunderbird — email client as a real .deb (ppa:mozillateam/ppa, not the snap)"
    [zh-TW]="Thunderbird — 電子郵件用戶端,真正的 .deb 版本(ppa:mozillateam/ppa,非 snap)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Launch Thunderbird from your desktop menu. The apt pin keeps future upgrades on the PPA .deb, not the snap."
    [zh-TW]="從桌面選單啟動 Thunderbird。apt pin 會讓後續升級維持在 PPA 的 .deb 而非 snap。"
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
TEST_VERIFY_CMD="command -v thunderbird"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt (PPA + pin) ───────────────────────────────────────────
APT_PKGS=("thunderbird")
APT_PPA="ppa:mozillateam/ppa"
CONFIG_PATHS=("${HOME}/.thunderbird")
# apt pin: prefer the Mozilla Team PPA build over the archive's snap-transition
# stub. Priority 1001 lets it win even over a higher archive version.
THUNDERBIRD_APT_PIN="/etc/apt/preferences.d/mozillateamppa"
module_use_apt_archetype

# Override install (super-call pattern): write the apt pin (so the PPA .deb wins
# over the snap-transition stub), then chain to the apt default, which adds the
# PPA and installs. The Sidecar is written by the phase-invocation wrapper.
install() {
    module_dryrun_guard install \
        "add ${APT_PPA} + apt pin (${THUNDERBIRD_APT_PIN}) + apt-install ${APT_PKGS[*]}" \
        && return 0
    module_skip_if_installed && return 0
    have_sudo_access 2>/dev/null \
        || { log_error "[${NAME}] sudo required for thunderbird install"; return 1; }
    _thunderbird_write_apt_pin || return $?
    module_default_apt_install
}

# Override remove: clean uninstall — apt-remove the package, then drop the PPA +
# pin it added (idempotent — a second remove is a no-op).
remove() {
    module_dryrun_guard remove "apt-remove ${APT_PKGS[*]} + drop ${APT_PPA} + pin" && return 0
    module_default_apt_remove || return $?
    _thunderbird_remove_apt_repo
}

# Override purge: apt-purge + config wipe (archetype handles APT_PPA + config),
# then drop the apt pin the archetype does not know about.
purge() {
    module_default_apt_purge || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    _thunderbird_remove_apt_pin
}

detect() {
    command -v apt-get >/dev/null 2>&1
}

# Desktop-only recommendation gate (GUI mail client): never pre-tick on
# headless / SBC form factors (doc/module-spec.md §4.3.1).
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

# doctor: a real runtime check — the tool must actually be on PATH, not just
# dpkg-registered (the archetype default only checks is_installed).
doctor() {
    if ! command -v thunderbird >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: thunderbird binary not found on PATH"
        return 1
    fi
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Write the apt pin preferring the Mozilla Team PPA over the snap-transition
# archive package. Idempotent — the file is rewritten in place.
_thunderbird_write_apt_pin() {
    log_info "[${NAME}] writing apt pin ${THUNDERBIRD_APT_PIN}"
    sudo mkdir -p "$(dirname -- "${THUNDERBIRD_APT_PIN}")"
    printf '%s\n' \
        "Package: thunderbird*" \
        "Pin: release o=LP-PPA-mozillateam" \
        "Pin-Priority: 1001" \
        | sudo tee "${THUNDERBIRD_APT_PIN}" > /dev/null
}

# Drop the Mozilla Team PPA + the apt pin (remove). Best effort: without sudo we
# leave them in place and keep the exit code at 0.
_thunderbird_remove_apt_repo() {
    if ! have_sudo_access 2>/dev/null; then
        log_warn "[${NAME}] no sudo: leaving ${APT_PPA} + apt pin in place"
        return 0
    fi
    log_info "[${NAME}] removing ${APT_PPA} + apt pin"
    sudo apt-add-repository -y --remove "${APT_PPA}" || true
    sudo rm -f "${THUNDERBIRD_APT_PIN}"
}

# Drop only the apt pin (purge — the archetype already removed the PPA).
_thunderbird_remove_apt_pin() {
    if ! have_sudo_access 2>/dev/null; then
        log_warn "[${NAME}] no sudo: leaving apt pin in place"
        return 0
    fi
    sudo rm -f "${THUNDERBIRD_APT_PIN}"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
