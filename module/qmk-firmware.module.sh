#!/usr/bin/env bash
# module/qmk-firmware.module.sh — QMK firmware dev environment  [archetype: custom]
#
# Migrated from module/setup_qmk_firmware.sh (v1 curl|sh sketch) to the v2
# contract (doc/module-spec.md). Custom archetype (cookbook §D): the install
# is apt prereqs + pipx-installed QMK CLI + `qmk setup` (clones qmk_firmware
# and installs the toolchain) + personal keymap overlay, so none of the
# apt / github-release / config macros fit.
#
# Per ADR-0026, build-essential is now its own base module, so DEPENDS_ON
# carries it directly (alongside git). install() still re-lists build-essential
# in _QMK_APT_PREREQS because standalone mode does not resolve DEPENDS_ON.
#
# Standalone usage:
#   bash module/qmk-firmware.module.sh install [--dry-run]
#   bash module/qmk-firmware.module.sh upgrade / remove / purge / verify
#   bash module/qmk-firmware.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/qmk-firmware.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install qmk-firmware

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
NAME="qmk-firmware"
VERSION_PROVIDED="pipx-managed"
CATEGORY="optional"
TAGS=("hardware")
HOMEPAGE="https://qmk.fm"
declare -gA DESCRIPTION=(
    [en]="QMK firmware dev environment — qmk CLI (pipx) + toolchain + qmk_firmware checkout"
    [zh-TW]="QMK 鍵盤韌體開發環境 — qmk CLI(pipx)+ 工具鏈 + qmk_firmware 原始碼"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="'qmk setup' cloned ${HOME}/qmk_firmware. Set your board with 'qmk config user.keyboard=<kb> user.keymap=<km>', then 'qmk compile' / 'qmk flash'."
    [zh-TW]="'qmk setup' 已複製 ${HOME}/qmk_firmware。先用 'qmk config user.keyboard=<kb> user.keymap=<km>' 設定鍵盤,再 'qmk compile' / 'qmk flash'。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "vm")
DEPENDS_ON=("git" "build-essential")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v qmk && qmk --version"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype D — custom data ───────────────────────────────────────────────
# build-essential is deliberately repeated here even though it is a
# DEPENDS_ON module (ADR-0026): standalone mode does not resolve DEPENDS_ON,
# and the QMK toolchain cannot compile without it.
_QMK_APT_PREREQS=("git" "python3" "python3-pip" "pipx" "build-essential")
_QMK_HOME="${QMK_HOME:-${HOME}/qmk_firmware}"
_QMK_KEYMAP_SRC="${MODULE_DIR:-${BASH_SOURCE[0]%/*}}/config/qmk_firmware/keyboards"
CONFIG_PATHS=(
    "${HOME}/.config/qmk"
    "${_QMK_HOME}"
)

# ── Lifecycle ───────────────────────────────────────────────────────────────

is_installed() {
    command -v qmk >/dev/null 2>&1
}

detect() {
    command -v apt-get >/dev/null 2>&1
}

is_recommended() {
    # Niche hardware tool (QMK keyboard owners only) — never auto-recommended.
    # Opt in via config: [modules.qmk-firmware] enabled = true (PRD §11).
    return 1
}

install() {
    module_dryrun_guard install \
        "apt prereqs (${_QMK_APT_PREREQS[*]}) + pipx install qmk + qmk setup -y -> ${_QMK_HOME} + keymap overlay" \
        && return 0
    module_skip_if_installed && return 0

    _qmk_apt_prereqs || return 1
    _qmk_pipx_install || return 1
    _qmk_setup || return 1
    _qmk_deploy_keymaps || log_warn "[${NAME}] keymap overlay failed (continuing)"
    module_sidecar_write "${NAME}" "$(_qmk_installed_version)"
}

upgrade() {
    module_dryrun_guard upgrade "pipx upgrade qmk + refresh keymap overlay + sidecar" && return 0
    if ! is_installed; then
        log_info "[${NAME}] not installed yet — running install instead"
        install
        return $?
    fi
    _qmk_pipx_upgrade || return 1
    _qmk_deploy_keymaps || log_warn "[${NAME}] keymap overlay failed (continuing)"
    module_sidecar_write "${NAME}" "$(_qmk_installed_version)"
}

remove() {
    module_dryrun_guard remove "pipx uninstall qmk" && return 0
    if ! module_skip_if_not_installed; then
        _qmk_pipx_uninstall \
            || log_warn "[${NAME}] pipx uninstall qmk failed (continuing)"
    fi
    module_sidecar_remove "${NAME}"
}

purge() {
    module_dryrun_guard purge "pipx uninstall qmk + rm ${CONFIG_PATHS[*]}" && return 0
    if ! module_skip_if_not_installed; then
        _qmk_pipx_uninstall \
            || log_warn "[${NAME}] pipx uninstall qmk failed (continuing)"
    fi
    log_info "[${NAME}] removing config paths: ${CONFIG_PATHS[*]}"
    local _p
    for _p in "${CONFIG_PATHS[@]:-}"; do
        [[ -n "${_p}" ]] || continue
        rm -rf "${_p}"
    done
    module_sidecar_remove "${NAME}"
}

verify() {
    module_default_verify
}

# is_outdated: compare the qmk CLI's reported version against the latest
# release on PyPI (the pipx upstream). Network-dependent; degrades to
# "not outdated" when either side cannot be determined.
is_outdated() {
    is_installed || return 1
    local _local="" _remote=""
    _local="$(_qmk_cli_version)" || _local=""
    _remote="$(_qmk_latest_pypi_version)" || _remote=""
    [[ -n "${_local}" && -n "${_remote}" && "${_local}" != "${_remote}" ]]
}

# doctor: health check — CLI present + runnable, qmk_firmware checkout and
# Sidecar advisory (warn-only, ADR-0001 drift is healable via install).
doctor() {
    if ! is_installed; then
        log_warn "[${NAME}] doctor: qmk CLI is not installed"
        return 1
    fi
    local _bin
    _bin="$(command -v qmk 2>/dev/null)" || {
        log_warn "[${NAME}] doctor: qmk binary not found on PATH"
        return 1
    }
    if ! "${_bin}" --version >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: ${_bin} --version failed"
        return 1
    fi
    [[ -d "${_QMK_HOME}" ]] \
        || log_warn "[${NAME}] doctor: ${_QMK_HOME} missing — run 'qmk setup -y'"
    module_sidecar_get_version "${NAME}" >/dev/null 2>&1 \
        || log_warn "[${NAME}] doctor: sidecar missing (installed outside init_ubuntu?)"
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Apt-level prerequisites (compiler + python + pipx). Q39: build-essential
# is ensured here because standalone mode never resolves DEPENDS_ON.
_qmk_apt_prereqs() {
    if ! have_sudo_access 2>/dev/null; then
        log_warn "[${NAME}] no sudo: please install manually: ${_QMK_APT_PREREQS[*]}"
        return 1
    fi
    log_info "[${NAME}] apt prereqs: ${_QMK_APT_PREREQS[*]}"
    sudo apt-get update -qq || log_warn "[${NAME}] apt-get update failed (continuing)"
    sudo apt-get install -y --no-install-recommends "${_QMK_APT_PREREQS[@]}"
}

_qmk_pipx_install() {
    log_info "[${NAME}] pipx install qmk"
    pipx install qmk || return 1
    pipx ensurepath >/dev/null 2>&1 || true
}

_qmk_pipx_upgrade() {
    log_info "[${NAME}] pipx upgrade qmk"
    pipx upgrade qmk
}

_qmk_pipx_uninstall() {
    log_info "[${NAME}] pipx uninstall qmk"
    pipx uninstall qmk
}

# `qmk setup` clones qmk_firmware + submodules and installs build deps.
# pipx drops the binary into ~/.local/bin which may not be on PATH yet
# in this same shell, so resolve via _qmk_bin_path.
_qmk_setup() {
    local _bin
    _bin="$(_qmk_bin_path)" || {
        log_error "[${NAME}] qmk CLI not found after pipx install"
        return 1
    }
    log_info "[${NAME}] qmk setup -y (clones ${_QMK_HOME})"
    "${_bin}" setup -y -H "${_QMK_HOME}"
}

# Overlay personal keymaps shipped in module/config/qmk_firmware/keyboards
# (e.g. boardsource/unicorne cyc_keymap) onto the qmk_firmware checkout.
# No-op when either side is missing (fresh machine, no checkout yet).
_qmk_deploy_keymaps() {
    [[ -d "${_QMK_KEYMAP_SRC}" ]] || return 0
    [[ -d "${_QMK_HOME}/keyboards" ]] || return 0
    log_info "[${NAME}] overlaying personal keymaps -> ${_QMK_HOME}/keyboards"
    cp -r "${_QMK_KEYMAP_SRC}/." "${_QMK_HOME}/keyboards/"
}

_qmk_bin_path() {
    command -v qmk 2>/dev/null && return 0
    if [[ -x "${HOME}/.local/bin/qmk" ]]; then
        printf '%s' "${HOME}/.local/bin/qmk"
        return 0
    fi
    return 1
}

# Raw CLI-reported version (e.g. "1.1.5"); exit 1 when undeterminable.
_qmk_cli_version() {
    local _bin _ver=""
    _bin="$(_qmk_bin_path)" || return 1
    _ver="$("${_bin}" --version 2>/dev/null | head -n1 | tr -d '[:space:]')" || _ver=""
    [[ -n "${_ver}" ]] || return 1
    printf '%s' "${_ver}"
}

# Version string for the Sidecar: CLI-reported version, falling back to
# the literal "pipx-managed" when the CLI has no answer.
_qmk_installed_version() {
    local _ver=""
    _ver="$(_qmk_cli_version)" || _ver=""
    printf '%s' "${_ver:-pipx-managed}"
}

# Latest qmk release on PyPI (pipx upstream); exit 1 on network failure.
_qmk_latest_pypi_version() {
    local _json=""
    _json="$(curl -fsSL --retry 2 --max-time 10 \
        "https://pypi.org/pypi/qmk/json" 2>/dev/null)" || return 1
    printf '%s' "${_json}" \
        | grep -o '"version":[[:space:]]*"[^"]*"' | head -n1 | cut -d'"' -f4
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
