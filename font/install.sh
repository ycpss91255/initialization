#!/usr/bin/env bash

set -euo pipefail

USER_NAME=${1:-"$USER"}

USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6 || true)"
if [[ -z "${USER_HOME}" || ! -d "${USER_HOME}" ]]; then
    echo "User home directory for '${USER_NAME}' not found."
    exit 1
fi

SCRIPT_PATH=$(dirname "$(readlink -f "${0}")")

SRC_FONTS_DIR="${SCRIPT_PATH}/fonts"
if [[ ! -d "${SRC_FONTS_DIR}" ]]; then
    echo "Not found: ${SRC_FONTS_DIR}" >&2
    exit 1
fi

readarray -d '' -t FONTS_DIR < <(
    find "${SRC_FONTS_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z
)
if [[ ${#FONTS_DIR[@]} -eq 0 ]]; then
    echo "Subdirectories not found in ${SRC_FONTS_DIR}" >&2
    exit 1
fi

# Install required packages for 'fonts'
sudo apt update && \
sudo apt install -y --no-install-recommends \
    unzip \
    fontconfig

TARGET_FONT_DIR="${USER_HOME}/.local/share/fonts"
# copy fonts to the user's font directory
mkdir -p "${TARGET_FONT_DIR}"
chmod 755 "${TARGET_FONT_DIR}"
cp -r "${FONTS_DIR[@]}" "${TARGET_FONT_DIR}/"

# refresh the font cache
if [[ "$(id -un)" == "${USER_NAME}" ]]; then
    fc-cache -f -v "${TARGET_FONT_DIR}" >/dev/null
else
    sudo -u "$USER_NAME" fc-cache -f -v "${TARGET_FONT_DIR}" >/dev/null
fi

echo -e "\033[1;37;42mFonts installed successfully for ${USER_NAME}.\033[0m"
