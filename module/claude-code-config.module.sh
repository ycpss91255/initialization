#!/usr/bin/env bash
# module/claude-code-config.module.sh — personal Claude Code settings drop
#                                       [archetype: config-drop]
#
# Drops the personal Claude Code configuration shipped in
# module/config/claude/ into ~/.claude/:
#   settings.json             main Claude Code settings
#   run-ccstatusline.sh       statusline launcher (executable)
#   settings.statusline.json  statusline-only settings fragment
# and the ccstatusline widget layout into the XDG config path:
#   ${XDG_CONFIG_HOME:-~/.config}/ccstatusline/settings.json
#
# The launcher execs the `ccstatusline` binary (sirmalloc/ccstatusline, a
# global npm CLI); install best-effort provisions it via `npm install -g`
# (#231, also resolves #116). Template-author home paths (/home/<user>) are
# rewritten to the current ${HOME} on drop so the config works on any
# machine/username.
#
# Standalone usage:
#   bash module/claude-code-config.module.sh install [--dry-run]
#   bash module/claude-code-config.module.sh upgrade / remove / purge / verify
#   bash module/claude-code-config.module.sh detect / is-installed /
#        is-recommended / is-outdated / doctor
#   bash module/claude-code-config.module.sh info / status   (read-only)
#
# Engine usage (resolves DEPENDS_ON=claude-code, batches with state.json):
#   setup_ubuntu install claude-code-config

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
NAME="claude-code-config"
VERSION_PROVIDED="1.0"
CATEGORY="optional"
TAGS=("agent" "config" "dotfile")
HOMEPAGE="https://code.claude.com/docs"
declare -gA DESCRIPTION=(
    [en]="Personal Claude Code settings (~/.claude: settings.json + statusline)"
    [zh-TW]="個人 Claude Code 設定(~/.claude:settings.json + statusline)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Restart Claude Code (or start a new session) to pick up ~/.claude/settings.json."
    [zh-TW]="重新啟動 Claude Code(或開新 session)以套用 ~/.claude/settings.json。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl" "container" "vm")
DEPENDS_ON=("claude-code")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=true
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="user-home"
TEST_VERIFY_CMD="[[ -s '${HOME}/.claude/settings.json' && -x '${HOME}/.claude/run-ccstatusline.sh' ]]"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}" "${CONFIG_MODE:-}"

# ── Archetype C — config-drop ────────────────────────────────────────────────
# Primary file for the archetype; the two statusline companions are dropped
# by the install/upgrade overrides below (same lifecycle, one Sidecar).
CONFIG_TEMPLATE_SRC="${MODULE_DIR:-${BASH_SOURCE[0]%/*}}/config/claude/settings.json"
CONFIG_DEST="${HOME}/.claude/settings.json"
# JSON cannot carry '#' comment markers — use a key that already exists in
# the template so the archetype never injects a marker line into JSON.
CONFIG_MARKER='"CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY"'
CONFIG_MODE="644"
module_use_config_archetype

# Files dropped into ~/.claude (basename list; mode handled per-file).
CLAUDE_CONFIG_FILES=("settings.json" "run-ccstatusline.sh" "settings.statusline.json")

# The ccstatusline widget layout is not a ~/.claude file — it lives at the
# tool's XDG config path. Shipped as module/config/claude/ccstatusline.settings.json.
CCSTATUSLINE_TEMPLATE="ccstatusline.settings.json"

# ── Overrides (super-call pattern, archetype-cookbook §C) ────────────────────
# Chain to the config-drop default, then drop the companion files with
# $HOME localization. The Sidecar is written/removed by the phase-invocation
# wrapper around install/upgrade/remove.

install() {
    module_default_config_install || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    _claude_config_drop_files || return $?
    _ccstatusline_ensure_binary
}

upgrade() {
    # backup_file (lib/general.sh) log_fatals when BACKUP_DIR is unset;
    # default the pre-upgrade backup into the state dir so the chained
    # config-drop upgrade can snapshot an existing settings.json.
    local _state_base="${INIT_UBUNTU_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/init_ubuntu}"
    export BACKUP_DIR="${BACKUP_DIR:-${_state_base}/backup/${NAME}}"
    module_default_config_upgrade || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    _claude_config_drop_files || return $?
    _ccstatusline_ensure_binary
}

remove() {
    module_default_config_remove || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    rm -f "${CONFIG_DEST%/*}/run-ccstatusline.sh" \
          "${CONFIG_DEST%/*}/settings.statusline.json" \
          "$(_ccstatusline_xdg_dest)"
}

purge() {
    # A config drop has no split between payload and config: purge == remove.
    module_dryrun_guard purge \
        "rm ${CONFIG_DEST%/*}/{${CLAUDE_CONFIG_FILES[*]}} + $(_ccstatusline_xdg_dest)" \
        && return 0
    remove
}

detect() {
    [[ -n "${HOME:-}" && -d "${HOME}" ]]
}

is_recommended() {
    # Only meaningful once the Claude Code CLI itself is present.
    command -v claude >/dev/null 2>&1 || return 1
    ! is_installed
}

