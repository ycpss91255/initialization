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
    bashtop \
    bmon \
    htop \
    iftop \
    iotop \
    nmon \
    powertop \
    && \
pip install \
    bpytop \
    && \

# Install required packages for 'other tools'
sudo apt install -y --no-install-recommends \
    bat \
    curl \
    git-lfs \
    jq \
    neofetch \
    net-tools \
    nmap \
    powerstat \
    ranger \
    tig \
    tldr \
    tree \
    wget \
    zoxide \
    && \
# Create a symbolic link for 'bat', repeated installation may cause problems
sudo ln -s $(which batcat) /usr/bin/bat && \
# tldr update
sudo tldr --update && \
# delete old ranger_devicons, avoid problems
rm -rf /home/"${USER_NAME}"/.config/ranger/plugins/ranger_devicons && \
# Install ranger plugins 'ranger_devicons'
git clone https://github.com/alexanderjeurissen/ranger_devicons \
        /home/"${USER_NAME}"/.config/ranger/plugins/ranger_devicons && \

# echo Success or failure message
echo -e "\033[1;37;42mSmall tools install successfully.\033[0m" || \
echo -e "\033[1;37;41mSmall tools Install failed.\033[0m"
