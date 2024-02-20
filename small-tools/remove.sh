#!/usr/bin/env bash

# ${1}: USER NAME. Use the provided username, or default to the current user ($USER).

# SCRIPT_PATH=$(dirname "$(readlink -f "${0}")")
USER_NAME=${1:-"$USER"}

# purge 'small tools' related packages
sudo apt purge -y \
    bat \
    bashtop \
    bmon \
    git-lfs \
    htop \
    iftop \
    iotop \
    nmon \
    powertop \
    tig \
    && \
pip uninstall -y \
    bpytop \
    nvitop && \

# purge 'other tools' related packages
sudo apt purge -y \
    curl \
    wget \
    jq \
    tree \
    net-tools \
    nmap \
    neofetch \
    powerstat \
    && \

# purge 'ranger' related packages
sudo apt purge -y \
    ranger \
    && \
# Remove ranger plugins 'ranger_devicons'
sudo rm -rf /home/"${USER_NAME}"/.config/ranger/plugins/ranger_devicons && \

# echo Success or failure message
echo -e "\033[1;37;42mSmall tools purge successfully.\033[0m" || \
echo -e "\033[1;37;41mSmall tools purge failed.\033[0m"
