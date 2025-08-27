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

readarray -d '' -t FONTS_NAME < <(
    find "${SRC_FONTS_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%f\0' | sort -z
)
if [[ ${#FONTS_NAME[@]} -eq 0 ]]; then
    echo "Subdirectories not found in ${SRC_FONTS_DIR}" >&2
    exit 1
fi

TARGET_FONT_DIR="${USER_HOME}/.local/share/fonts"
if [[ ! -d "${TARGET_FONT_DIR}" ]]; then
    echo "Target font directory '${TARGET_FONT_DIR}' does not exist."
    exit 1
fi

for font in "${FONT_NAMES[@]}"; do
    # remove fonts from the user's font directory
    rm -rf "${TARGET_FONT_DIR}/${font}"
done

# refresh the font cache
if [[ "$(id -un)" == "${USER_NAME}" ]]; then
    fc-cache -f -v "${TARGET_FONT_DIR}" >/dev/null
else
    sudo -u "$USER_NAME" fc-cache -f -v "${TARGET_FONT_DIR}" >/dev/null
fi

echo -e "\033[1;37;42mFonts removal successfully for ${USER_NAME}.\033[0m"
