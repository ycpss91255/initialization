#!/usr/bin/env bash

set -euo pipefail

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    printf "To learn how to use it, please refer to '%s'\n" "./test/test_logger.sh"
    return 0 2>/dev/null
fi

[[ -n "${TTY_COLORS_READY:-}" ]] && return 0

export LOG_LEVEL="${LOG_LEVEL:-INFO}"
export LOG_COLOR="${LOG_COLOR:-true}"

export TTY_COLORS_READY=""

#TODO: add custom output format
#TODO: add output to file function and option

# Support color output in the terminal
#
# Usage:
#   _support_color
#
# Examples:
#   _support_color
function _support_color() {
    function _esc() {
        local out="${1:?"${FUNCNAME[0]} need outvar."}"; shift
        printf -v "${out}" "\033[%sm" "$1"
    }

    function _bold() {
        local out="${1:?"${FUNCNAME[0]} need outvar."}"; shift
        _esc "${out}" "1;$1"
    }

    local -a _names=(RED GREEN YELLOW BLUE MAGENTA CYAN WHITE)
    local -a _codes=(31  32    33     34   35      36   37)
    local _i=""

    for _i in "${!_names[@]}"; do
        _esc "TTY_CLR_${_names[_i]}"  "22;${_codes[_i]}"
        _bold "TTY_BOLD_${_names[_i]}" "${_codes[_i]}"
    done

    _esc "TTY_CLR_RESET" "0"

    TTY_COLORS_READY="true"
}

# Logger level to number
#
# Usage:
#   _logger_level_to_num <outvar> <level>
#
# Parameters:
#   <outvar>: variable name to store the numeric level
#   <level>: log level string (e.g. "DEBUG", "INFO", etc.)
#
# Examples:
#   _logger_level_to_num outvar "DEBUG"
function _logger_level_to_num() {
    local -n _outvar="${1:?"${FUNCNAME[0]} need outvar."}"; shift
    local _level="${1:?"${FUNCNAME[0]} need level."}"

    case "${_level^^}" in
        DEBUG) _outvar=10 ;; INFO)  _outvar=20 ;; WARN) _outvar=30 ;;
        ERROR) _outvar=40 ;; FATAL) _outvar=50 ;; *)    _outvar=20 ;;
    esac
}

# Logger should print or not
#
# Usage:
#   _logger_should_print <level>
#
# Parameters:
#   <level>: log level string (e.g. "DEBUG", "INFO", etc.)
#
# Examples:
#   _logger_should_print "DEBUG"
function _logger_should_print() {
    local _level="${1:?"${FUNCNAME[0]} need level."}"
    local _target="" _default=""
    _logger_level_to_num _target "${_level}"
    _logger_level_to_num _default "${LOG_LEVEL:-INFO}"

    if [[ "${_target}" -ge "${_default}" ]]; then
        return 0
    else
        return 1
    fi
}

# Logger file descriptor for level
#
# Usage:
#   _logger_fd_for_level <outvar> <level>
#
# Parameters:
#   <outvar>: variable name to store the file descriptor
#   <level>: log level string (e.g. "DEBUG", "INFO", etc.)
#
# Examples:
#   _logger_fd_for_level outvar "DEBUG"
function _logger_fd_for_level() {
    local -n _outvar="${1:?"${FUNCNAME[0]} need outvar"}"; shift
    local _level="${1:?"${FUNCNAME[0]} need level"}"

    case "${_level^^}" in
        DEBUG|INFO) _outvar="1" ;;  # stdout
        WARN|ERROR|FATAL) _outvar="2" ;; # stderr
        *) _outvar="1" ;; # Default to stdout
    esac
}

# Logger header color
#
# Usage:
#   _logger_header_color <outvar> <level>
#
# Parameters:
#   <outvar>: variable name to store the header color
#   <level>: log level string (e.g. "DEBUG", "INFO", etc.)
#
# Examples:
#   _logger_header_color outvar "DEBUG"
function _logger_header_color() {
    local -n _outvar="${1:?"${FUNCNAME[0]} need outvar."}"; shift
    local _level="${1:?"${FUNCNAME[0]} need level."}"
    local _reset="${TTY_CLR_RESET:-}" _color=""

    case "${_level^^}" in
        DEBUG) _color="${TTY_CLR_BLUE}"   ;;
        INFO)  _color="${TTY_CLR_GREEN}"  ;;
        WARN)  _color="${TTY_CLR_YELLOW}" ;;
        ERROR) _color="${TTY_CLR_RED}"    ;;
        FATAL) _color="${TTY_BOLD_RED}"   ;;
        *)     _color="${TTY_CLR_RESET}"  ;; # Default to reset
    esac

    _outvar="${_color}${_level}${_reset}"
}

# Logger color control for file descriptor
#
# Usage:
#   _logger_color_control <fd>
#
# Parameters:
#   <fd>: logger file descriptor (1 for stdout, 2 for stderr)
#
# Examples:
#   _logger_color_control "${fd}"
function _logger_color_control() {
    local _fd="${1:?"${FUNCNAME[0]} need fd."}";
    if { [[ -t 1 && "${_fd}" -eq 1 ]] || [[ -t 2 && "${_fd}" -eq 2 ]]; } && \
    [[ "${LOG_COLOR}" != "false" ]]; then
        return 0
    else
        return 1
    fi
}

# Logger message formatter
#
# Usage:
#   _logger_formatter <level_str> <fd> <message>
#
# Parameters:
#   <level_str>: log level string (e.g. "DEBUG", "INFO", etc.)
#   <fd>: output file descriptor (1 for stdout, 2 for stderr)
#   <message>: log message
#
# Examples:
#   _logger_formatter "DEBUG" "1" "This is a debug message"
function _logger_formatter() {
    local _level="${1:?${FUNCNAME[0]} need level.}"; shift
    local _fd="${1:?${FUNCNAME[0]} need fd.}"; shift

    local _date="" _funcname="" _source=""
    _date="$(date +"%y-%m-%d %H:%M:%S")"
    _source="${BASH_SOURCE[3]##*/}"
    _funcname=${FUNCNAME[3]:-main}

    printf "%s [%s] [%s] [%s] %s\n" \
        "${_date}" \
        "${_source%.*}" \
        "${_funcname}" \
        "${_level}" \
        "$*" >&"${_fd}"
}

# logger print
#
# Usage:
#   _logger_print <level> <message>
#
# Parameters:
#   <level_str>: log level string (e.g. "DEBUG", "INFO", etc.)
#   <message>: log message
#
# Examples:
#   _logger_print "DEBUG" "This is a debug message"
function _logger_print() {
    local _level="${1:?"${FUNCNAME[0]} need level."}"
    local _level_str="${1:?"${FUNCNAME[0]} need level."}"; shift
    local _level_fd=""

    _logger_should_print "${_level}" || return 0

    _logger_fd_for_level _level_fd "${_level}"

    _logger_color_control "${_level_fd}" && \
     _logger_header_color _level_str "${_level}"

    _logger_formatter "${_level_str}" "${_level_fd}" "$*"
}

function log_debug() { _logger_print "DEBUG" "$*"; }
function log_info()  { _logger_print "INFO"  "$*"; }
function log_warn()  { _logger_print "WARN"  "$*"; }
function log_error() { _logger_print "ERROR" "$*"; }
function log_fatal() { _logger_print "FATAL" "$*"; exit 1; }

_support_color
