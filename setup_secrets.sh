#!/usr/bin/env bash
# setup_secrets.sh — init_ubuntu sensitive-data sub-tool (PRD §14, issue #44)
#
# Standalone tool, deliberately decoupled from the install engine: it shares
# lib/logger.sh / lib/i18n.sh / lib/config.sh / lib/secrets.sh only — no
# module pipeline, no registry/resolver/runner/dispatcher coupling, so the
# TUI can simply fork it from a "Manage Secrets" menu entry.
#
# Subcommands (issues #44 + #68):
#   ssh-key generate [--type t] [--file path] [--comment c] [--no-passphrase]
#   ssh-key load     [--file path]
#   ssh-key copy <user@host> [--file path]
#   ssh-key list                          (public keys / agent identities only)
#   ssh-key remove [--file <path>] | <name> [--yes]   (DESTRUCTIVE)
#   token set <name>      (value via interactive prompt or stdin pipe)
#   token get <name>      (value to stdout, nothing else on stdout)
#   gpg generate / gpg import [<file>] / gpg list   (list = id/uid/fpr only)
#   list / remove <name>
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

# ── i18n: user-facing interactive prompts (issue #185) ───────────────────────
# Only human-readable prompts are localized; every log_* call stays English
# (secrets diagnostics are operator-facing, not end-user-facing).
# kcov-exclude-start (i18n data table; excluded from coverage — kcov counts each entry line as uncoverable, issue #185)
declare -gA SECRETS_ENTRY_I18N=(
    [en.token_prompt]="Enter value for token {0}: "
    [zh-TW.token_prompt]="請輸入權杖 {0} 的值："
)
# kcov-exclude-end
# SECRETS_ENTRY_I18N is consumed by i18n_t via a nameref on the table NAME passed
# as a bareword argument — static analysis cannot follow that indirection, so
# make the read explicit here to keep shellcheck honest (no disable directive).
: "${SECRETS_ENTRY_I18N[@]+x}"

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
  ssh-key list         List public SSH keys (~/.ssh/*.pub) and, when an agent
                       is running, the identities it holds (ssh-add -l).
                       READ-ONLY: public material / fingerprints only — never
                       any private key.
  ssh-key remove [--file <path>] | <name> [--yes]
                       DESTRUCTIVE: delete a key pair (private + .pub). <name>
                       resolves under ~/.ssh; --file must also live under
                       ~/.ssh (traversal / absolute escapes are rejected, same
                       guard as the secret store). When stdin is not a tty the
                       deletion proceeds only with --yes (the TUI layers its
                       own type-to-confirm on top; non-interactive callers must
                       pass --yes explicitly).

  token set <name>     Store a token/secret under <name>. The value is read
                       from an interactive no-echo prompt (or from a stdin
                       pipe in automation) — never from argv, so it cannot
                       leak into `ps` output or shell history.
  token get <name>     Print the stored value to stdout (and nothing else
                       on stdout, so it is pipe-safe). Careful: redirecting
                       it on an interactive shell can land it in history.
  gpg generate         Generate a GPG key pair (gpg --full-generate-key;
                       all prompts are owned by gpg on its own tty).
  gpg import [<file>]  Import GPG key material from <file> (or stdin).
  gpg list             List GPG keys — key id / uid / fingerprint only
                       (gpg --list-keys). READ-ONLY: private key material is
                       never listed or exported.
  list                 List stored secret names — names only, never values.
  remove <name>        Delete the named secret from the active backend.

  help                 Show this help.
  version              Show version.

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

# READ-ONLY: enumerate public SSH key material only. Public keys (~/.ssh/*.pub)
# and agent-loaded identities (ssh-add -l) are safe to print; private key files
# are deliberately never opened.
_secrets_ssh_key_list() {
    if (( $# != 0 )); then
        log_error "ssh-key list takes no arguments"
        exit 2
    fi
    local _ssh_dir="${HOME}/.ssh"
    local _found=false _pub
    if [[ -d "${_ssh_dir}" ]]; then
        for _pub in "${_ssh_dir}"/*.pub; do
            [[ -e "${_pub}" ]] || continue
            _found=true
            # Path + the public key line itself (public by definition).
            printf '%s: %s\n' "${_pub}" "$(cat -- "${_pub}")"
        done
    fi

    # Agent identities are fingerprints only — never private material.
    if [[ -n "${SSH_AUTH_SOCK:-}" ]] && command -v ssh-add >/dev/null 2>&1; then
        local _agent
        if _agent="$(ssh-add -l 2>/dev/null)" && [[ -n "${_agent}" ]]; then
            printf 'agent identities:\n%s\n' "${_agent}"
            _found=true
        fi
    fi

    if [[ "${_found}" == false ]]; then
        log_info "no public SSH keys found in ${_ssh_dir} and no agent identities"
    fi
}

# DESTRUCTIVE: delete a key pair (private + .pub). The target is resolved to an
# absolute path and constrained to ~/.ssh so traversal / absolute escapes can
# never delete files elsewhere (same guard intent as the secret store path).
_secrets_ssh_key_remove() {
    local _file="" _name="" _yes=false
    while (( $# > 0 )); do
        case "$1" in
            --file) _file="${2:?--file needs a value}"; shift 2 ;;
            --yes)  _yes=true; shift ;;
            -*) log_error "unknown option for ssh-key remove: $1"; exit 2 ;;
            *)
                if [[ -n "${_name}" ]]; then
                    log_error "unexpected extra argument: $1"
                    exit 2
                fi
                _name="$1"; shift
                ;;
        esac
    done

    if [[ -n "${_file}" && -n "${_name}" ]]; then
        log_error "ssh-key remove takes either --file <path> OR <name>, not both"
        exit 2
    fi

    local _ssh_dir _target
    _ssh_dir="$(cd -- "${HOME}" 2>/dev/null && pwd -P)/.ssh"
    if [[ -n "${_name}" ]]; then
        # A bare name must be a single safe basename (no separators / traversal).
        if [[ ! "${_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]]; then
            log_error "invalid ssh-key name '${_name}' (allowed: alnum start, then [A-Za-z0-9._@-])"
            exit 2
        fi
        _target="${_ssh_dir}/${_name}"
    elif [[ -n "${_file}" ]]; then
        # Strip a trailing .pub so callers can name either half of the pair.
        _file="${_file%.pub}"
        local _dir _base
        _dir="$(dirname -- "${_file}")"
        _base="$(basename -- "${_file}")"
        # Canonicalize the directory; reject anything outside ~/.ssh (this also
        # collapses any ../ segments, so a traversal cannot escape).
        local _real_dir
        if ! _real_dir="$(cd -- "${_dir}" 2>/dev/null && pwd -P)"; then
            log_error "ssh-key remove: cannot resolve directory of '${_file}'"
            exit 2
        fi
        if [[ "${_real_dir}" != "${_ssh_dir}" ]]; then
            log_error "ssh-key remove: refusing to delete outside ${_ssh_dir} (got '${_real_dir}/${_base}')"
            exit 2
        fi
        if [[ "${_base}" == "." || "${_base}" == ".." || "${_base}" == */* ]]; then
            log_error "invalid ssh-key file basename '${_base}'"
            exit 2
        fi
        _target="${_real_dir}/${_base}"
    else
        log_error "ssh-key remove requires --file <path> or a <name>"
        exit 2
    fi

    if [[ ! -e "${_target}" && ! -e "${_target}.pub" ]]; then
        log_error "no SSH key pair found at: ${_target}"
        exit 1
    fi

    # Confirmation contract: in a non-interactive context (no tty on stdin) the
    # destructive delete proceeds ONLY with --yes. Interactively, prompt once.
    # The TUI passes --yes after its own type-to-confirm widget.
    if [[ "${_yes}" != true ]]; then
        if [[ ! -t 0 ]]; then
            log_error "ssh-key remove is destructive; pass --yes for non-interactive deletion"
            exit 2
        fi
        local _reply=""
        printf 'Delete SSH key pair %s (private + .pub)? [y/N] ' "${_target}" > /dev/tty
        IFS= read -r _reply < /dev/tty
        if [[ ! "${_reply}" =~ ^[Yy]$ ]]; then
            log_info "ssh-key remove aborted"
            exit 0
        fi
    fi

    rm -f -- "${_target}" "${_target}.pub"
    log_event info setup_secrets ssh_key_remove "file=${_target}"
    log_info "SSH key pair removed: ${_target}"
}

