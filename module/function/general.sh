#!/usr/bin/env bash

set -euo pipefail

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    printf "To learn how to use it, please refer to '%s'\n" "./test/test_logger.sh"
    return 0 2>/dev/null
fi

_script_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${_script_path}/logger.sh"

# NOTE: not use
function check_in_WSL() {
    if [[ -n "${WSL_DISTRO_NAME}" ]] || (uname -r | grep -qiF 'microsoft'); then
        export IN_WSL=true
    fi
}

# NOTE: not use
function check_in_docker() {
    if [[ -f "/.dockerenv" ]] || grep -qE '/docker|/lxc/' /proc/1/cgroup 2>/dev/null; then
        export IN_DOCKER=true
    fi
}

# NOTE: not use
function check_in_mac() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        export IN_MAC=true
    fi
}

# NOTE: not use
# Get system parameters.
function get_system_param() {
    local _system_id _system_codename _system_release

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release

        _system_id="${ID:-""}"
        _system_release="${VERSION_ID:-""}"
        _system_codename="${VERSION_CODENAME:-""}"
    fi

    export SYSTEM_ID="${_system_id}"
    export SYSTEM_RELEASE="${_system_release}"
    export SYSTEM_CODENAME="${_system_codename}"

}

# export EXEC_CMD_NO_PRINT="true"
# From https://github.com/XuehaiPan/Dev-Setup.git
function exec_cmd() {
    local -a _cmd=("$@")
    if [[ "${EXEC_CMD_NO_PRINT-}" != "true" ]]; then
        local _color="false"; [[ -t 2 ]] && _color="true"
        printf "%s" "${_cmd[@]}" | awk -v _color="$_color"\
            'BEGIN {
                if (_color == "true") {
                    RESET = "\033[0m";
                    BOLD = "\033[1m";
                    UNDERLINE = "\033[4m";
                    UNDERLINEOFF = "\033[24m";
                    RED = "\033[31m";
                    GREEN = "\033[32m";
                    YELLOW = "\033[33m";
                    WHITE = "\033[37m";
                    GRAY = "\033[90m";
                } else {
                    RESET = "";
                    BOLD = "";
                    UNDERLINE = "";
                    UNDERLINEOFF = "";
                    RED = "";
                    GREEN = "";
                    YELLOW = "";
                    WHITE = "";
                    GRAY = "";
                }

                IDENTIFIER = "[_a-zA-Z][_a-zA-Z0-9]*";
                idx = 0;
                in_string = 0;
                double_quoted = 1;

                printf("%s$", BOLD WHITE);
            }
            {
                for (i = 1; i <= NF; ++i) {
                    style = WHITE;
                    post_style = WHITE;

                    if (!in_string) {
                        if ($i ~ /^-/)
                            style = YELLOW;
                        else if ($i == "sudo" && idx == 0) {
                            style = UNDERLINE GREEN;
                            post_style = UNDERLINEOFF WHITE;
                        }
                        else if ($i ~ "^" IDENTIFIER "=" && idx == 0) {
                            style = GRAY;
                            '"if (\$i ~ \"^\" IDENTIFIER \"=[\\\"']\") {"'
                                in_string = 1;

                                double_quoted = ($i ~ "^" IDENTIFIER "=\"");
                            }
                        }
                        else if ($i ~ /^[12&]?>>?/ || $i == "\\")
                            style = RED;
                        else {
                            ++idx;
                            '"if (\$i ~ /^[\"']/) {"'
                                in_string = 1;
                                double_quoted = ($i ~ /^"/);
                            }
                            if (idx == 1)
                                style = GREEN;
                        }
                    }
                    if (in_string) {
                        if (style == WHITE)
                            style = "";
                        post_style = "";
                        '"if ((double_quoted && \$i ~ /\";?\$/ && \$i !~ /\\\\\";?\$/) || (!double_quoted && \$i ~ /';?\$/))"'
                            in_string = 0;
                    }
                    if (($i ~ /;$/ && $i !~ /\\;$/) || $i == "|" || $i == "||" || $i == "&&") {
                        if (!in_string) {
                            idx = 0;
                            if ($i !~ /;$/)
                                style = RED;
                        }
                    }
                    if ($i ~ /;$/ && $i !~ /\\;$/)
                        printf(" %s%s%s;%s", style, substr($i, 1, length($i) - 1), (in_string ? WHITE : RED), post_style);
                    else
                        printf(" %s%s%s", style, $i, post_style);
                    if ($i == "\\")
                        printf("\n\t");
                }
            }
            END {
                printf("%s\n", RESET);
            }' >&2
    fi
    eval "$*"
}

