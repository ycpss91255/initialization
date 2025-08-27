#!/usr/bin/env bash

set -euo pipefail

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    printf "Warn: %s is a executable script, not a library.\n" "${BASH_SOURCE[0]##*/}"
    printf "Please run this file.\n"
    return 0 2>/dev/null
fi

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_PATH}/../general.sh"

_script_path="${SCRIPT_PATH}"
# logger.sh variables
export LOG_LEVEL="DEBUG"

# general.sh variables
export EXEC_CMD_NO_PRINT="true"
export BACKUP_DIR="${_script_path}/test_use_backup"

# ----------------------------- Usage -----------------------------

for i in "true" "false"; do
    log_info "TEST: EXEC_CMD_NO_PRINT=%s" "${i}"
    EXEC_CMD_NO_PRINT="${i}"
    exec_cmd "echo \"Hello, World!\""
done

log_info "TEST: have_sudo_access"
if have_sudo_access; then
    log_info "Have sudo access"
else
    log_info "No sudo access"
fi

log_info "TEST: backup_files"
backup_files "${_script_path}/test_general.sh" "${_script_path}/not_found_file.txt"
exec_cmd "ls -l ${BACKUP_DIR}"

log_info "TEST: create_temp_file"
_file_path=""
create_temp_file _file_path "mytempfile" ".txt"
echo "Temp file created: ${_file_path}"

_folder_path=""
create_temp_file _folder_path -d -- "mytempfile"
echo "Temp folder created: ${_folder_path}"

log_info "TEST:check_pkg_status()"
if check_pkg_status --exec "bash"; then
    log_info "Package 'bash' is installed."
else
    log_info "Package 'bash' is NOT installed."
fi

if check_pkg_status --install "not-a-real-package"; then
    log_info "Package 'not-a-real-package' is installed."
else
    log_info "Package 'not-a-real-package' is NOT installed."
fi

log_info "TEST: setup_apt_mirror()"
setup_apt_mirror --dry-run -- "tw.packages.microsoft.com" "packages.microsoft.com"
setup_apt_mirror --path "/etc/apt/sources.list.d/" --dry-run -- "tw.archive.ubuntu.com" "archive.ubuntu.com"

log_info "TEST: apt_pkg_manager()"
apt_pkg_manager --install -- cowsay htop
apt_pkg_manager --install --no-update --only-upgrade -- cowsay htop
apt_pkg_manager --remove -- cowsay htop
# apt_pkg_manager --purge -- cowsay htop

log_info "TEST: get_github_pkg_latest_release()"
_version=""
get_github_pkg_latest_release _version "stedolan/jq"
log_info "Latest jq version: %s" "${_version}"