# is_outdated: dest files drifted from the (localized) repo templates.
is_outdated() {
    is_installed || return 1
    local _f _src _dest
    _src="$(_claude_config_src_dir)"
    _dest="${CONFIG_DEST%/*}"
    for _f in "${CLAUDE_CONFIG_FILES[@]}"; do
        [[ -f "${_dest}/${_f}" ]] || return 0
        if ! diff -q <(_claude_config_localize < "${_src}/${_f}") \
                     "${_dest}/${_f}" >/dev/null 2>&1; then
            return 0
        fi
    done
    # The XDG-dropped ccstatusline layout drifts independently of ~/.claude.
    local _xdg; _xdg="$(_ccstatusline_xdg_dest)"
    [[ -f "${_xdg}" ]] || return 0
    diff -q <(_claude_config_localize < "${_src}/${CCSTATUSLINE_TEMPLATE}") \
            "${_xdg}" >/dev/null 2>&1 || return 0
    return 1
}

# doctor: health check — files present, launcher executable + syntactically
# valid.
doctor() {
    if ! is_installed; then
        log_warn "[${NAME}] doctor: ~/.claude/settings.json not managed by init_ubuntu"
        return 1
    fi
    local _launcher="${CONFIG_DEST%/*}/run-ccstatusline.sh"
    if [[ ! -x "${_launcher}" ]]; then
        log_warn "[${NAME}] doctor: ${_launcher} missing or not executable"
        return 1
    fi
    if ! bash -n "${_launcher}" 2>/dev/null; then
        log_warn "[${NAME}] doctor: ${_launcher} has bash syntax errors"
        return 1
    fi
    # Read-only Sidecar advisory: the wrapper writes the Sidecar at the
    # invocation layer; a missing one means an out-of-band install (warn only).
    module_sidecar_get_version "${NAME}" >/dev/null 2>&1 \
        || log_warn "[${NAME}] doctor: sidecar missing (installed outside init_ubuntu?)"
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────

_claude_config_src_dir() {
    printf '%s/config/claude' "${MODULE_DIR:-${BASH_SOURCE[0]%/*}}"
}

# Rewrite template-author home prefixes (/home/<user>) to the current $HOME
# so absolute paths inside the settings work on any machine. Stream filter.
_claude_config_localize() {
    sed -E "s#/home/[A-Za-z0-9._-]+#${HOME}#g"
}

# Absolute path to the ccstatusline widget-layout config (XDG, not ~/.claude).
_ccstatusline_xdg_dest() {
    printf '%s/ccstatusline/settings.json' "${XDG_CONFIG_HOME:-${HOME}/.config}"
}

# Drop all CLAUDE_CONFIG_FILES into ~/.claude plus the ccstatusline layout
# into its XDG config path, localized; launcher is 755, JSON files 644.
# Idempotent: re-dropping converges to the same content.
_claude_config_drop_files() {
    local _src _dest _f
    _src="$(_claude_config_src_dir)"
    _dest="${CONFIG_DEST%/*}"
    mkdir -p "${_dest}" || return 1
    for _f in "${CLAUDE_CONFIG_FILES[@]}"; do
        if [[ ! -f "${_src}/${_f}" ]]; then
            log_warn "[${NAME}] template missing: ${_src}/${_f}"
            return 1
        fi
        _claude_config_localize < "${_src}/${_f}" > "${_dest}/${_f}" || return 1
        if [[ "${_f}" == *.sh ]]; then
            chmod 755 "${_dest}/${_f}"
        else
            chmod 644 "${_dest}/${_f}"
        fi
    done
    # ccstatusline reads its layout from the XDG config path, not ~/.claude.
    if [[ ! -f "${_src}/${CCSTATUSLINE_TEMPLATE}" ]]; then
        log_warn "[${NAME}] template missing: ${_src}/${CCSTATUSLINE_TEMPLATE}"
        return 1
    fi
    local _xdg; _xdg="$(_ccstatusline_xdg_dest)"
    mkdir -p "${_xdg%/*}" || return 1
    _claude_config_localize < "${_src}/${CCSTATUSLINE_TEMPLATE}" > "${_xdg}" || return 1
    chmod 644 "${_xdg}"
    log_info "[${NAME}] dropped ${#CLAUDE_CONFIG_FILES[@]} files -> ${_dest}, layout -> ${_xdg}"
}

# Best-effort provisioning of the `ccstatusline` binary the launcher execs
# (issue #231: "global binary + XDG config"). Non-fatal: the config drop still
# succeeds if the binary can't be installed here — the user can run
# `npm install -g ccstatusline` later. Skipped entirely in the test harness
# (INIT_UBUNTU_STATUSLINE_NO_BINARY) so no host package install runs under CI.
_ccstatusline_ensure_binary() {
    [[ "${INIT_UBUNTU_STATUSLINE_NO_BINARY:-false}" == "true" ]] && return 0
    command -v ccstatusline >/dev/null 2>&1 && return 0
    if command -v npm >/dev/null 2>&1; then
        log_info "[${NAME}] provisioning statusline binary: npm install -g ccstatusline"
        npm install -g ccstatusline >/dev/null 2>&1 \
            || log_warn "[${NAME}] 'npm install -g ccstatusline' failed; install it manually"
    else
        log_warn "[${NAME}] npm not found; install the statusline binary with 'npm install -g ccstatusline'"
    fi
    return 0
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
