#!/usr/bin/env bash

# ${1}: USER NAME. Use the provided USER_NAME, or default to the current user ($USER).
USER_NAME=${1:-"$USER"}

USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6 || true)"
if [[ -z "${USER_HOME}" || ! -d "${USER_HOME}" ]]; then
    echo "User home directory for '${USER_NAME}' not found."
    exit 1
fi


# Disable Docker and containerd services.
sudo systemctl step docker.service containerd.service 2>/dev/null
sudo systemctl disable --now docker.service containerd.service 2>/dev/null

# Check for NVIDIA hardware. If present, uninstall the NVIDIA container toolkit.
if dpkg -l | awk '
    /^ii/ && $2=="nvidia-container-toolkit" {found=1}
    END {exit !found}'; then

    sudo apt purge -y nvidia-container-toolkit
    # remove the NVIDIA container toolkit's GPG key and repository list.
    sudo rm -f \
        /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
        /etc/apt/sources.list.d/nvidia-container-toolkit.list
fi

# Uninstall Docker CE, Docker CE CLI, containerd.io, and related Docker plugins.
sudo apt purge -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# Remove Docker's GPG key, Docker repository list, and clean up Docker directories.
USER_DOCKER_FILE="${USER_HOME}/.docker"

sudo rm -rf /etc/apt/keyrings/docker.gpg \
    /etc/apt/sources.list.d/docker.list \
    "${USER_DOCKER_FILE}"

# Delete the Docker group and remove the specified user from it.
sudo gpasswd -d "${USER_NAME}" docker 2>/dev/null
sudo groupdel docker 2>/dev/null

echo -e "\033[1;37;42mDocker toolkit removal finished.\033[0m\n"
