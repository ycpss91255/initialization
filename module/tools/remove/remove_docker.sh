#!/usr/bin/env bash

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_PATH}/../general/sub_func.sh"

# ${1}: USER NAME. Use the provided USER_NAME, or default to the current user ($USER).
USER_NAME=$(get_user_name "${1:-}")
USER_HOME=$(get_user_home "$USER_NAME")

echo "==> Stopping and disabling Docker and containerd services"
sudo systemctl stop docker.service containerd.service 2>/dev/null
sudo systemctl disable --now docker.service containerd.service 2/dev/null

# Check for NVIDIA hardware. If present, uninstall the NVIDIA container toolkit.
echo "==> Checking for NVIDIA hardware"
if check_pkg_status --exec -- nvidia-smi; then
    echo "==> NVIDIA hardware detected, uninstalling NVIDIA container toolkit"
    NVIDIA_APT_PKGS=(
        nvidia-container-toolkit
        nvidia-container-toolkit-base
        nvidia-container-tools
        nvidia-container1
    )
    apt_pkg_manager --remove -- "${NVIDIA_APT_PKGS[@]}"

    # remove the NVIDIA container toolkit's GPG key and repository list.
    sudo rm -f \
        /etc/apt/sources.list.d/nvidia-container-toolkit.list \
        /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
else
    echo "==> No NVIDIA hardware detected, skipping NVIDIA container toolkit removal"
fi

echo "==> Uninstalling Docker and related packages"
DOCKER_APT_PKGS=(
    docker-ce
    docker-ce-cli
    containerd.io
    docker-buildx-plugin
    docker-compose-plugin
    docker-ce-rootless-extras
)
apt_pkg_manager --purge -- "${DOCKER_APT_PKGS[@]}"

echo "==> Removing Docker's GPG key and repository list"
USER_DOCKER_FILE="${USER_HOME}/.docker"
[[ -d "${USER_DOCKER_FILE}" ]] && { sudo rm -rf "${USER_DOCKER_FILE}"; }

sudo rm -rf /etc/apt/keyrings/docker.gpg \
    /etc/apt/sources.list.d/docker.list

echo "==> Removing Docker's data"
sudo rm -rf /var/lib/docker /var/lib/containerd

echo "==> Deleting Docker group and removing user from it"
sudo gpasswd -d "${USER_NAME}" docker 2>/dev/null
sudo groupdel docker 2>/dev/null

green_echo "Docker toolkit removal finished."
