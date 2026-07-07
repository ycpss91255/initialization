#!/usr/bin/env bash
# module/trash-maintenance.module.sh — daily trash size/age maintenance  [archetype: custom]
#
# Promotes the legacy tool/trash-maintenance.sh one-off to the v2 module
# contract (doc/module-spec.md). This module owns the SINGLE source of truth
# for trash retention:
#   1. Deploys the corrected maintenance script to ~/.local/bin/ (fixes for
#      issue #277 baked into module/config/trash-maintenance/trash-maintenance.sh).
#   2. Schedules it via a daily USER crontab entry (no sudo) — the mechanism
#      the two live hosts already use (TODO.md "Trash 自動維護").
#   3. Disables GNOME's own trash auto-delete so gsd-housekeeping never fights
#      the script (issue #275). remove()/purge() reset that key back to default.
#
# Standalone usage:
#   bash module/trash-maintenance.module.sh install [--dry-run]
#   bash module/trash-maintenance.module.sh upgrade / remove / purge / verify
#   bash module/trash-maintenance.module.sh detect / is-installed / is-recommended
#   bash module/trash-maintenance.module.sh info / status
#
# Engine usage:
#   setup_ubuntu install trash-maintenance

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
NAME="trash-maintenance"
VERSION_PROVIDED="1.0"
CATEGORY="optional"
TAGS=("maintenance" "trash" "cron")
HOMEPAGE=""
declare -gA DESCRIPTION=(
    [en]="Daily trash cleanup: age + size cap (single source of truth vs GNOME auto-delete)"
    [zh-TW]="每日垃圾桶清理:天數 + 容量上限(取代 GNOME auto-delete 成為唯一維護來源)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Requires trash-cli (trash-empty). Logs to ~/.local/state/trash-maintenance.log. Override MAX_DAYS/MAX_GB via the crontab env if the defaults (90 days / 30 GB) do not fit."
    [zh-TW]="需要 trash-cli(trash-empty)。紀錄寫入 ~/.local/state/trash-maintenance.log。若預設(90 天 / 30 GB)不合用,可在 crontab 以環境變數覆蓋 MAX_DAYS/MAX_GB。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=true
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="user-home"
TEST_VERIFY_CMD=""

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${VERSION_PROVIDED}" "${CATEGORY}" "${TAGS[*]}" "${HOMEPAGE}" \
    "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTED_UBUNTU[*]}" "${SUPPORTED_PLATFORMS[*]}" "${DEPENDS_ON[*]:-}" \
    "${CONFLICTS_WITH[*]:-}" "${SUPPORTS_USER_HOME}" "${RISK_LEVEL}" \
    "${REBOOT_REQUIRED}" "${INSTALL_TARGET_DEFAULT}" "${TEST_VERIFY_CMD}"

# ── Archetype D data (deployment layout) ─────────────────────────────────────
# Source artifact shipped with the module (carries the issue #277 fixes).
TRASH_MAINT_SRC="${MODULE_DIR:-${BASH_SOURCE[0]%/*}}/config/trash-maintenance/trash-maintenance.sh"
# Where it lands on the host + where cron writes its log.
TRASH_MAINT_BIN="${HOME}/.local/bin/trash-maintenance.sh"
TRASH_MAINT_LOG="${HOME}/.local/state/trash-maintenance.log"
# Cron: a sentinel comment makes the managed line greppable + idempotently
# replaceable without clobbering the user's other crontab entries.
TRASH_MAINT_CRON_MARKER="# init_ubuntu:trash-maintenance"
TRASH_MAINT_CRON_SCHEDULE="0 3 * * *"
# GNOME privacy key this module owns (issue #275).
TRASH_MAINT_GNOME_SCHEMA="org.gnome.desktop.privacy"
TRASH_MAINT_GNOME_KEY="remove-old-trash-files"

# ── Required hooks ───────────────────────────────────────────────────────────
detect() {
    command -v lsb_release >/dev/null 2>&1 \
        && [[ "$(lsb_release -is 2>/dev/null)" == "Ubuntu" ]]
}

# Recommend on hosts that already route `rm` through trash-cli (fish rm.fish)
# and have not deployed it yet. Never re-recommend once installed.
is_recommended() {
    is_installed && return 1
    command -v trash-empty >/dev/null 2>&1
}

# ── Lifecycle ────────────────────────────────────────────────────────────────
# Installed = the artifact is deployed AND the cron entry is present. Both
# checks are read-only.
is_installed() {
    [[ -x "${TRASH_MAINT_BIN}" ]] && _trash_maint_cron_present
}

install() {
    module_dryrun_guard install \
        "deploy ${TRASH_MAINT_BIN} + daily cron (${TRASH_MAINT_CRON_SCHEDULE}) + disable GNOME ${TRASH_MAINT_GNOME_KEY}" \
        && return 0
    module_skip_if_installed && return 0
    _trash_maint_deploy_script || return $?
    _trash_maint_cron_install || return $?
    _trash_maint_disable_gnome_autodelete
    log_info "[${NAME}] installed: script + daily cron + GNOME auto-delete disabled"
}

# upgrade: re-deploy the (possibly updated) artifact and refresh the cron line.
# Idempotent; safe to run before a first install too.
upgrade() {
    module_dryrun_guard upgrade \
        "re-deploy ${TRASH_MAINT_BIN} + refresh cron" \
        && return 0
    _trash_maint_deploy_script || return $?
    _trash_maint_cron_install || return $?
    _trash_maint_disable_gnome_autodelete
}