_secrets_cmd_ssh_key() {
    if (( $# == 0 )); then
        log_error "ssh-key requires an action: generate | load | copy <user@host> | list | remove"
        exit 2
    fi
    local _action="$1"; shift
    case "${_action}" in
        generate) _secrets_ssh_key_generate "$@" ;;
        load)     _secrets_ssh_key_load "$@" ;;
        copy)     _secrets_ssh_key_copy "$@" ;;
        list)     _secrets_ssh_key_list "$@" ;;
        remove)   _secrets_ssh_key_remove "$@" ;;
        *)
            log_error "unknown ssh-key action '${_action}' (valid: generate | load | copy | list | remove)"
            exit 2
            ;;
    esac
}

# ── token actions (issue #68) ────────────────────────────────────────────────

_secrets_token_set() {
    if (( $# != 1 )); then
        log_error "usage: setup_secrets token set <name> — the value is prompted for (or piped on stdin), never passed as an argument"
        exit 2
    fi
    local _name="$1"

    if [[ -t 0 ]]; then
        # Interactive: no-echo prompt on the tty. The value never appears in
        # argv (`ps`) or shell history (AC-20); printf is a bash builtin, so
        # the pipe below never exec()s the value either.
        local _value=""
        i18n_t SECRETS_ENTRY_I18N token_prompt "${_name}" > /dev/tty
        IFS= read -rs _value < /dev/tty
        printf '\n' > /dev/tty
        if [[ -z "${_value}" ]]; then
            log_error "empty token value rejected"
            exit 1
        fi
        printf '%s' "${_value}" | secrets_store "${_name}"
    else
        # Automation: the value arrives on the stdin pipe and flows straight
        # through to the backend without touching argv or the filesystem.
        secrets_store "${_name}"
    fi
    log_info "token '${_name}' stored"
}

_secrets_token_get() {
    if (( $# != 1 )); then
        log_error "usage: setup_secrets token get <name>"
        exit 2
    fi
    # stdout carries the secret value and nothing else (pipe-safe);
    # diagnostics from the lib go to stderr only.
    secrets_retrieve "$1"
}

_secrets_cmd_token() {
    if (( $# == 0 )); then
        log_error "token requires an action: set <name> | get <name>"
        exit 2
    fi
    local _action="$1"; shift
    case "${_action}" in
        set) _secrets_token_set "$@" ;;
        get) _secrets_token_get "$@" ;;
        *)
            log_error "unknown token action '${_action}' (valid: set | get)"
            exit 2
            ;;
    esac
}

# ── gpg actions (issue #68) ──────────────────────────────────────────────────

_secrets_require_gpg() {
    if ! command -v gpg >/dev/null 2>&1; then
        log_error "gpg is not installed (install it first: sudo apt install gnupg)"
        exit 3
    fi
}

_secrets_gpg_generate() {
    if (( $# != 0 )); then
        log_error "gpg generate takes no arguments"
        exit 2
    fi
    _secrets_require_gpg
    # gpg owns every interactive prompt (key parameters AND the passphrase)
    # on its own tty — nothing sensitive ever passes through our argv or
    # shell history (AC-20).
    gpg --full-generate-key
    log_event info setup_secrets gpg_generate
    log_info "GPG key generated"
}

_secrets_gpg_import() {
    local _file=""
    case $# in
        0) ;;
        1) _file="$1" ;;
        *) log_error "usage: setup_secrets gpg import [<file>]"; exit 2 ;;
    esac
    _secrets_require_gpg

    if [[ -n "${_file}" ]]; then
        if [[ ! -f "${_file}" ]]; then
            log_error "key file not found: ${_file}"
            exit 1
        fi
        gpg --import "${_file}"
    else
        if [[ -t 0 ]]; then
            log_error "gpg import needs a <file> argument or key material on stdin"
            exit 2
        fi
        gpg --import
    fi
    log_event info setup_secrets gpg_import
    log_info "GPG key material imported"
}

# READ-ONLY: list public key id / uid / fingerprint via `gpg --list-keys`.
# `--list-secret-keys` and any `--export*` are deliberately never used, so no
# private key material is ever read or emitted.
_secrets_gpg_list() {
    if (( $# != 0 )); then
        log_error "gpg list takes no arguments"
        exit 2
    fi
    _secrets_require_gpg
    gpg --list-keys --keyid-format long --fingerprint
}

_secrets_cmd_gpg() {
    if (( $# == 0 )); then
        log_error "gpg requires an action: generate | import [<file>] | list"
        exit 2
    fi
    local _action="$1"; shift
    case "${_action}" in
        generate) _secrets_gpg_generate "$@" ;;
        import)   _secrets_gpg_import "$@" ;;
        list)     _secrets_gpg_list "$@" ;;
        *)
            log_error "unknown gpg action '${_action}' (valid: generate | import | list)"
            exit 2
            ;;
    esac
}

# ── list / remove actions (issue #68) ────────────────────────────────────────

_secrets_cmd_list() {
    if (( $# != 0 )); then
        log_error "list takes no arguments"
        exit 2
    fi
    # stdout carries stored names only, one per line — values are never
    # printed (by design; see lib/secrets.sh). No log_info here so stdout
    # stays machine-consumable.
    secrets_list
}

_secrets_cmd_remove() {
    if (( $# != 1 )); then
        log_error "usage: setup_secrets remove <name>"
        exit 2
    fi
    secrets_remove "$1"
    log_info "secret '$1' removed"
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
        token)
            _secrets_cmd_token "$@"
            ;;
        list)
            _secrets_cmd_list "$@"
            ;;
        remove)
            _secrets_cmd_remove "$@"
            ;;
        gpg)
            _secrets_cmd_gpg "$@"
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
