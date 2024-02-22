#!/usr/bin/env bash

# ${1}: USER NAME. Use the provided username, or default to the current user ($USER).

USER_NAME=${1:-"$USER"}
SCRIPT_PATH=$(dirname "$(readlink -f "${0}")")

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
    openssh-client \
    openssh-server \
    powerstat \
    ranger \
    tig \
    tldr \
    tmux \
    tree \
    ssh \
    sshfs \
    wget \
    zoxide \
    && \

# Create a symbolic link for 'bat', repeated installation may cause problems
sudo ln -s $(which batcat) /usr/bin/bat && \

# tldr update
sudo tldr --update && \

# delete old tmux plugin manager, avoid problems
rm -rf /home/"${USER_NAME}"/.tmux/plugins/tpm && \
# install new plugin manager
git clone --depth 1 \
    https://github.com/tmux-plugins/tpm \
    /home/"${USER_NAME}"/.tmux/plugins/tpm && \
# copy tmux configuration file
cp "${SCRIPT_PATH}"/config/tmux.conf /home/"${USER_NAME}"/.tmux.conf && \
/home/"${USER_NAME}"/.tmux/plugins/tpm/scripts/install_plugins.sh && \

# copy ssh config template to ~/.ssh/config
cp "${SCRIPT_PATH}"/config/ssh_config /home/"${USER_NAME}"/.ssh/config && \
# enable X11Forwarding
sudo sed -i 's/#\s*\(ForwardX11 yes\)/\1/' '/etc/ssh/ssh_config' && \
sudo sed -i -e 's/#\s*\(AllowTcpForwarding yes\)/\1/' \
           -e 's/#\s*\(X11Forwarding yes\)/\1/' \
           -e 's/#\s*\(X11DisplayOffset 10\)/\1/' \
           -e 's/#\s*\(X11UseLocalhost yes\)/\1/' \
           '/etc/ssh/sshd_config' && \
sudo systemctl enable ssh && \
sudo systemctl restart ssh && \

# delete old ranger_devicons, avoid problems
rm -rf /home/"${USER_NAME}"/.config/ranger/plugins/ranger_devicons && \
# Install ranger plugins 'ranger_devicons'
git clone --depth 1 \
    https://github.com/alexanderjeurissen/ranger_devicons \
    /home/"${USER_NAME}"/.config/ranger/plugins/ranger_devicons && \

# print Success or failure message
printf "\033[1;37;42mSmall tools install successfully.\033[0m\n" || \
printf "\033[1;37;41mSmall tools Install failed.\033[0m\n"
