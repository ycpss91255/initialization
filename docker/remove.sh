#!/usr/bin/env bash

# ${1}: USER NAME. Use the provided USER_NAME, or default to the current user ($USER).
USER_NAME=${1:-"$USER"}

# if (lspci | grep -q VGA ||
#     lspci | grep -iq NVIDIA ||
#     lsmod | grep -q nvidia ||
#     nvidia-smi -L >/dev/null 2>&1 | grep -iq nvidia) &&
#     (command -v nvidia-smi >/dev/null 2>&1); then

# Check for NVIDIA hardware. If present, uninstall the NVIDIA container toolkit.
if dpkg --get-selections | grep -q "nvidia-container-toolkit[[:space:]]*install"; then
    sudo apt purge -y nvidia-container-toolkit

    # remove the NVIDIA container toolkit's GPG key and repository list.
    sudo rm \
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
sudo rm -rf /etc/apt/keyrings/docker.gpg \
    /etc/apt/sources.list.d/docker.list \
    /home/"${USER_NAME}"/.docker

# Delete the Docker group and remove the specified user from it.
sudo groupdel docker
sudo gpasswd -d "${USER_NAME}" docker

# Remove user's Docker configuration directory.
sudo rm -rf /home/"${USER_NAME}"/.docker

# Disable Docker and containerd services.
sudo systemctl disable docker.service
sudo systemctl disable containerd.service
