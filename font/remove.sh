#!/usr/bin/env bash

# ${1}: USER NAME. Use the provided username, or default to the current user ($USER).

USER_NAME=${1:-"$USER"}
SCRIPT_PATH=$(dirname "$(readlink -f "${0}")")
readarray -t FONT_NAMES < <(find "${SCRIPT_PATH}/fonts" -maxdepth 1 -type d | sed 's|.*/||')

error_occurred=false

for font in "${FONT_NAMES[@]}"; do
    # remove fonts from the user's font directory
    rm -rf "/home/${USER_NAME}/.local/share/fonts/${font}" || error_occurred=true
done

sudo fc-cache --force --verbose || error_occurred=true

# print Success or failure message
if [ "${error_occurred}" = true ]; then
    printf "\033[1;37;41mFonts purge failed.\033[0m\n"
else
    printf "\033[1;37;42mFonts purge successfully.\033[0m\n"
fi
