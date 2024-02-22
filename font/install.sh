#!/usr/bin/env bash

# ${1}: USER NAME. Use the provided username, or default to the current user ($USER).

# USER_NAME=${1:-"$USER"}
SCRIPT_PATH=$(dirname "$(readlink -f "${0}")")
FONTS_DIR=($(find "${SCRIPT_PATH}/fonts" -maxdepth 1 -type d))

# Update the package lists
sudo apt update && \

# Install required packages for 'fonts'
sudo apt install -y --no-install-recommends \
    unzip \
    fontconfig \
    && \

# copy fonts to the user's font directory
cp -r "${FONTS_DIR}" "${HOME}/.local/share/fonts/" && \
# refresh the font cache
sudo fc-cache --force --verbose && \

# print Success or failure message
printf "\033[1;37;42mFonts install successfully.\033[0m" || \
printf "\033[1;37;41mFonts Install failed.\033[0m"


# BUG: not download noto sans font...
# FIRACODE_VERSION=$(curl -s "https://api.github.com/repos/tonsky/FiraCode/releases/latest" | grep -Po '"tag_name": "\K[^"]*')

# NERDFONTS_VERSION=$(curl -s "https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest" | grep -Po '"tag_name": "\K[^"]*')

# curl -Lo ./fonts/FiraCode.zip "https://github.com/tonsky/FiraCode/releases/dwnload/${FIRACODE_VERSION}/Fira_Code_${FIRACODE_VERSION}.zip"


# FONT_NF=('FiraCode' 'Meslo' 'SourceCodePro')

# mkdir -p ./fonts

# for font in ${FONT_NF[@]}; do
#     curl -Lo "./fonts/${font}.zip" "https://github.com/ryanoasis/nerd-fonts/releases/download/${NERDFONTS_VERSION}/${font}.zip"
# done

