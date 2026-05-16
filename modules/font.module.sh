#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata vars (NAME / DESCRIPTION / CATEGORY / TAGS / ...) consumed by engine post-source — https://www.shellcheck.net/wiki/SC2034
# modules/font.module.sh — Nerd Font (Hack + FiraCode + JetBrainsMono) install

# ── Dual-mode header ────────────────────────────────────────────────────────
MODULE_STANDALONE="true"
[[ "${BASH_SOURCE[0]:-}" != "${0:-}" ]] && MODULE_STANDALONE="false"
if [[ "${MODULE_STANDALONE}" == "true" ]]; then
    set -euo pipefail
    shopt -s inherit_errexit 2>/dev/null || true
    MODULE_DIR="${MODULE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-}")" && pwd -P)}"
    REPO_ROOT="${REPO_ROOT:-$(cd -- "${MODULE_DIR}/.." && pwd -P)}"
    LIB_DIR="${LIB_DIR:-${REPO_ROOT}/lib}"
    # shellcheck disable=SC1091
    source "${LIB_DIR}/logger.sh"
    # shellcheck disable=SC1091
    source "${LIB_DIR}/general.sh"
    # shellcheck disable=SC1091
    source "${LIB_DIR}/module_helper.sh"
fi

# ── Metadata ────────────────────────────────────────────────────────────────
NAME="font"
VERSION_PROVIDED="latest"
CATEGORY="recommended"
TAGS=("font" "nerd-font" "desktop")
HOMEPAGE="https://www.nerdfonts.com/"
declare -gA DESCRIPTION=(
    [en]="Nerd Font collection (Hack, FiraCode, JetBrainsMono)"
    [zh-TW]="Nerd Font 字型組合(Hack / FiraCode / JetBrainsMono)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Set the terminal font to '<family> Nerd Font Mono' to see icons."
    [zh-TW]="請將終端機字型設為「<family> Nerd Font Mono」以正確顯示圖示。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "wsl")
DEPENDS_ON=("apt-essentials")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=true
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="user-home"
TEST_VERIFY_CMD="fc-list | grep -qi 'Nerd Font'"

_NERD_FONT_VERSION="v3.4.0"
_NERD_FONTS=("Hack" "FiraCode" "JetBrainsMono")
_FONTS_DIR="${HOME}/.local/share/fonts"

# ── Lifecycle (hand-written — multiple downloads loop) ──────────────────────
is_installed() {
    local _f
    for _f in "${_NERD_FONTS[@]}"; do
        [[ -d "${_FONTS_DIR}/${_f}" ]] || return 1
    done
    return 0
}

install() {
    module_dryrun_guard install "download Nerd Fonts ${_NERD_FONTS[*]} -> ${_FONTS_DIR}" && return 0
    module_skip_if_installed && return 0

    mkdir -p "${_FONTS_DIR}"
    local _f _url _tmp
    for _f in "${_NERD_FONTS[@]}"; do
        log_info "[${NAME}] download ${_f}"
        _url="https://github.com/ryanoasis/nerd-fonts/releases/download/${_NERD_FONT_VERSION}/${_f}.zip"
        _tmp="$(mktemp -d)"
        if ! curl -fsSL --retry 3 -o "${_tmp}/${_f}.zip" "${_url}"; then
            log_warn "[${NAME}] download failed for ${_f}; skipping"
            rm -rf "${_tmp}"
            continue
        fi
        mkdir -p "${_FONTS_DIR}/${_f}"
        if command -v unzip >/dev/null 2>&1; then
            unzip -qo "${_tmp}/${_f}.zip" -d "${_FONTS_DIR}/${_f}" \
                || log_warn "[${NAME}] unzip failed for ${_f}"
        else
            log_warn "[${NAME}] unzip not installed; cannot extract ${_f}"
        fi
        rm -rf "${_tmp}"
    done
    if command -v fc-cache >/dev/null 2>&1; then
        fc-cache -f "${_FONTS_DIR}" >/dev/null || true
    fi
}

upgrade() {
    module_dryrun_guard upgrade "re-download Nerd Fonts" && return 0
    local _f
    for _f in "${_NERD_FONTS[@]}"; do
        rm -rf "${_FONTS_DIR:?}/${_f}" 2>/dev/null || true
    done
    install
}

remove() {
    module_dryrun_guard remove "rm ${_FONTS_DIR}/{${_NERD_FONTS[*]}}" && return 0
    module_skip_if_not_installed && return 0
    local _f
    for _f in "${_NERD_FONTS[@]}"; do
        rm -rf "${_FONTS_DIR:?}/${_f}"
    done
    if command -v fc-cache >/dev/null 2>&1; then
        fc-cache -f "${_FONTS_DIR}" >/dev/null || true
    fi
}

purge() {
    remove
}

verify() {
    module_default_verify
}

detect() {
    return 0
}
is_recommended() {
    ! is_installed
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
