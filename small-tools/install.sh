#!/usr/bin/env bash

# ${1}: USER NAME. Use the provided username, or default to the current user ($USER).
# TODO: install eza
# BUG: "snap" not found (wsl)

USER_NAME=${1:-"$USER"}
SCRIPT_PATH=$(dirname "$(readlink -f "${0}")")

# delete old tldr folder or unknown file, avoid problems
if [ -n "/home/${USER_NAME}/.local/share/tldr" ]; then
    rm -rf /home/"${USER_NAME}"/.local/share/tldr
fi

if [ -z "/home/"${USER_NAME}"/.local/share" ]; then
    mkdir -p /home/"${USER_NAME}"/.local/share
fi

if [ -z "/home/"${USER_NAME}"/.config/fish" ]; then
    mkdir -p /home/"${USER_NAME}"/.config/fish
fi

if [ -n "/home/"${USER_NAME}"/.fzf" ]; then
    rm -rf /home/"${USER_NAME}"/.fzf
fi

# add apt repository for 'fish'
sudo apt-add-repository -y ppa:fish-shell/release-3 && \

# Update the package lists
sudo apt update && \

# Install 'small tools' dependencies
sudo apt install -y --no-install-recommends \
    curl \
    git \
    python3 \
    python3-dev \
    python3-pip \
    python3-setuptools \
    snapd \
    software-properties-common \
    wget \
    xclip \
    xsel \
    && \

# ubuntu 24.04 install error, error: externally-managed-environment
# pip install -U pip setuptools && \

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
    bpytop \
    && \

# ubuntu 24.04 install error, error: externally-managed-environment
# pip install -U \
#     bypytop \
#     && \

# Install required packages for 'other tools'
sudo apt install -y --no-install-recommends \
    asciidoctor \
    apt-file \
    bat \
    fd-find \
    fish \
    git-lfs \
    jq \
    ncdu \
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
    tmuxp \
    tree \
    silversearcher-ag \
    ssh \
    sshfs \
    xdg-utils \
    zoxide \
    thefuck \
    gpustat \
    && \

# ubuntu 24.04 install error, error: externally-managed-environment
# pip install -U \
#     thefuck \
#     gpustat \
#     && \

sudo apt-file update && \

# clone fzf repositories from the ~/.fzf and install
git clone --depth 1 https://github.com/junegunn/fzf.git /home/"${USER_NAME}"/.fzf && \

# Create a symbolic link for 'bat', repeated installation may cause problems
sudo ln -sf $(which batcat) /usr/local/bin/bat && \
sudo ln -sf $(which fdfind) /usr/local/bin/fd && \

# Create fish and install fisher tools
cp -r "${SCRIPT_PATH}/config/fish" "/home/${USER_NAME}/.config/fish"
# Install fisher
curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish \
    | fish -c "source && fisher install jorgebucaran/fisher" && \
# Install fish plugin
fish -c "fisher install \
        IlanCosman/tide@v5 \
        andreiborisov/sponge \
        jorgebucaran/autopair.fish \
        PatrickF1/fzf.fish \
        oh-my-fish/plugin-thefuck \
        kidonng/zoxide.fish \
        edc/bass \
        joseluisq/gitnow \
        markcial/upto \
        jorgebucaran/nvm.fish \
        && \
    /home/${USER_NAME}/.fzf/install --all && \
    set -U fish_user_paths /home/${USER_NAME}/.local/bin \$fish_user_paths" && \

# fish -c "/home/"${USER_NAME}"/.fzf/install --all" && \
        ## danhper/fish-ssh-agent \

# copy tmux configuration file
cp -r "${SCRIPT_PATH}"/config/fish /home/"${USER_NAME}"/.config/ && \

# switch default shell to fish shell
sudo chsh -s "$(which fish)" "${USER_NAME}" && \

# tldr update
mkdir -p /home/"${USER_NAME}"/.local/share/tldr && \
tldr --update && \

# delete old tmux plugin manager, avoid problems
rm -rf /home/"${USER_NAME}"/.tmux/plugins/tpm && \
# install new plugin manager
git clone --depth 1 \
    https://github.com/tmux-plugins/tpm \
    /home/"${USER_NAME}"/.tmux/plugins/tpm && \

# copy tmux configuration file
cp "${SCRIPT_PATH}"/config/tmux/tmux.conf /home/"${USER_NAME}"/.tmux.conf && \
/home/"${USER_NAME}"/.tmux/plugins/tpm/scripts/install_plugins.sh && \

mkdir -p /home/"${USER_NAME}"/.config/tmux-powerline && \
cp "${SCRIPT_PATH}"/config/tmux/tmux-powerline /home/"${USER_NAME}"/.config/tmux-powerline && \

# copy ssh config template to ~/.ssh/config
cp "${SCRIPT_PATH}"/config/ssh/ssh_config /home/"${USER_NAME}"/.ssh/config && \
# enable X11Forwarding
sudo sed -i 's/#\s*\(ForwardX11 yes\)/\1/' '/etc/ssh/ssh_config' && \
sudo sed -i -e 's/#\s*\(AllowTcpForwarding yes\)/\1/' \
           -e 's/#\s*\(X11Forwarding yes\)/\1/' \
           -e 's/#\s*\(X11DisplayOffset 10\)/\1/' \
           -e 's/#\s*\(X11UseLocalhost yes\)/\1/' \
           '/etc/ssh/sshd_config' && \
sudo systemctl enable ssh && \
sudo systemctl restart ssh && \

pip install pynvim

# NOTE: .config/ranger/rc.conf set preview_images true
# delete old ranger_devicons, avoid problems
rm -rf /home/"${USER_NAME}"/.config/ranger/plugins/ranger_devicons && \
# Install ranger plugins 'ranger_devicons'
git clone --depth 1 \
    https://github.com/alexanderjeurissen/ranger_devicons \
    /home/"${USER_NAME}"/.config/ranger/plugins/ranger_devicons && \

# print Success or failure message
printf "\033[1;37;42mSmall tools install successfully.\033[0m\n" || \
printf "\033[1;37;41mSmall tools Install failed.\033[0m\n"
