#!/usr/bin/env bash

# Remove any existing Docker installations and related packages
sudo apt purge -y --purge \
    docker \
    docker-engine \
    docker.io \
    containerd \
    runc

# Update the package lists
sudo apt update && \

# Install required packages for Docker
sudo apt install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    pciutils \
    kmod && \

# Create a directory for Docker GPG keyring
sudo install -m 0755 -d /etc/apt/keyrings && \

# Download and add the GPG key for the Docker repository
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg.tmp && \
sudo mv /etc/apt/keyrings/docker.gpg.tmp /etc/apt/keyrings/docker.gpg && \

# Add the Docker repository to the system
echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null && \

# Set permissions for the Docker GPG keyring
sudo chmod a+r /etc/apt/keyrings/docker.gpg && \

# Update the package lists to include Docker repository
sudo apt update && \

# Install Docker and related packages
sudo apt install -y --no-install-recommends \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin && \

# Check for NVIDIA hardware and install NVIDIA container toolkit if present
if (lspci | grep -q VGA ||
    lspci | grep -iq NVIDIA ||
    lsmod | grep -q nvidia ||
    nvidia-smi -L >/dev/null 2>&1 | grep -iq nvidia) &&
    (command -v nvidia-smi >/dev/null 2>&1); then

    # Install NVIDIA container toolkit
    distribution=$(. /etc/os-release;echo "${ID}${VERSION_ID}") && \
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | sudo gpg --dearmor -o \
            /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg && \
    curl -s -L https://nvidia.github.io/libnvidia-container/"${distribution}"/libnvidia-container.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list && \
    sudo apt update && \
    sudo apt install -y --no-install-recommends \
        nvidia-container-toolkit && \

    # configure the container runtime
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker

fi && \

# Create a Docker group and add the current user to it
sudo groupadd docker
sudo usermod -aG docker "$USER" && \

# Change to the new group without logging out and in
newgrp docker && \

# Set ownership and permissions for Docker related directories
sudo chown "$USER:$USER" /home/"${USER}"/.docker -R && \
sudo chmod g+rwx "/home/${USER}/.docker" -R && \

# Enable and start Docker and containerd services
sudo systemctl enable docker.service && \
sudo systemctl enable containerd.service && \
sudo systemctl enable docker
