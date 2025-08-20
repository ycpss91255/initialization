#!/usr/bin/env bash

# set -euo pipefail

USER_NAME=${1:-"$USER"}

USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6 || true)"
if [[ -z "${USER_HOME}" || ! -d "${USER_HOME}" ]]; then
    echo "User home directory for '${USER_NAME}' not found."
    exit 1
fi

SCRIPT_PATH=$(dirname "$(readlink -f "${0}")")

# purge 'XXX' related packages
sudo apt purge -y \


# Remove 'XXX' related files
sudo rm

# print Success or failure message
printf "\033[1;37;42mXXX purge successfully.\033[0m" || \
printf "\033[1;37;41mXXX purge failed.\033[0m"