# Check if the user has sudo access.
#
# Usage:
#   have_sudo_access
#
# Returns:
#   0 if the user has sudo access
#   1 if the user does not have sudo access
#
# Examples:
# if have_sudo_access; then
function have_sudo_access() {
    local -a _SUDO=("/usr/bin/sudo")

    if [[ "${EUID:-"${UID}"}" -eq "0" ]]; then
        log_debug "User has sudo access."

        if [[ ! -x "${_SUDO[0]}" ]]; then
            exec_cmd "apt-get update && apt-get install -y -- sudo"
        fi

        return 0
    fi

    if [[ ! -x "${_SUDO[0]}" ]]; then
        log_fatal "User is normal user and 'sudo' command not found."
    fi

    if [[ -n "${SUDO_ASKPASS-}" ]]; then
        _SUDO+=("-A")
    fi

    if [[ -z "${HAVE_SUDO_ACCESS-}" ]]; then
        log_info "Checking sudo access (press Ctrl+C to run as normal user)."
        exec_cmd "${_SUDO[*]} -v &>/dev/null"
        export HAVE_SUDO_ACCESS="$?"
    fi

    return "$HAVE_SUDO_ACCESS"
}

# Backup files
#
# Usage:
#   backup_files <file1> [<file2> ...]
#
# Parameters:
#   <file1>: files to backup
#   [<file2> ...]: additional files to backup
#
# Examples:
#   backup_files folder folder/file.txt
function backup_files() {
    if [[ -z "${BACKUP_DIR:-}" ]]; then
        log_fatal "BACKUP_DIR is not set."
    fi

    echo "Backup files to ${BACKUP_DIR}"
    mkdir -p -- "${BACKUP_DIR}"

    local _file="" _original_file=""
    for _file in "${@:?"${FUNCNAME[0] need files to backup.}"}"; do
        if [[ -e "${_file}" ]]; then
            log_debug "Backup file: ${_file}"
            cp -aL -- "${_file}" "${BACKUP_DIR}"
            continue
        fi
        log_warn "File not found, skip: ${_file}"
    done
}

# Create a temp file in /tmp.
#
# Usage:
#   create_temp_file [options] [--] <outvar> <prefix> [ext]
#
# Options:
#   [-d] : create folder
#
# Parameters:
#   <outvar>: variable name to store the temporary file path
#   <prefix>: prefix string
#   [ext]: file extension
#
# Examples:
#   create_temp_file var "prefix" "txt"
#   create_temp_file var "prefix"
#   create_temp_file -d -- var "prefix" "suffix"
#   create_temp_file -d -- var "prefix"
function create_temp_file() {
    local _short_opts="d"
    local _long_opts=""

    local _parsed=""
    if ! _parsed=$(getopt -o "${_short_opts}" --long "${_long_opts}" -n "${FUNCNAME[0]}" -- "$@"); then
        log_fatal "Usage: ${FUNCNAME[0]} [options] [--] <outver> <prefix> [ext]"
    fi

    eval set -- "${_parsed}"

    local _mode="file"

    while true; do
        case "$1" in
            -d) _mode="folder"; shift ;;
            --) shift; break ;;
            *) break ;;
        esac
    done

    local -n _outvar="${1:?"${FUNCNAME[0]} need outvar."}"; shift
    local _prefix="${1:?"${FUNCNAME[0]} need prefix."}"
    local _ext="${2:-""}"

    _prefix="${_prefix//[^a-zA-Z0-9_.-]/}"
    _ext="${_ext//[^a-zA-Z0-9_.-]/}"
    _ext="${_ext#.}"

    case "${_mode}" in
        file)
            if ! _outvar=$(mktemp "/tmp/${_prefix}_XXXXXX.${_ext}"); then
                log_fatal "Failed to create temporary file."
            fi
            ;;
        folder)
            if ! _outvar=$(mktemp -d "/tmp/${_prefix}_XXXXXX${_ext}"); then
                log_fatal "Failed to create temporary folder."
            fi
            ;;
        *)
            log_fatal "Unknown mode: ${_mode}"
            ;;
    esac
}

