#!/usr/bin/env bash
# modules/docker.module.sh — Docker Engine + Compose plugin
#
# Reference module per docs/module-spec.md. Docker's apt setup needs custom
# repo keys + sources.list.d entry, so we DON'T use module_use_apt_archetype;
# we hand-write install/remove/purge but reuse module_default_apt_is_installed
# + module_default_verify.

# ── Dual-mode header ────────────────────────────────────────────────────────
MODULE_STANDALONE="true"
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && MODULE_STANDALONE="false"
if [[ "${MODULE_STANDALONE}" == "true" ]]; then
    set -euo pipefail
    shopt -s inherit_errexit 2>/dev/null || true
    MODULE_DIR="${MODULE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)}"
    REPO_ROOT="${REPO_ROOT:-$(cd -- "${MODULE_DIR}/.." && pwd -P)}"
    LIB_DIR="${LIB_DIR:-${REPO_ROOT}/lib}"
    # shellcheck disable=SC1091
    source "${LIB_DIR}/logger.sh"
    # shellcheck disable=SC1091
    source "${LIB_DIR}/general.sh"
    # shellcheck disable=SC1091
    source "${LIB_DIR}/module_helper.sh"
fi

# ── Metadata (docs/module-spec.md §3) ───────────────────────────────────────
NAME="docker"
VERSION_PROVIDED="apt-managed"
CATEGORY="recommended"
TAGS=("container" "devops")
HOMEPAGE="https://docs.docker.com/engine/"
declare -gA DESCRIPTION=(
    [en]="Docker Engine + Compose plugin"
    [zh-TW]="Docker 容器引擎 + Compose 外掛"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Run 'newgrp docker' or re-login to use docker without sudo."
    [zh-TW]="執行 'newgrp docker' 或重新登入以免 sudo 使用 docker。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=("apt-essentials")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v docker && docker --version"

APT_PKGS=(
    "docker-ce"
    "docker-ce-cli"
    "containerd.io"
    "docker-buildx-plugin"
    "docker-compose-plugin"
)
CONFIG_PATHS=(
    "/var/lib/docker"
    "/etc/docker"
    "${HOME}/.docker"
)

# ── Lifecycle ───────────────────────────────────────────────────────────────
# is_installed reuses helper; install/remove/purge are custom because the apt
# repo setup is non-trivial.

is_installed() {
    dpkg -l docker-ce 2>/dev/null | grep -q '^ii'
}

detect() {
    command -v lsb_release >/dev/null 2>&1 && \
        [[ "$(lsb_release -is 2>/dev/null)" == "Ubuntu" ]]
}

is_recommended() {
    is_installed && return 1
    if command -v systemd-detect-virt >/dev/null 2>&1 \
        && systemd-detect-virt --container --quiet 2>/dev/null; then
        return 1
    fi
    return 0
}

# shellcheck disable=SC2032,SC2033
# SC2032/SC2033: `install` shadows the system binary; inside this function
#   `sudo install -m 0755 -d ...` runs /usr/bin/install (sudo clears the
#   function table before exec), so the shadowing is harmless here.
install() {
    module_dryrun_guard install "apt-repo setup + apt-install ${APT_PKGS[*]} + usermod -aG docker" && return 0
    module_skip_if_installed && return 0

    have_sudo_access 2>/dev/null \
        || { log_error "[${NAME}] sudo required for docker install"; return 1; }

    log_info "[${NAME}] adding apt key + source"
    sudo install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod 0644 /etc/apt/keyrings/docker.gpg
    fi

    local _codename
    _codename="$(lsb_release -cs 2>/dev/null || echo "")"
    if [[ -z "${_codename}" ]]; then
        log_error "[${NAME}] could not detect Ubuntu codename via lsb_release -cs"
        return 1
    fi

    printf "deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n" \
        "$(dpkg --print-architecture)" "${_codename}" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    log_info "[${NAME}] apt-get update + install ${APT_PKGS[*]}"
    sudo apt-get update
    sudo apt-get install -y "${APT_PKGS[@]}"

    log_info "[${NAME}] adding ${USER} to docker group"
    sudo usermod -aG docker "${USER}"
}

upgrade() {
    module_dryrun_guard upgrade "apt-get install --only-upgrade ${APT_PKGS[*]}" && return 0
    if ! is_installed; then
        log_info "[${NAME}] not installed yet — running install instead"
        install
        return $?
    fi
    have_sudo_access 2>/dev/null || { log_error "[${NAME}] sudo required"; return 1; }
    sudo apt-get update -qq || log_warn "[${NAME}] apt-get update failed (continuing)"
    sudo apt-get install --only-upgrade -y "${APT_PKGS[@]}"
}

remove() {
    module_dryrun_guard remove "apt-remove ${APT_PKGS[*]}" && return 0
    module_skip_if_not_installed && return 0
    log_info "[${NAME}] apt-get remove ${APT_PKGS[*]}"
    sudo apt-get remove -y "${APT_PKGS[@]}" || true
}

purge() {
    module_dryrun_guard purge "apt-purge + wipe ${CONFIG_PATHS[*]} + apt sources" && return 0
    log_info "[${NAME}] apt-get purge ${APT_PKGS[*]}"
    sudo apt-get purge -y "${APT_PKGS[@]}" 2>/dev/null || true

    log_info "[${NAME}] removing config paths: ${CONFIG_PATHS[*]}"
    local _p
    for _p in "${CONFIG_PATHS[@]}"; do
        if [[ "${_p}" == "${HOME}/"* ]]; then
            rm -rf "${_p}"
        else
            sudo rm -rf "${_p}"
        fi
    done

    sudo rm -f /etc/apt/sources.list.d/docker.list
    sudo rm -f /etc/apt/keyrings/docker.gpg
}

verify() {
    module_default_verify
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
