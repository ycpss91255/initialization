#!/usr/bin/env bash

set -euo pipefail

USER_NAME=${1:-"$USER"}

USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6 || true)"
if [[ -z "${USER_HOME}" || ! -d "${USER_HOME}" ]]; then
    echo "User home directory for '${USER_NAME}' not found."
    exit 1
fi

# Remove any existing Docker installations and related packages
OLD_DOCKER=(
    docker
    docker-engine
    docker.io
    containerd
    runc
)
for pkg in "${OLD_DOCKER[@]}"; do
    if dpkg -l | awk -v f_pkg="$pkg" '
    /^ii/ && $2==f_pkg {found=1}
    END {exit !found}'; then
    sudo apt purge -y purge "$pkg"
    fi
done

# Install required packages for Docker
sudo apt update && \
sudo apt install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    pciutils \
    kmod

# Create a directory for Docker GPG keyring
sudo install -m 0755 -d /etc/apt/keyrings

# Download and add the GPG key for the Docker repository
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg.tmp
sudo mv /etc/apt/keyrings/docker.gpg.tmp /etc/apt/keyrings/docker.gpg

# Add the Docker repository to the system
echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
| sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Set permissions for the Docker GPG keyring
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Install Docker and related packages
sudo apt update && \
sudo apt install -y --no-install-recommends \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# Check for NVIDIA hardware and install NVIDIA container toolkit if present
if command -v nvidia-smi >/dev/null 2>&1; then
    distribution=$(. /etc/os-release;echo "${ID}${VERSION_ID}")

    # Install NVIDIA container toolkit
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    curl -fsSL https://nvidia.github.io/libnvidia-container/"${distribution}"/libnvidia-container.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

    sudo apt update && \
    sudo apt install -y --no-install-recommends \
        nvidia-container-toolkit

    # configure the container runtime
    sudo nvidia-ctk runtime configure --runtime=docker
fi

# Create a Docker group and add the current user to it
if ! getent group docker >/dev/null; then
    sudo groupadd docker
fi

sudo usermod -aG docker "$USER_NAME"

# Set ownership and permissions for Docker related directories
USER_DOCKER_FILE="${USER_HOME}/.docker"

sudo -u "${USER_NAME}" mkdir -p "${USER_DOCKER_FILE}"
sudo chown -R "$USER_NAME:$USER_NAME" "${USER_DOCKER_FILE}"
sudo chmod -R g+rwx "${USER_DOCKER_FILE}"

# Enable and restart Docker and containerd services
sudo systemctl enable --now docker.service containerd.service
sudo systemctl restart docker

# print Success or failure message
echo -e "\033[1;37;42mDocker toolkit install finished.\033[0m\n"