# Check package status.
#
# Usage:
#   check_pkg_status <option> [--] <name> <version>
#
# Options:
#   --install | -i  check package installation status
#   --exec    | -e  check package executable status
#   --version | -v  check package version
#
# Parameters:
#   <name>: package name
#   <version>: package version (option is <version>)
#
# Returns:
#   0 if <name> is installed or executable
#   1 if <name> is not installed or not executable
#
# Examples:
#   if check_pkg_status --install "curl"; then
#   if check_pkg_status --exec "ls"; then
#   if check_pkg_status --version "bash" "0.0.1"; then
function check_pkg_status() {
    local _short_opts="iev"
    local _long_opts="install,exec,version"

    local _parsed=""

    if ! _parsed=$(getopt -o "${_short_opts}" --long "${_long_opts}" -n "${FUNCNAME[0]}" -- "$@"); then
        log_fatal "Usage: ${FUNCNAME[0]} <option> [--] <name> <version>"
    fi

    eval set -- "${_parsed}"

    local _mode=""

    while true; do
        case "$1" in
            --install|-i) _mode="install"; shift ;;
            --exec|-e)    _mode="exec";    shift ;;
            --version|-v) _mode="version"; shift ;;
            --) shift; break ;;
            *) break ;;
        esac
    done

    local _pkg=${1:?"${FUNCNAME[0]} check package quantity."}

    case "${_mode}" in
        install)
            log_debug "Checking installation status of package: ${_pkg}"

            if dpkg-query -W -f='${db:Status-Abbrev}\n' -- "${_pkg}" 2>/dev/null \
                | grep -q "^ii" ; then
                return 0
            else
                return 1
            fi
            ;;
        exec)
            log_debug "Checking executable status of command: ${_pkg}"

            if command -v -- "${_pkg}" &>/dev/null; then
                return 0
            else
                return 1
            fi
            ;;
        version)
            local _version=${2:?"${FUNCNAME[0]} need version."}
            _version="${_version#v}"
            log_debug "Checking version of package: ${_pkg}"
            local _opt=""
            for _opt in "--version" "-v" "-V"; do
                local _cmd_version=""
                if _cmd_version=$("${_pkg}" "${_opt}" 2>&1) && \
                [[ "${_cmd_version}" == *"${_version}"* ]]; then
                    log_debug "Found version '${_version}' in '${_cmd_version}'"
                    return 0
                fi
            done
            log_debug "Version '${_version}' not found for package: ${_pkg}"
            return 1
            ;;
        *)
            log_fatal "Unknown mode: ${_mode}"
            ;;
    esac
}

