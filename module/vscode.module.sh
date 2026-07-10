#!/usr/bin/env bash
# module/vscode.module.sh — Visual Studio Code editor  [archetype: apt]
#
# Migrated from module/setup_vscode.sh (v1) to the v2 contract
# (doc/module-spec.md) on the apt archetype with a Microsoft vendor repo
# (deb822 source + dearmored keyring, same shape as module/docker.module.sh's
# vendor-repo setup). Demoted from recommended to optional — no longer the
# primary editor (PRD §6.3.3).
#
# Standalone usage:
#   bash module/vscode.module.sh install [--dry-run]
#   bash module/vscode.module.sh upgrade / remove / purge / verify
#   bash module/vscode.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/vscode.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install vscode

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
NAME="vscode"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("editor")
HOMEPAGE="https://code.visualstudio.com/"
declare -gA DESCRIPTION=(
    [en]="Visual Studio Code — Microsoft's GUI code editor (Microsoft apt repo)"
    [zh-TW]="Visual Studio Code — 微軟 GUI 程式碼編輯器(Microsoft apt 套件庫)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Launch with 'code'. Extensions: 'code --install-extension <id>'; sign in to Settings Sync to restore your profile."
    [zh-TW]="以 'code' 啟動。擴充套件:'code --install-extension <id>';登入 Settings Sync 可還原個人設定。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "wsl")
DEPENDS_ON=("curl")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v code && code --version"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt (+ Microsoft vendor repo) ─────────────────────────────
APT_PKGS=("code")
APT_PPA=""
CONFIG_PATHS=("${HOME}/.config/Code" "${HOME}/.vscode")
# Vendor repo: deb822 source (Ubuntu >= 22.04) signed by a dearmored copy of
# https://packages.microsoft.com/keys/microsoft.asc under /etc/apt/keyrings
# (modern keyring dir, mirroring docker.module.sh).
VSCODE_APT_SOURCE="/etc/apt/sources.list.d/vscode.sources"
VSCODE_APT_KEYRING="/etc/apt/keyrings/microsoft.gpg"
VSCODE_APT_KEY_URL="https://packages.microsoft.com/keys/microsoft.asc"
VSCODE_APT_REPO_URL="https://packages.microsoft.com/repos/code"
module_use_apt_archetype

# Override install/upgrade (super-call pattern, archetype-cookbook §A):
# install first wires the Microsoft repo, then chains to the apt default,
# then records the version Sidecar (ADR-0001; module_sidecar_* helpers are
# dry-run-safe, the explicit guard just skips the pointless dpkg-query).
install() {
    module_dryrun_guard install \
        "Microsoft apt repo (${VSCODE_APT_SOURCE}) + apt-install ${APT_PKGS[*]}" \
        && return 0
    module_skip_if_installed && return 0
    _vscode_setup_apt_repo || return 1
    module_default_apt_install
}

# upgrade / remove use the apt archetype defaults; the Sidecar is handled at
# the phase-invocation layer (ADR-0001 refinement). The Microsoft repo files
# survive remove (re-install stays cheap) and are wiped only on purge.
purge() {
    module_dryrun_guard purge \
        "apt-purge ${APT_PKGS[*]} + rm ${VSCODE_APT_SOURCE} ${VSCODE_APT_KEYRING} + CONFIG_PATHS" \
        && return 0
    module_default_apt_purge || return $?
    _vscode_remove_apt_repo
}

detect() {
    command -v apt-get >/dev/null 2>&1
}

is_recommended() {
    ! is_installed
}

# doctor: inherits module_default_doctor (is_installed + TEST_VERIFY_CMD); the
# binary --version runtime probe is shared with verify (TEST_VERIFY_CMD).

# ── Private helpers ─────────────────────────────────────────────────────────

# Wire the Microsoft apt repo: dearmored keyring + deb822 source file
# (install step ref: https://code.visualstudio.com/docs/setup/linux).
_vscode_setup_apt_repo() {
    have_sudo_access 2>/dev/null || {
        log_warn "[${NAME}] no sudo: cannot set up the Microsoft apt repo"
        return 1
    }
    log_info "[${NAME}] adding Microsoft apt key + source"
    # mkdir+chmod instead of `install -d`: this module defines an install()
    # lifecycle function, and `sudo install` would look like passing a shell
    # function to an external command (SC2033).
    sudo mkdir -p "${VSCODE_APT_KEYRING%/*}" || return 1
    sudo chmod 0755 "${VSCODE_APT_KEYRING%/*}"
    if [[ ! -f "${VSCODE_APT_KEYRING}" ]]; then
        curl -fsSL "${VSCODE_APT_KEY_URL}" \
            | sudo gpg --dearmor -o "${VSCODE_APT_KEYRING}" || {
                log_error "[${NAME}] failed to fetch/dearmor ${VSCODE_APT_KEY_URL}"
                return 1
            }
        sudo chmod 0644 "${VSCODE_APT_KEYRING}"
    fi
    printf '%s\n' \
        "Types: deb" \
        "URIs: ${VSCODE_APT_REPO_URL}" \
        "Suites: stable" \
        "Components: main" \
        "Architectures: amd64,arm64,armhf" \
        "Signed-By: ${VSCODE_APT_KEYRING}" \
        | sudo tee "${VSCODE_APT_SOURCE}" > /dev/null
}

# Drop the vendor repo files (purge only).
_vscode_remove_apt_repo() {
    sudo rm -f "${VSCODE_APT_SOURCE}" "${VSCODE_APT_KEYRING}" || true
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
