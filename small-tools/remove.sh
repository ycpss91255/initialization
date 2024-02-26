#!/usr/bin/env bash

# ${1}: USER NAME. Use the provided username, or default to the current user ($USER).

# SCRIPT_PATH=$(dirname "$(readlink -f "${0}")")
USER_NAME=${1:-"$USER"}

# get symbolic link
BAT_FILE=$(readlink -f "/usr/local/bin/bat")
FDFIND_FILE=$(readlink -f "/usr/local/bin/fdfind")j
# remove symbolic link for 'bat'
if [ "${BAT_FILE}" == "/usr/bin/batcat" ]; then
    sudo rm /usr/local/bin/bat
fi
# remove symbolic link for 'fdfind'
if [ "${FDFIND_FILE}" == "/usr/bin/fdfind" ]; then
    sudo rm /usr/local/bin/fdfind
fi

# delete 'fish' configuration file
fish -c "fisher remove \
    IlanCosman/tide@v5 \
    andreiborisov/sponge \
    jorgebucaran/autopair.fish \
    PatrickF1/fzf.fish \
    oh-my-fish/plugin-thefuck \
    edc/bass \
    joseluisq/gitnow@2.11.0 \
    markcial/upto \
    danhper/fish-ssh-agent \
    jorgebucaran/nvm.fish \
    && \
    /home/'${USER_NAME}'/.fzf/uninstall && \
    set -e fish_user_paths" && \
rm -rf /home/"${USER_NAME}"/.config/fish && \
sudo add-apt-repository --remove -y ppa:fish-shell/release-3 && \

# delete 'fzf' configuration file
rm -rf /home/"${USER_NAME}"/.fzf && \

# delete tldr folder
rm -rf /home/"${USER_NAME}"/.local/share/tldr && \

# delete 'tmux' configuration file
rm -rf /home/"${USER_NAME}"/.tmux/plugins/tpm /home/"${USER_NAME}"/.tmux.conf && \

# delete 'ssh' configuration file
rm -f /home/"${USER_NAME}"/.ssh/config && \
# disble X11Forwarding
if [ -f "/etc/ssh/ssh_config" ]; then
    sudo sed -i 's/\s*\(ForwardX11 yes\)/# \1/' '/etc/ssh/ssh_config'
fi
if [ -f "/ect/ssh/sshd_config" ]; then
    sudo sed -i -e 's/\s*\(AllowTcpForwarding yes\)/# \1/' \
        -e 's/#\s*\(X11Forwarding yes\)# \1/' \
        -e 's/#\s*\(X11DisplayOffset 10\)# \1/' \
        -e 's/#\s*\(X11UseLocalhost yes\)# \1/' \
        '/etc/ssh/sshd_config'
fi

# Remove ranger plugins 'ranger_devicons'
rm -rf /home/"${USER_NAME}"/.config/ranger/plugins/ranger_devicons && \

# purge 'small tools' related packages
sudo apt purge -y \
    bashtop \
    bmon \
    htop \
    iftop \
    iotop \
    nmon \
    powertop \
    && \
pip uninstall -y \
    bpytop \
    nvitop && \


# purge 'other tools' related packages
sudo apt purge -y \
    bat \
    fd-find \
    fish \
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
    tmuxinator \
    tree \
    ssh \
    sshfs \
    zoxide \
    && \
pip uninstall -y \
    thefuck \
    && \

# switch default shell to bash
chsh -s "$(which bash)" && \

# print Success or failure message
printf "\033[1;37;42mSmall tools purge successfully.\033[0m\n" || \
printf "\033[1;37;41mSmall tools purge failed.\033[0m\n"