# remove: unschedule + delete the deployed script; reset the GNOME key back to
# default (undo the install-time disable). The log is kept (remove ≠ purge).
remove() {
    module_dryrun_guard remove \
        "strip cron + rm ${TRASH_MAINT_BIN} + reset GNOME ${TRASH_MAINT_GNOME_KEY}" \
        && return 0
    module_skip_if_not_installed && return 0
    _trash_maint_cron_remove
    rm -f "${TRASH_MAINT_BIN}"
    _trash_maint_reset_gnome_autodelete
    log_info "[${NAME}] removed script + cron (log kept: ${TRASH_MAINT_LOG})"
}

# purge: remove + also wipe the log. Unconditional/idempotent so it also
# cleans a half-installed host.
purge() {
    module_dryrun_guard purge \
        "strip cron + rm ${TRASH_MAINT_BIN} + reset GNOME ${TRASH_MAINT_GNOME_KEY} + rm ${TRASH_MAINT_LOG}" \
        && return 0
    _trash_maint_cron_remove
    rm -f "${TRASH_MAINT_BIN}" "${TRASH_MAINT_LOG}"
    _trash_maint_reset_gnome_autodelete
    log_info "[${NAME}] purged script + cron + log"
}

verify() {
    module_default_verify
}

# module_provided_version: custom modules must publish the Sidecar version
# themselves (no archetype macro to default it).
module_provided_version() {
    printf '%s' "${VERSION_PROVIDED}"
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Deploy the shipped artifact to ~/.local/bin (cp+chmod, NOT coreutils
# `install` — that name collides with the lifecycle function above).
_trash_maint_deploy_script() {
    [[ -f "${TRASH_MAINT_SRC}" ]] || {
        log_error "[${NAME}] shipped script missing: ${TRASH_MAINT_SRC}"
        return 1
    }
    mkdir -p "$(dirname -- "${TRASH_MAINT_BIN}")" \
             "$(dirname -- "${TRASH_MAINT_LOG}")"
    cp -f "${TRASH_MAINT_SRC}" "${TRASH_MAINT_BIN}" || {
        log_error "[${NAME}] failed to deploy script to ${TRASH_MAINT_BIN}"
        return 1
    }
    chmod 0755 "${TRASH_MAINT_BIN}"
}

# True when the managed cron marker is present in the user's crontab.
_trash_maint_cron_present() {
    command -v crontab >/dev/null 2>&1 || return 1
    crontab -l 2>/dev/null | grep -qF "${TRASH_MAINT_CRON_MARKER}"
}

# Install/replace the managed cron line, preserving every other entry.
_trash_maint_cron_install() {
    command -v crontab >/dev/null 2>&1 || {
        log_warn "[${NAME}] crontab not available; skipping schedule (deploy only)"
        return 0
    }
    local _line _keep
    _line="${TRASH_MAINT_CRON_SCHEDULE} ${TRASH_MAINT_BIN} >> ${TRASH_MAINT_LOG} 2>&1 ${TRASH_MAINT_CRON_MARKER}"
    _keep="$(crontab -l 2>/dev/null | grep -vF "${TRASH_MAINT_CRON_MARKER}")" || true
    { [[ -n "${_keep}" ]] && printf '%s\n' "${_keep}"
      printf '%s\n' "${_line}"; } | crontab -
}

# Strip the managed cron line, preserving every other entry.
_trash_maint_cron_remove() {
    command -v crontab >/dev/null 2>&1 || return 0
    local _keep
    _keep="$(crontab -l 2>/dev/null | grep -vF "${TRASH_MAINT_CRON_MARKER}")" || true
    if [[ -n "${_keep}" ]]; then
        printf '%s\n' "${_keep}" | crontab -
    else
        crontab -r 2>/dev/null || true
    fi
}

# gsettings only persists against a real session bus; a headless server or
# container has none, so this is best-effort and never fails the phase.
_trash_maint_gnome_available() {
    command -v gsettings >/dev/null 2>&1 || return 1
    [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] \
        || [[ -n "${DISPLAY:-}" ]] \
        || [[ -n "${WAYLAND_DISPLAY:-}" ]]
}

# issue #275: turn GNOME's own trash auto-delete OFF so this module is the
# single enforcement path for trash retention.
_trash_maint_disable_gnome_autodelete() {
    _trash_maint_gnome_available || {
        log_info "[${NAME}] no desktop session; skipping GNOME ${TRASH_MAINT_GNOME_KEY} toggle"
        return 0
    }
    log_info "[${NAME}] disabling GNOME own trash auto-delete (single source of truth: this module)"
    gsettings set "${TRASH_MAINT_GNOME_SCHEMA}" "${TRASH_MAINT_GNOME_KEY}" false 2>/dev/null \
        || log_warn "[${NAME}] failed to set ${TRASH_MAINT_GNOME_KEY}=false"
}

# remove/purge undo: reset the key to its GNOME default (do not force it back
# to true — resetting cleanly hands ownership back to GNOME).
_trash_maint_reset_gnome_autodelete() {
    _trash_maint_gnome_available || return 0
    gsettings reset "${TRASH_MAINT_GNOME_SCHEMA}" "${TRASH_MAINT_GNOME_KEY}" 2>/dev/null \
        || log_warn "[${NAME}] failed to reset ${TRASH_MAINT_GNOME_KEY}"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
