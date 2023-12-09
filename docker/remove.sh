#!/usr/bin/env bash

# ${1}: USER NAME. Use the provided username, or default to the current user ($USER).
username=${1:-"$USER"}

# Check for NVIDIA hardware. If present, uninstall the NVIDIA container toolkit.
if (lspci | grep -q VGA ||
    lspci | grep -iq NVIDIA ||
    lsmod | grep -q nvidia ||
    nvidia-smi -L >/dev/null 2>&1 | grep -iq nvidia) &&
    (command -v nvidia-smi >/dev/null 2>&1); then
    sudo apt remove -y --purge \
        nvidia-container-toolkit
    sudo rm /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    sudo rm /etc/apt/sources.list.d/nvidia-container-toolkit.list
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
    /home/"${username}"/.docker

# Delete the Docker group and remove the specified user from it.
sudo groupdel docker
sudo gpasswd -d "${username}" docker

# Remove user's Docker configuration directory.
sudo rm -rf /home/"${username}"/.docker

# Disable Docker and containerd services.
sudo systemctl disable docker.service
sudo systemctl disable containerd.service
