#!/usr/bin/env bash

set -euo pipefail
shopt -s inherit_errexit &>/dev/null || true

MAIN_FILE="true"; [[ "${BASH_SOURCE[0]}" != "${0}" ]] && MAIN_FILE="false"

if [[ "${MAIN_FILE}" == "true" ]]; then
    # shellcheck disable=SC2155
    SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
    export USER="${USER:-"$(whoami)"}"
    export HOME="${HOME:-"/home/${USER}"}"
    export LANGUAGE="C:en"

    # logger.sh variables
    export LOG_LEVEL="DEBUG"

    # sub_func.sh variables
    export LOG_NO_COLOR="false"

    unset HAVE_SUDO_ACCESS

    # main.sh variables
    # export SET_MIRRORS="false"

    # shellcheck disable=SC2155
    # export DATETIME="$(date +"%Y-%m-%d-%T")"
    # export BACKUP_DIR="${HOME}/.backup/${DATETIME}"
    :
else
    # include module
    :
fi

# shellcheck disable=SC1091
source "${SCRIPT_PATH}/function/logger.sh"
# shellcheck disable=SC1091
source "${SCRIPT_PATH}/function/sub_func.sh"

# the file used variables
_script_path="${SCRIPT_PATH}"

# include sub script

# main script
log_info "Start setup process..."

unset HAVE_SUDO_ACCESS



if ! have_sudo_access; then
    if [[ "${MAIN_FILE}" == "true" ]]; then
        log_fatal "No sudo access. Cannot continue install 'VSCode'."
    else
        log_warn "Skip install 'VSCode' due to no sudo access."
        return 1
    fi
fi

# install step ref: https://code.visualstudio.com/docs/setup/linux
log_info "Start install 'VSCode' and related packages"

log_info "Install 'VSCode' dependency packages: ${_vscode_dep_pkgs[*]}"
# coreutils => for 'install' command
# lsb-release => for 'lsb_release' command
# apt-transport-https => for https apt source
# wget => for download gpg key
# gpg => for import gpg key
_vscode_dep_pkgs=(
    "coreutils"
    "software-properties-common"
    "apt-transport-https"
    "lsb-release"
    "wget"
    "gpg"
)
apt_pkg_manager --install -- "${_vscode_dep_pkgs[@]}"

log_info "Setup 'VSCode' apt source"
exec_cmd "wget -qO- \"https://packages.microsoft.com/keys/microsoft.asc\" | gpg --dearmor > \"microsoft.gpg\""
exec_cmd "sudo install -D -o root -g root -m 644 \"microsoft.gpg\" \"/usr/share/keyrings/microsoft.gpg\" && rm -f \"microsoft.gpg\""

log_info "Add 'VSCode' apt source list"
# for ubuntu 20.04 or 20.04 up
if [[ -f /etc/apt/sources.list.d/vscode.sources ]]; then
    log_info "Backup old 'vscode.sources' file"
    if ! grep -qF "packages.microsoft.com/repos/code" "/etc/apt/sources.list.d/vscode.sources"; then
        exec_cmd "sudo cp -f \"/etc/apt/sources.list.d/vscode.sources{,.save}\""
    fi
fi
log_info "Copy new 'vscode.sources' file"
exec_cmd "sudo install -D -o root -g root -m 644 \"${_script_path}/config/vscode/vscode.sources\" \"/etc/apt/sources.list.d/vscode.sources\""

# # for ubuntu 18.04
# if [[ -f /etc/apt/sources.list.d/vscode.list ]]; then
#     if ! grep -qF 'packages.microsoft.com/repos/code' /etc/apt/sources.list; then
#         exec_cmd "sudo cp -f /etc/apt/sources.list.d/vscode.list /etc/apt/sources.list.d/vscode.list.save"
#     fi
#     exec_cmd 'echo "deb [arch=amd64,arm64,armhf] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list'
# fi

log_info "Install 'VSCode'"
apt_pkg_manager --install -- "code"

# TODO: add vscode to desktop and favorite
# TODO: check vscode keyboardbinding
# TODO: check settings.json

# TODO: check vscode extension (recommend)


# # 偵測 VS Code 可執行檔（穩定版或 Insiders）
# CODE_BIN="$(command -v code || true)"
# DESKTOP_ID="code.desktop"
# NAME="Visual Studio Code"
# ICON_NAME="com.visualstudio.code"

# if [[ -z "${CODE_BIN}" ]]; then
#   # 試試看 Insiders
#   CODE_BIN="$(command -v code-insiders || true)"
#   DESKTOP_ID="code-insiders.desktop"
#   NAME="Visual Studio Code - Insiders"
#   ICON_NAME="com.visualstudio.code.insiders"
# fi

# if [[ -z "${CODE_BIN}" ]]; then
#   echo "找不到 'code' 或 'code-insiders' 可執行檔。請先安裝 VS Code。"
#   exit 1
# fi

# # 準備 .desktop 路徑（優先使用使用者本地）
# USER_DESKTOP_DIR="${HOME}/.local/share/applications"
# SYSTEM_DESKTOP_DIR="/usr/share/applications"
# mkdir -p "${USER_DESKTOP_DIR}"

# DESKTOP_PATH_SYSTEM="${SYSTEM_DESKTOP_DIR}/${DESKTOP_ID}"
# DESKTOP_PATH_USER="${USER_DESKTOP_DIR}/${DESKTOP_ID}"

# # 若系統層已有 .desktop，直接使用；否則建立使用者層 .desktop
# if [[ -f "${DESKTOP_PATH_SYSTEM}" ]]; then
#   echo "偵測到系統已存在 ${DESKTOP_ID}，將使用它。"
# else
#   echo "系統未提供 ${DESKTOP_ID}，建立使用者層 .desktop：${DESKTOP_PATH_USER}"
#   cat > "${DESKTOP_PATH_USER}" <<EOF
# [Desktop Entry]
# Type=Application
# Name=${NAME}
# Comment=Code Editing. Redefined.
# Exec=${CODE_BIN} -- %F
# Icon=${ICON_NAME}
# Terminal=false
# Categories=Development;IDE;
# StartupNotify=true
# MimeType=text/plain;inode/directory;
# Actions=new-window;

# [Desktop Action new-window]
# Name=New Window
# Exec=${CODE_BIN} --new-window %F
# EOF
#   # 嘗試更新 desktop 資料庫（失敗也不致命）
#   command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "${USER_DESKTOP_DIR}" || true
# fi

# # 釘選到 Dock（GNOME）
# if command -v gsettings >/dev/null 2>&1; then
#   CURRENT="$(gsettings get org.gnome.shell favorite-apps)"
#   # 組合要加入的 desktop-id
#   WANT="${DESKTOP_ID}"

#   # 如果尚未包含，就插入到陣列尾端
#   if [[ "${CURRENT}" != *"'${WANT}'"* ]]; then
#     # 把 ] 改成 , 'code.desktop'] 的方式附加
#     NEW="${CURRENT%]*}, '${WANT}']"
#     gsettings set org.gnome.shell favorite-apps "${NEW}"
#     echo "已將 ${WANT} 釘選到 Dock。"
#   else
#     echo "${WANT} 已在 Dock 收藏中。"
#   fi
# else
#   echo "找不到 gsettings，無法自動釘選到 Dock。你仍可在應用程式清單中找到 VS Code，開啟後在 Dock 上右鍵 -> 加入到收藏。"
# fi

# echo "完成。"
