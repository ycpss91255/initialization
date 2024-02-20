#!/usr/bin/env bash

# ${1}: USER NAME. Use the provided username, or default to the current user ($USER).

# SCRIPT_PATH=$(dirname "$(readlink -f "${0}")")
USER_NAME=${1:-"$USER"}

# Update the package lists
sudo apt update && \

# Install 'small tools' dependencies
sudo apt install -y --no-install-recommends \
    git \
    python3 \
    python3-pip \
    && \
pip install -U pip setuptools && \

# Install required packages for 'monitoring tools'
sudo apt update && \
sudo apt install -y --no-install-recommends \
    bat \
    bashtop \
    bmon \
    btop \
    git-lfs \
    htop \
    iftop \
    iotop \
    nmon \
    powertop \
    tig \
    && \
pip install bpytop \
    git+https://github.com/XuehaiPan/nvitop.git#egg=nvitop && \

# Install required packages for 'other tools'
sudo apt install -y --no-install-recommends \
    curl \
    wget \
    jq \
    tree \
    net-tools \
    nmap \
    neofetch \
    powerstat \
    && \

# Install required packages for 'ranger'
sudo apt install -y --no-install-recommends \
    ranger \
    && \
# delete old ranger_devicons, avoid problems
rm -rf /home/"${USER_NAME}"/.config/ranger/plugins/ranger_devicons && \
# Install ranger plugins 'ranger_devicons'
git clone https://github.com/alexanderjeurissen/ranger_devicons \
        /home/"${USER_NAME}"/.config/ranger/plugins/ranger_devicons && \

# echo Success or failure message
echo -e "\033[1;37;42mSmall tools install successfully.\033[0m" || \
echo -e "\033[1;37;41mSmall tools Install failed.\033[0m"
