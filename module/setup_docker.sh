#!/usr/bin/env bash

set -euo pipefail
shopt -s inherit_errexit &>/dev/null || true

MAIN_FILE="true"; [[ "${BASH_SOURCE[0]}" != "${0}" ]] && MAIN_FILE="false"

if [[ "${MAIN_FILE}" == "true" ]]; then
    # shellcheck disable=SC2155
    SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
    export USER="${USER:-"$(whoami)"}"
    export HOME="${HOME:-"/home/${USER}"}"
    export LANGUAGE="C:en"

    # logger.sh variables
    export LOG_LEVEL="INFO"
    export LOG_COLOR="true"

    # sub_func.sh variables
    unset HAVE_SUDO_ACCESS

    # shellcheck disable=SC2155
    # export DATETIME="$(date +"%Y-%m-%d-%T")"
    # export BACKUP_DIR="${HOME}/.backup/${DATETIME}"
    :
fi

# include sub script
# shellcheck disable=SC1091
source "${SCRIPT_PATH}/function/logger.sh"
# shellcheck disable=SC1091
source "${SCRIPT_PATH}/function/general.sh"

# the file used variables
if [[ "${MAIN_FILE}" == "true" ]]; then
    _script_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
else
    _script_path="${SCRIPT_PATH}"
fi

# main script
log_info "Start setup process..."

if ! have_sudo_access; then
    if [[ "${MAIN_FILE}" == "true" ]]; then
        log_fatal "No sudo access. Cannot continue install 'VSCode'."
    else
        log_warn "Skip install 'VSCode' due to no sudo access."
        return 1
    fi
fi

log_info "Removing old Docker packages"
_old_docker_pkgs=(
    "docker.io"
    "docker-doc"
    "docker-compose"
    "docker-compose-v2"
    "podman-docker"
    "containerd"
    "runc"
)
apt_pkg_manager --remove -- "${_old_docker_pkgs[@]}"

log_info "Install Docker dependencies"
_docker_dep_pkgs=(
    "ca-certificates"
    "curl"
    "gnupg"
    "lsb-release"
    "pciutils"
    "kmod"
    "gpg"
)
apt_pkg_manager --install -- "${_docker_dep_pkgs[@]}"

log_info "Create Docker GPG keyring directory and add GPG key"
# # Official practice
# sudo install -m 0755 -d /etc/apt/keyrings
# sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
#     -o /etc/apt/keyrings/docker.asc
# sudo chmod a+r /etc/apt/keyrings/docker.asc

# exec_cmd "curl -fsSL --retry 3 \"https://download.docker.com/linux/ubuntu/gpg\" -o \"docker.asc\""
# exec_cmd "sudo install -D -o root -g root -m 644 \"docker.asc\" \"/etc/apt/keyrings/docker.asc\" && rm -f \"docker.asc\""

# NOTE: test fun
# Download and add the GPG key for the Docker repository
exec_cmd "curl -fsSL --retry 3 \"https://download.docker.com/linux/ubuntu/gpg\" \
    | sudo gpg --dearmor -o \"/usr/share/keyrings/docker.gpg\""

log_info "Install Docker and related packages"
# Add the Docker repository to the system
# shellcheck disable=SC1091
_docker_list="deb [arch=$(dpkg --print-architecture) \
signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$(source /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable"
exec_cmd "echo \"${_docker_list}\" | sudo tee \"/etc/apt/sources.list.d/docker.list\" > /dev/null"

DOCKER_APT_PKGS=(
    "docker-ce"
    "docker-ce-cli"
    "containerd.io"
    "docker-buildx-plugin"
    "docker-compose-plugin"
)
apt_pkg_manager --install -- "${DOCKER_APT_PKGS[@]}"

# Check for NVIDIA hardware and install NVIDIA container toolkit if present
log_info "Check for NVIDIA hardware"
if check_pkg_status --exec -- nvidia-smi; then
    log_info "NVIDIA hardware detected, installing NVIDIA container toolkit"

    curl -fsSL --retry 3 https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

    # Install NVIDIA container toolkit
    log_info "Adding NVIDIA container toolkit GPG key"
    exec_cmd "curl -fsSL --retry 3 \"https://nvidia.github.io/libnvidia-container/gpgkey\" \
    | sudo gpg --dearmor -o \"/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg\""
    exec_cmd "curl -fsSL --retry 3 \
            \"https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list\" | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee \"/etc/apt/sources.list.d/nvidia-container-toolkit.list\"" >/dev/null

    log_info "Installing NVIDIA container toolkit"
    _nvidia_container_toolkit_version="1.17.8-1"
    _nvidia_apt_pkgs=(
        "nvidia-container-toolkit=${_nvidia_container_toolkit_version}"
        "nvidia-container-toolkit-base=${_nvidia_container_toolkit_version}"
        "nvidia-container-tools=${_nvidia_container_toolkit_version}"
        "nvidia-container1=${_nvidia_container_toolkit_version}"
    )
    apt_pkg_manager --install -- "${_nvidia_apt_pkgs[@]}"

    log_info "Configuring NVIDIA container runtime"
    exec_cmd "sudo nvidia-ctk runtime configure --runtime=docker"
else
    log_warn "No NVIDIA hardware detected, skipping NVIDIA container toolkit installation"
fi

log_info "Create Docker group and add user to it"
exec_cmd "getent group docker >/dev/null || sudo groupadd docker"
exec_cmd "sudo usermod -aG docker \"${USER}\""
# newgrp docker

log_info "Set ownership and permissions for Docker related directories"
_docker_conf_file="${HOME}/.docker"
if [[ ! -d "$_docker_conf_file" ]]; then
    log_info "Create Docker config folder: ${_docker_conf_file}"
    mkdir -p -- "${_docker_conf_file}"
fi


exec_cmd "sudo chown -R \"${USER}:${USER}\" \"${_docker_conf_file}\" && \
    sudo chmod -R g+rwx \"${_docker_conf_file}\""

# permission denied '/var/run/docker.sock'
# use 'id -nG' or 'id' to check user group
# use 'newgrp docker' or 'exec su - ${USER}' to re-evaluate the group membership
exec_cmd "sudo chown root:docker \"/var/run/docker.sock\" && \
    sudo chmod 660 \"/var/run/docker.sock\""

log_info "Enable and restart Docker and containerd services"
exec_cmd "sudo systemctl enable --now docker.service containerd.service"
exec_cmd "sudo systemctl restart docker"

log_info "Docker toolkit install finished"
log_info "Log out and log back in so that group membership is re-evaluated. or run 'newgrp docker' command to activate the changes to groups."
