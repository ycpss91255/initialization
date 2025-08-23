#!/usr/bin/env bash

set -euo pipefail

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    return 0 2>/dev/null
fi
[[ -n "${TTY_COLORS_READY:-}" ]] && return 0

#TODO: add comment

# Get system current user name or user input string.
#
# Usage:
#   get_user_name [user_input]
#
# Parameters:
#   [user_input]: user input string
#
# Returns:
#   User name
#
# Examples:
#   var=$(get_user_name "Alice")
#   var=$(get_user_name)
function _support_color() {
    if [[ -t 1 || -t 2 ]]; then
        function _esc() { printf "\033[%sm" "$1"; }
    else
        function _esc() { :; }
    fi
    function _bold() { _esc "1;$1"; }

    local -a _names=(RED GREEN YELLOW BLUE MAGENTA CYAN WHITE)
    local -a _codes=(31  32    33     34   35      36   37)
    local i
    for i in "${!_names[@]}"; do
        printf -v "TTY_CLR_${_names[i]}"  '%s' "$(_esc  "22;${_codes[i]}")"
        printf -v "TTY_BOLD_${_names[i]}" '%s' "$(_bold "${_codes[i]}")"
    done

    TTY_CLR_RESET="$(_esc "22;0")"
    TTY_COLORS_READY="true"

    # echo ""
    # echo "${TTY_CLR_RED}TTY_CLR_RED"
    # echo "${TTY_BOLD_RED}TTY_BOLD_RED"
    # echo "${TTY_CLR_GREEN}TTY_CLR_GREEN"
    # echo "${TTY_BOLD_GREEN}TTY_BOLD_GREEN"
    # echo "${TTY_CLR_YELLOW}TTY_CLR_YELLOW"
    # echo "${TTY_BOLD_YELLOW}TTY_BOLD_YELLOW"
    # echo "${TTY_CLR_BLUE}TTY_CLR_BLUE"
    # echo "${TTY_BOLD_BLUE}TTY_BOLD_BLUE"
    # echo "${TTY_CLR_MAGENTA}TTY_CLR_MAGENTA"
    # echo "${TTY_BOLD_MAGENTA}TTY_BOLD_MAGENTA"
    # echo "${TTY_CLR_CYAN}TTY_CLR_CYAN"
    # echo "${TTY_BOLD_CYAN}TTY_BOLD_CYAN"
    # echo "${TTY_CLR_WHITE}TTY_CLR_WHITE"
    # echo "${TTY_BOLD_WHITE}TTY_BOLD_WHITE"
    # echo ""
}

function _logger_level_to_num() {
    case "${1:-INFO}" in
        DEBUG) echo 10 ;;
        INFO)  echo 20 ;;
        WARN)  echo 30 ;;
        ERROR) echo 40 ;;
        FATAL) echo 50 ;;
        *)     echo 20 ;; # Default to INFO
    esac
}

function _logger_should_print() {
    local _level="$1"
    [[ "$(_logger_level_to_num "${_level}")" -ge "$(logger_level_to_num "${LOG_LEVEL:-INFO}")" ]]
}

function _logger_fd_for_level() {
    local _level="$1"
    case "${_level}" in
        DEBUG|INFO) echo 1 ;;  # stdout
        WARN|ERROR|FATAL) echo 2 ;; # stderr
        *) echo 1 ;; # Default to stdout
    esac
}

function _logger_header_color() {
    local _level="$1${TTY_CLR_RESET}"
    case "${_level}" in
        DEBUG) echo "${TTY_CLR_BLUE}${1}"   ;;
        INFO)  echo "${TTY_CLR_GREEN}${1}"  ;;
        WARN)  echo "${TTY_CLR_YELLOW}${1}" ;;
        ERROR) echo "${TTY_CLR_RED}${1}"    ;;
        FATAL) echo "${TTY_BOLD_RED}${1}"   ;;
        *)     echo "${TTY_CLR_RESET}${1}"  ;; # Default to reset
    esac
}

function _logger_formatter() {
    local _level _fd
    local _date _funcname _source
    _level="$1"; shift
    _fd="$1"; shift
    _date="$(date +"%y-%m-%d %H:%M:%S")"
    _funcname=${FUNCNAME[2]:-main}
    _source="${BASH_SOURCE[2]##*/}"

    printf "%s [%s] [%s] [%s] %s\n" \
        "${_date}" \
        "${_source%.*}" \
        "${_funcname}" \
        "${_level}" \
        "$*" >&"${_fd}"
}

function _log_print() {
    local _level="$1"; shift
    local _fd
    _logger_should_print "${_level}" || return 0
    _fd=$(_logger_fd_for_level "${_level}")
    _level=$(_logger_header_color "${_level}")
    _logger_formatter "${_level}" "${_fd}" "$*"

}

function log_debug() { _log_print "DEBUG" "$*"; }
function log_info()  { _log_print "INFO"  "$*"; }
function log_warn()  { _log_print "WARN"  "$*"; }
function log_error() { _log_print "ERROR" "$*"; }
function log_fatal() { _log_print "FATAL" "$*"; exit 1; }

_support_color
