#!/usr/bin/env bash

# ${1}: USER NAME. Use the provided username, or default to the current user ($USER).

# SCRIPT_PATH=$(dirname "$(readlink -f "${0}")")
USER_NAME=${1:-"$USER"}

# Update the package lists
sudo apt update && \

# Install small tools dependencies
sudo apt install -y --no-install-recommends \
    curl \
    git \
    python3 \
    python3-pip \
    && \
pip install -U pip && \

# Install required packages for 'monitoring tools'
sudo apt install -y --no-install-recommends \
    bat \
    bashtop \
    bmon \
    docker-ctop \
    htop \
    iftop \
    iotop \
    nmon \
    powertop \
    && \
pip install bpytop \
    git+https://github.com/XuehaiPan/nvitop.git#egg=nvitop && \
# echo Success or failure message
echo -e "\033[1;37;42mMonitoring tools install successfully.\033[0m" || \
echo -e "\033[1;37;41mSmall tools Install failed.\033[0m"

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
    ranger && \
git clone https://github.com/alexanderjeurissen/ranger_devicons \
        /home/"${USER_NAME}"/.config/ranger/plugins/ranger_devicons && \

# echo Success or failure message
echo -e "\033[1;37;42mSmall tools install successfully.\033[0m" || \
echo -e "\033[1;37;41mSmall tools Install failed.\033[0m"
