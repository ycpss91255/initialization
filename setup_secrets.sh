#!/usr/bin/env bash
# setup_secrets.sh — init_ubuntu sensitive-data sub-tool (PRD §14, issue #44)
#
# Standalone tool, deliberately decoupled from the install engine: it shares
# lib/logger.sh / lib/i18n.sh / lib/config.sh / lib/secrets.sh only — no
# module pipeline, no registry/resolver/runner/dispatcher coupling, so the
# TUI can simply fork it from a "Manage Secrets" menu entry.
#
# Subcommands (issue #44 scope):
#   ssh-key generate [--type t] [--file path] [--comment c] [--no-passphrase]
#   ssh-key load     [--file path]
#   ssh-key copy <user@host> [--file path]
#
# Reserved for issue #68 (the lib/secrets.sh backend API they mount on is
# already in place): gpg generate, token set/get, list, remove.
#
# Security (AC-20): anything sensitive (key passphrases, future tokens) is
# entered through interactive prompts owned by this tool or by ssh-keygen
# itself — never through argv, so nothing sensitive can land in `ps` output
# or shell history.

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# ── Path resolution ──────────────────────────────────────────────────────────
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export REPO_ROOT="${SCRIPT_PATH}"
export LIB_DIR="${REPO_ROOT}/lib"

# ── Defaults for logging / env-driven flags ──────────────────────────────────
export USER="${USER:-"$(whoami)"}"
export HOME="${HOME:-"/home/${USER}"}"
export LOG_LEVEL="${LOG_LEVEL:-INFO}"
export LOG_COLOR="${LOG_COLOR:-true}"

# ── Source shared libs (logger / i18n / config / secrets only) ───────────────
# shellcheck source=lib/logger.sh
source "${LIB_DIR}/logger.sh"
_logger_ensure_trace_id
# shellcheck source=lib/i18n.sh
source "${LIB_DIR}/i18n.sh"
# shellcheck source=lib/config.sh
source "${LIB_DIR}/config.sh"
# shellcheck source=lib/secrets.sh
source "${LIB_DIR}/secrets.sh"

i18n_resolve_init_ubuntu_lang

: "${INIT_UBUNTU_VERSION:=0.1.0-draft}"

# ── usage ────────────────────────────────────────────────────────────────────

_secrets_usage() {
    cat <<'EOF'
Usage: setup_secrets.sh <command> [options]

Commands:
  ssh-key generate [--type <ed25519|ecdsa|rsa>] [--file <path>]
                   [--comment <text>] [--no-passphrase]
                       Generate an SSH key pair. The passphrase prompt is
                       handled by ssh-keygen itself on the tty — it never
                       appears in argv or shell history.
  ssh-key load     [--file <path>]
                       Add a private key to the running ssh-agent.
  ssh-key copy <user@host> [--file <path>]
                       Install the public key on a remote host (ssh-copy-id).

  help                 Show this help.
  version              Show version.

Planned (issue #68; not implemented yet):
  gpg generate / token set <name> / token get <name> / list / remove <name>

Storage backend selection (for token storage; PRD §14.3):
  pass -> gnome-keyring -> encrypted file (~/.config/init_ubuntu/secrets/).
  Override with `setup_ubuntu config set secrets.backend <name>` or the
  INIT_UBUNTU_SECRETS_BACKEND environment variable.
EOF
}

# ── ssh-key actions ──────────────────────────────────────────────────────────

_secrets_ssh_key_generate() {
    local _type="ed25519" _file="" _comment="" _no_passphrase=false
    while (( $# > 0 )); do
        case "$1" in
            --type)          _type="${2:?--type needs a value}"; shift 2 ;;
            --file)          _file="${2:?--file needs a value}"; shift 2 ;;
            --comment)       _comment="${2:?--comment needs a value}"; shift 2 ;;
            --no-passphrase) _no_passphrase=true; shift ;;
            *) log_error "unknown option for ssh-key generate: $1"; exit 2 ;;
        esac
    done

    case "${_type}" in
        ed25519|ecdsa|rsa) ;;
        *)
            log_error "unsupported key type '${_type}' (valid: ed25519 | ecdsa | rsa)"
            exit 2
            ;;
    esac
    [[ -n "${_file}" ]] || _file="${HOME}/.ssh/id_${_type}"
    [[ -n "${_comment}" ]] || _comment="${USER}@${HOSTNAME:-localhost}"

    if [[ -e "${_file}" || -e "${_file}.pub" ]]; then
        log_error "refusing to overwrite existing key: ${_file}"
        exit 1
    fi
    ( umask 077; mkdir -p "$(dirname -- "${_file}")" )

    local -a _args=(-t "${_type}" -f "${_file}" -C "${_comment}")
    if [[ "${_no_passphrase}" == true ]]; then
        _args+=(-N "")
    fi
    # No --no-passphrase: ssh-keygen prompts for the passphrase on its own
    # tty. It never travels through our argv or the shell history (AC-20).
    ssh-keygen "${_args[@]}"
    log_event info setup_secrets ssh_key_generate "type=${_type}"
    log_info "SSH key generated: ${_file}"
}