# Setup APT source mirrors.
#
# Usage:
#   setup_apt_mirror [options] -- <mirror_url> <origin_url>
#
# Options:
#   [--path <path>]: the path to the file or directory to be mirrored
#   [--dry-run]: do not modify any files, just print the changes that would be made
#
# Parameters:
#   <mirror_url>: the URL of the mirror
#   <origin_url>: the original URL to be mirrored
#
# Examples:
#  setup_apt_mirror --path "/etc/apt/sources.list.d" -- "tw.packages.microsoft.com" "packages.microsoft.com"
# setup_apt_mirror --path "/etc/apt/sources.list" -- "tw.packages.microsoft.com" "packages.microsoft.com"
# default path is /etc/apt/sources.list.d
# setup_apt_mirror -- "tw.packages.microsoft.com" "packages.microsoft.com"
function setup_apt_mirror() {
    local _short_opts="p:"
    local _long_opts="path:,dry-run"

    local _parsed=""

    if ! _parsed=$(getopt -o "${_short_opts}" --long "${_long_opts}" -n "${FUNCNAME[0]}" -- "$@"); then
        log_fatal "Usage: ${FUNCNAME[0]} [options] [--] <mirror_url> <origin_url>"
    fi

    eval set -- "${_parsed}"

    local _path="/etc/apt/sources.list.d"
    local _dry_run="false"

    while true; do
        case "$1" in
            --path|-p)
                _path="$2"; shift 2;;
            --dry-run)
                log_warn "Dry run mode, no files will be modified."; _dry_run="true"; shift ;;
            --) shift; break ;;
            *) break ;;
        esac
    done

    if [[ ! -d "${_path}" && ! -f "${_path}" ]]; then
        log_fatal "Path not found: ${_path}"
    fi

    local _mirror_url="${1:?"${FUNCNAME[0]} need mirror url"}"; shift
    local _origin_url="${1:?"${FUNCNAME[0]} need origin url"}"
    echo "mirror: ${_mirror_url}, origin: ${_origin_url}"
    # mirror cmd
    local _mirror_cmd="s|${_origin_url}|${_mirror_url}|g"

    if [[ -d "${_path}" ]]; then
        local _file=""

        log_debug "Setup APT source mirror in folder: ${_path}"
        for _file in "${_path}"/*; do
            if [[ -f "${_file}" ]]; then
                log_debug "Processing file: ${_file}"
                if [[ "${_file}" == *.sources || "${_file}" == *.list ]]; then
                    log_debug "Setup APT source mirror in file: ${_file}"
                    if [[ "${_dry_run}" == "true" ]]; then
                        log_info "Dry run: sed -E -i.bak 's|${_origin_url}|${_mirror_url}|g' ${_file}"
                        continue
                    fi

                    exec_cmd "sed -E -i.bak 's|${_origin_url}|${_mirror_url}|g' ${_file}"
                    if cmp -s "{$_file}" "${_file}.bak"; then
                        log_warn "Failed to setup APT source mirror in file: ${_file}, ${_origin_url} -> ${_mirror_url}"
                    else
                        log_debug "Successfully setup APT source mirror in file: ${_file}, ${_origin_url} -> ${_mirror_url}"
                    fi
                    continue
                fi
                log_debug "Skip non-APT source file: ${_file}"
            fi
        done
    elif [[ -f "${_path}" ]]; then
        _file="${_path}"
        if [[ "${_file}" == *.sources || "${_file}" == *.list ]]; then
            log_debug "Setup APT source mirror in file: ${_file}"
            if [[ "${_dry_run}" == "true" ]]; then
                log_info "Dry run: sed -E -i.bak 's|${_origin_url}|${_mirror_url}|g' ${_file}"
                return 0
            fi

            exec_cmd "sed -E -i.bak 's|${_origin_url}|${_mirror_url}|g' ${_file}"
            if cmp -s "{$_file}" "${_file}.bak"; then
                log_error "Failed to setup APT source mirror in file: ${_file}, ${_origin_url} -> ${_mirror_url}"
                return 0
            fi
            log_debug "Successfully setup APT source mirror in file: ${_file}, ${_origin_url} -> ${_mirror_url}"
        fi
    else
        log_fatal "Path is not file or folder: ${_path}"
    fi
}

# Manage APT packages (install, remove).
#
# Usage:
#   apt_pkg_manager <action> [option] [--] <package1> [<package2> ...]
#
# Actions:
#   install   : install packages
#   remove    : remove packages
#   purge     : remove packages and their configuration files
#
# Options:
#   action is install
#      [--no-update]: do not update package list
#      [--only-upgrade]: only upgrade packages
#   action is remove
#   [--purge]: remove packages and their configuration files
#
# Parameters:
#   <package1>: package name
#   [<package2> ...]: additional package names
#
# Examples:
#   apt_pkg_manager --install --no-update "cowsay"
#   apt_pkg_manager --install -- "cowsay"
#   apt_pkg_manager --install "cowsay"
#   apt_pkg_manager --remove "cowsay"
#   apt_pkg_manager --remove --purge "cowsay"
function apt_pkg_manager() {
    local _short_opts=""
    local _long_opts="install,remove,purge,no-update,only-upgrade"

    local _parsed=""

    if ! _parsed=$(getopt -o "${_short_opts}" --long "${_long_opts}" -n "${FUNCNAME[0]}" -- "$@"); then
        log_fatal "Usage: ${FUNCNAME[0]} <action> [option] [--] <package1> [<package2> ...]"
    fi

    eval set -- "${_parsed}"

    local _action=""
    local _update_flag="true"
    local _only_upgrade="false"
    local _purge="false"

    while true; do
        case "$1" in
            --install) _action="install"; shift ;;
            --remove)  _action="remove";  shift ;;
            --purge)   _action="remove"; _purge="true";   shift ;;
            --no-update) _update_flag="false"; shift ;;
            --only-upgrade) _only_upgrade="true"; shift ;;
            --) shift; break ;;
            *) break ;;
        esac
    done

    if [[ "${_action}" != "install" ]]; then
        if [[ "${_update_flag}" == "false" ]]; then
            log_fatal "<--no-update> option only supports install action."
        fi
        if [[ "${_only_upgrade}" == "true" ]]; then
            log_fatal "<--only-upgrade> option only supports install action."
        fi
    fi

    if [[ "${_action}" != "remove" ]]; then
        if [[ "${_purge}" == "true" ]]; then
            log_fatal "<--purge> option only supports remove action."
        fi
    fi

    if [[ $# -eq 0 ]]; then
        log_fatal "Package quantity is zero"
    fi

    local _pkgs=() _failed_pkgs=() _not_install_pkgs=()
    local _pkg=""

    for _pkg in "$@"; do
        _pkg="${_pkg//[^a-zA-Z0-9_.-]/}"

        if [[ -n "${_pkg}" ]]; then
            _pkgs+=("${_pkg}")
        fi
    done

    local -a _apt_cmd=("sudo" "apt-get" "${_action}" "-y")

    case "$_action" in
        install)
            if [[ "${_update_flag}" == "true" ]]; then
                log_debug "Updating package list..."
                exec_cmd "sudo apt-get update" || \
                    log_fatal "Failed to update package list."
            fi

            log_debug "Installing packages: ${_pkgs[*]}"
            local _pkg=""

            if [[ "${_only_upgrade}" == "true" ]]; then
                _apt_cmd+=("--only-upgrade")
            fi

            _apt_cmd+=("--no-install-recommends" "--")

            for _pkg in "${_pkgs[@]}"; do
                log_debug "Installing package: ${_pkg}"

                if sudo apt-cache show "${_pkg}" &>/dev/null; then
                    exec_cmd "${_apt_cmd[*]} ${_pkg}" || _failed_pkgs+=("${_pkg}")
                else
                    log_debug "Package not found: ${_pkg}"

                    _failed_pkgs+=("${_pkg}")
                    continue
                fi
            done
            ;;
        remove)
            log_debug "${_action^} packages: ${_pkgs[*]}"

            if [[ "${_purge}" == "true" ]]; then
                _apt_cmd+=("--purge")
            fi

            local _pkg=""

            for _pkg in "${_pkgs[@]}"; do
                if ! check_pkg_status --install "$_pkg"; then
                    log_debug "Package not installed, skip: ${_pkg}"
                    _not_install_pkgs+=("${_pkg}")
                    continue
                fi

                if ! exec_cmd "${_apt_cmd[*]} ${_pkg}"; then
                    _failed_pkgs+=("$_pkg")
                    continue
                fi
                log_debug "Successfully ${_action} package: ${_pkg}"
            done

            if [[ "${#_not_install_pkgs[@]}" -gt 0 ]]; then
                log_debug "Not installed (skip): ${_not_install_pkgs[*]}"
            fi
            ;;
        *)
            log_fatal "Unknown action: ${_action}"
            ;;
    esac

    if [[ "${#_failed_pkgs[@]}" -gt 0 ]]; then
        log_error "${_action^} failed: ${_failed_pkgs[*]}"
        return 1
    fi
}

# Get package latest version from GitHub.
#
# Usage:
#   get_github_pkg_lattst_version <outvar> <repo>
#
# Parameters:
#   <outvar>: variable name to store the GitHub repository release version
#   <repo>: GitHub repository (owner/repo)
#
# Examples:
#   get_github_pkg_latest_version PKG_VERSION "jesseduffield/lazygit"
function get_github_pkg_latest_version() {
    local -n _outvar="${1:?"${FUNCNAME[0]} need outvar."}"; shift
    local _repo="${1:?"${FUNCNAME[0]} need repo."}"

    if [[ "$_repo" != *"/"* ]]; then
        log_fatal "Invalid GitHub repository format: ${_repo}"
    fi

    local _curl_jq_mode="true"
    local -a _cmd=()

    log_debug "Try installing 'curl' and 'jq'..."
    for _cmd in "curl" "jq"; do
        if ! check_pkg_status --exec -- "${_cmd}"; then
            log_debug "${_cmd} is not install, Installing ${_cmd}..."

            if ! apt_pkg_manager --install -- "${_cmd}"; then
                log_debug "Failed to install ${_cmd}."

                _curl_jq_mode="false"
                break
            fi
        fi
    done

    if [[ "${_curl_jq_mode}" == "false" ]]; then
        local _cmd=""

        log_debug "Try installing 'wget' 'grep' and 'sed' ..."
        for _cmd in "wget" "grep" "sed"; do
            if ! check_pkg_status --exec -- "${_cmd}"; then
                log_debug "${_cmd} is not install, Installing ${_cmd}..."

                if ! apt_pkg_manager --install -- "${_cmd}"; then
                    log_fatal "Unable to install 'curl jq' or 'wget grep sed' tools."
                fi
            fi
        done
    fi

    local _url="https://api.github.com/repos/${_repo}/releases/latest"
    local _response=""

    log_debug "Github repository url: ${_url}"

    if [[ "${_curl_jq_mode}" == "true" ]]; then
        if ! _response=$(curl -fsSL --retry 3 "${_url}"); then
            log_fatal "Failed to get GitHub API response."
        fi

        _outvar="$(printf '%s' "$_response" | jq -er '.tag_name' | sed -E 's/^v//')"
    else
        if ! _response=$(wget -qO- --timeout=10 "${_url}"); then
            log_fatal "Failed to get GitHub API response."
        fi

        _outvar="$(printf '%s' "$_response" | grep -oP '"tag_name":\s*"\K(.*)(?=")' | sed -E 's/^v//')"
    fi

    if [[ -z "${_outvar}" ]]; then
        log_fatal "No valid release version found in url: ${_url}"
    fi
}
