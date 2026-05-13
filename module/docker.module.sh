#!/usr/bin/env bash
# module/docker.module.sh — Docker Engine + Compose plugin
#
# First reference module (Phase 2 batch B). Follows docs/module-spec.md
# verbatim so it doubles as a working contract example.
#
# Lineage: succeeds module/setup_docker.sh, which stays on disk until
# Phase 7 (module migration) removes legacy script orchestrators.

# Note: no top-level `set -e`. runner.sh sources us inside a sub-shell that
# already declares `set -euo pipefail`, so we inherit. Setting it here too
# would be harmless but redundant.

# ===========================================================
# Metadata (docs/module-spec.md §3)
# ===========================================================

NAME="docker"
VERSION_PROVIDED="apt-managed"
DESCRIPTION_EN="Docker Engine + Compose plugin"
DESCRIPTION_ZH_TW="Docker 容器引擎 + Compose 外掛"
CATEGORY="recommended"
TAGS=("container" "devops")
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=("apt-essentials")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
PARALLEL_GROUP="apt"
HOMEPAGE="https://docs.docker.com/engine/"

# ===========================================================
# Lifecycle (docs/module-spec.md §4)
# ===========================================================

detect() {
    command -v lsb_release >/dev/null 2>&1 && \
        [[ "$(lsb_release -is 2>/dev/null)" == "Ubuntu" ]]
}

is_recommended() {
    if is_installed; then
        return 1
    fi
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        if systemd-detect-virt --container --quiet 2>/dev/null; then
            return 1
        fi
    fi
    return 0
}

is_installed() {
    dpkg -l docker-ce 2>/dev/null | grep -q '^ii'
}

install() {
    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        log_info "[docker] [DRY-RUN] would set up apt repo and install docker-ce + plugins"
        log_info "[docker] [DRY-RUN] would add ${USER} to docker group"
        return 0
    fi

    if is_installed; then
        log_info "[docker] already installed; skipping"
        return 0
    fi

    log_info "[docker] adding apt key + source"
    sudo install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod 0644 /etc/apt/keyrings/docker.gpg
    fi

    local _codename
    _codename="$(lsb_release -cs 2>/dev/null || echo "")"
    if [[ -z "${_codename}" ]]; then
        log_error "[docker] could not detect Ubuntu codename via lsb_release -cs"
        return 1
    fi

    printf "deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n" \
        "$(dpkg --print-architecture)" "${_codename}" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    log_info "[docker] apt-get update + install docker-ce ..."
    sudo apt-get update
    sudo apt-get install -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    log_info "[docker] adding ${USER} to docker group (re-login required)"
    sudo usermod -aG docker "${USER}"

    log_warn "[docker] Installed. Run 'newgrp docker' or re-login to use docker without sudo."
}

remove() {
    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        log_info "[docker] [DRY-RUN] would apt-get remove docker-ce + plugins"
        return 0
    fi

    if ! is_installed; then
        log_info "[docker] not installed; nothing to remove"
        return 0
    fi

    log_info "[docker] apt-get remove docker-ce + plugins"
    sudo apt-get remove -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin || true
}

purge() {
    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        log_info "[docker] [DRY-RUN] would purge docker-ce + wipe /var/lib/docker /etc/docker ~/.docker"
        return 0
    fi

    log_info "[docker] apt-get purge docker-ce + plugins"
    sudo apt-get purge -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin || true

    log_info "[docker] removing /var/lib/docker, /etc/docker, ~/.docker"
    sudo rm -rf /var/lib/docker /etc/docker
    rm -rf "${HOME}/.docker"

    # Drop apt source so a re-install does a fresh repo setup.
    sudo rm -f /etc/apt/sources.list.d/docker.list
    sudo rm -f /etc/apt/keyrings/docker.gpg
}