_secrets_ssh_key_load() {
    local _file=""
    while (( $# > 0 )); do
        case "$1" in
            --file) _file="${2:?--file needs a value}"; shift 2 ;;
            *) log_error "unknown option for ssh-key load: $1"; exit 2 ;;
        esac
    done
    [[ -n "${_file}" ]] || _file="${HOME}/.ssh/id_ed25519"

    if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
        log_error "no running ssh-agent detected (SSH_AUTH_SOCK is unset)"
        log_error "hint: start one with:  eval \"\$(ssh-agent -s)\""
        exit 3
    fi
    if [[ ! -f "${_file}" ]]; then
        log_error "key file not found: ${_file}"
        exit 1
    fi
    # ssh-add prompts for the passphrase on its own tty (AC-20).
    ssh-add "${_file}"
    log_event info setup_secrets ssh_key_load "file=${_file}"
}

_secrets_ssh_key_copy() {
    local _target="" _file=""
    while (( $# > 0 )); do
        case "$1" in
            --file) _file="${2:?--file needs a value}"; shift 2 ;;
            -*) log_error "unknown option for ssh-key copy: $1"; exit 2 ;;
            *)
                if [[ -n "${_target}" ]]; then
                    log_error "unexpected extra argument: $1"
                    exit 2
                fi
                _target="$1"; shift
                ;;
        esac
    done
    if [[ -z "${_target}" ]]; then
        log_error "ssh-key copy requires a <user@host> target"
        exit 2
    fi
    [[ -n "${_file}" ]] || _file="${HOME}/.ssh/id_ed25519"

    local _pub="${_file}.pub"
    if [[ ! -f "${_pub}" ]]; then
        log_error "public key not found: ${_pub} (generate one first: setup_secrets ssh-key generate)"
        exit 1
    fi
    if ! ssh-copy-id -i "${_pub}" "${_target}"; then
        log_error "ssh-copy-id to '${_target}' failed"
        exit 7
    fi
    log_event info setup_secrets ssh_key_copy "target=${_target}"
    log_info "public key installed on ${_target}"
}

_secrets_cmd_ssh_key() {
    if (( $# == 0 )); then
        log_error "ssh-key requires an action: generate | load | copy <user@host>"
        exit 2
    fi
    local _action="$1"; shift
    case "${_action}" in
        generate) _secrets_ssh_key_generate "$@" ;;
        load)     _secrets_ssh_key_load "$@" ;;
        copy)     _secrets_ssh_key_copy "$@" ;;
        *)
            log_error "unknown ssh-key action '${_action}' (valid: generate | load | copy)"
            exit 2
            ;;
    esac
}

# ── dispatch ─────────────────────────────────────────────────────────────────

main() {
    if (( $# == 0 )); then
        _secrets_usage >&2
        exit 2
    fi
    local _cmd="$1"; shift
    case "${_cmd}" in
        ssh-key)
            _secrets_cmd_ssh_key "$@"
            ;;
        gpg|token|list|remove)
            log_error "'${_cmd}' is not implemented yet — planned for issue #68"
            exit 2
            ;;
        help|-h|--help)
            _secrets_usage
            ;;
        version|--version)
            printf 'setup_secrets %s\n' "${INIT_UBUNTU_VERSION}"
            ;;
        *)
            log_error "unknown subcommand: ${_cmd}"
            _secrets_usage >&2
            exit 2
            ;;
    esac
}

main "$@"
