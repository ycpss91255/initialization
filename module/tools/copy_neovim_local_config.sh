#!/usr/bin/env bash

#TODO: wait review
set -euo pipefail

USER_NAME=${1:-"$USER"}

USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6 || true)"
if [[ -z "${USER_HOME}" || ! -d "${USER_HOME}" ]]; then
    echo "User home directory for '${USER_NAME}' not found."
    exit 1
fi

SCRIPT_PATH=$(dirname "$(readlink -f "${0}")")

USER_CONF_DIR="${USER_HOME}/.config/nvim/lua"

TARGET_USER_DIR="${USER_CONF_DIR}/user"

mv "${SCRIPT_PATH}/config" "${SCRIPT_PATH}/config.bak" || true

cp -r "${USER_CONF_DIR}/user" "${SCRIPT_PATH}/config"
