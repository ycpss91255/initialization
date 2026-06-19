#!/usr/bin/env bash
# lib/secrets.sh — secrets storage backend abstraction (PRD §14, issue #44)
#
# Used by setup_secrets.sh only — NOT part of the module pipeline.
#
# Public API (generic; `token set/get`, `list`, `remove` subcommands from
# issue #68 mount directly on these — no backend work needed there):
#   secrets_backend_resolve        # prints chosen backend name on stdout
#   secrets_store <name>           # secret read from STDIN (never argv)
#   secrets_retrieve <name>        # secret written to STDOUT
#   secrets_exists <name>          # 0=yes 1=no
#   secrets_list                   # stored names only, one per line
#   secrets_remove <name>
#
# Backend contract: each backend <b> (dashes mapped to underscores)
# implements:
#   _secrets_backend_<b>_available
#   _secrets_backend_<b>_store <name>      (secret on stdin)
#   _secrets_backend_<b>_retrieve <name>   (secret on stdout)
#   _secrets_backend_<b>_exists <name>
#   _secrets_backend_<b>_list
#   _secrets_backend_<b>_remove <name>
#
# Backend priority (PRD §14.3): pass -> gnome-keyring -> encrypted-file.
# Selection honors (highest first):
#   1. $INIT_UBUNTU_SECRETS_BACKEND  (env; automation/test hook)
#   2. config.ini  [secrets] backend  (auto | pass | gnome-keyring |
#      encrypted-file)
#   3. autoselect by availability
#
# Security invariants (PRD §14.3 / architecture.md §15.5):
#   - Plaintext is NEVER written to disk; the encrypted-file backend stores
#     only openssl-enc AES-256-CBC + PBKDF2 ciphertext.
#   - Secret material travels via stdin/stdout pipes only — never argv
#     (visible in `ps`), never shell history.
#   - The encryption passphrase reaches openssl via `-pass env:` (child
#     process env), never argv. Interactive entry uses `read -rs` on
#     /dev/tty. Note: openssl enc has no argon2id support, so PBKDF2 with
#     a high iteration count stands in for architecture.md §15.5's KDF
#     until/unless `age` becomes the fallback encryptor.
#   - Secret values are never logged (names are fine — `list` exposes them
#     by design).

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not an executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# PBKDF2 work factor for the encrypted-file backend (OWASP 2023 baseline
# for PBKDF2-HMAC-SHA512 is 210k; round up).
readonly SECRETS_PBKDF2_ITER=300000

readonly SECRETS_PASS_PREFIX="init_ubuntu"

# i18n_t (issue #185) lives in lib/i18n.sh. setup_secrets.sh sources it before
# this lib, but make the lib self-sufficient (unit specs source secrets.sh
# directly) by loading it on demand when the helper is not yet defined.
if ! declare -F i18n_t >/dev/null 2>&1; then
    # shellcheck source=lib/i18n.sh
    source "${BASH_SOURCE[0]%/*}/i18n.sh"
fi

# ── i18n: user-facing interactive prompts (issue #185) ───────────────────────
# Only the human-readable /dev/tty passphrase prompts are localized; every
# log_* diagnostic stays English (operator-facing). i18n_t is provided by
# lib/i18n.sh, which setup_secrets.sh sources before this lib; these prompts
# only fire on the interactive (no passphrase-file) path.
declare -gA SECRETS_I18N=(
    [en.passphrase_prompt]="Enter passphrase for the encrypted-file secrets backend: "
    [zh-TW.passphrase_prompt]="請輸入加密檔案密鑰後端的密碼短語："
    [en.passphrase_confirm]="Confirm passphrase: "
    [zh-TW.passphrase_confirm]="請再次確認密碼短語："
)
# SECRETS_I18N is consumed by i18n_t via a nameref on the table NAME passed as a
# bareword argument — static analysis cannot follow that indirection, so make
# the read explicit here to keep shellcheck honest (no disable directive).
: "${SECRETS_I18N[@]+x}"

# ── backend selection ────────────────────────────────────────────────────────

_secrets_backend_pass_available() {
    command -v pass >/dev/null 2>&1
}

_secrets_backend_gnome_keyring_available() {
    command -v secret-tool >/dev/null 2>&1 && \
        [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]
}

_secrets_backend_encrypted_file_available() {
    command -v openssl >/dev/null 2>&1
}

# secrets_backend_resolve
#   Print the selected backend name (pass | gnome-keyring | encrypted-file)
#   on stdout. Diagnostics go to stderr only, so callers can safely
#   command-substitute. Exit codes: 0 ok, 2 unknown backend name,
#   3 requested backend unavailable on this machine.
secrets_backend_resolve() {
    local _requested="${INIT_UBUNTU_SECRETS_BACKEND:-}"
    if [[ -z "${_requested}" ]] && declare -F config_get >/dev/null 2>&1; then
        _requested="$(config_get secrets.backend 2>/dev/null)" || _requested=""
    fi

    case "${_requested}" in
        ""|auto)
            ;;  # fall through to autoselect
        pass|gnome-keyring|encrypted-file)
            if "_secrets_backend_${_requested//-/_}_available"; then
                printf '%s\n' "${_requested}"
                return 0
            fi
            log_error "secrets backend '${_requested}' was requested but is not available on this machine"
            return 3
            ;;
        *)
            log_error "unknown secrets backend '${_requested}' (valid: auto | pass | gnome-keyring | encrypted-file)"
            return 2
            ;;
    esac

    local _backend
    for _backend in pass gnome-keyring encrypted-file; do
        if "_secrets_backend_${_backend//-/_}_available"; then
            printf '%s\n' "${_backend}"
            return 0
        fi
    done

    log_error "no secrets backend available (need one of: pass, secret-tool + DBus, openssl)"
    return 3
}

# ── name validation ──────────────────────────────────────────────────────────

# Secret names become file basenames in the encrypted-file backend, so
# path separators / dot-dot / leading dashes are all rejected up front.
_secrets_validate_name() {
    local _name="${1:-}"
    if [[ "${_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]]; then
        return 0
    fi
    log_error "invalid secret name '${_name}' (allowed: alnum start, then [A-Za-z0-9._@-])"
    return 2
}

# ── generic API (dispatch) ───────────────────────────────────────────────────

# secrets_store <name>   — secret read from stdin (NEVER as an argument:
# argv is visible in `ps` and lands in shell history when typed).
secrets_store() {
    if (( $# != 1 )); then
        log_error "secrets_store takes exactly one <name>; the secret itself is read from stdin"
        return 2
    fi
    local _name="$1"
    _secrets_validate_name "${_name}" || return 2
    local _backend
    _backend="$(secrets_backend_resolve)" || return $?
    log_event info setup_secrets secret_store "name=${_name}" "backend=${_backend}"
    "_secrets_backend_${_backend//-/_}_store" "${_name}"
}

secrets_retrieve() {
    local _name="${1:?secrets_retrieve needs <name>}"
    _secrets_validate_name "${_name}" || return 2
    local _backend
    _backend="$(secrets_backend_resolve)" || return $?
    "_secrets_backend_${_backend//-/_}_retrieve" "${_name}"
}

secrets_exists() {
    local _name="${1:?secrets_exists needs <name>}"
    _secrets_validate_name "${_name}" || return 2
    local _backend
    _backend="$(secrets_backend_resolve)" || return $?
    "_secrets_backend_${_backend//-/_}_exists" "${_name}"
}

secrets_list() {
    local _backend
    _backend="$(secrets_backend_resolve)" || return $?
    "_secrets_backend_${_backend//-/_}_list"
}

secrets_remove() {
    local _name="${1:?secrets_remove needs <name>}"
    _secrets_validate_name "${_name}" || return 2
    local _backend
    _backend="$(secrets_backend_resolve)" || return $?
    log_event info setup_secrets secret_remove "name=${_name}" "backend=${_backend}"
    "_secrets_backend_${_backend//-/_}_remove" "${_name}"
}

# ── backend: pass ────────────────────────────────────────────────────────────

_secrets_backend_pass_store() {
    pass insert -m -f "${SECRETS_PASS_PREFIX}/$1" >/dev/null
}

_secrets_backend_pass_retrieve() {
    pass show "${SECRETS_PASS_PREFIX}/$1"
}

_secrets_backend_pass_exists() {
    pass show "${SECRETS_PASS_PREFIX}/$1" >/dev/null 2>&1
}

_secrets_backend_pass_list() {
    local _store="${PASSWORD_STORE_DIR:-${HOME}/.password-store}/${SECRETS_PASS_PREFIX}"
    [[ -d "${_store}" ]] || return 0
    local _f
    for _f in "${_store}"/*.gpg; do
        [[ -e "${_f}" ]] || continue
        _f="${_f##*/}"
        printf '%s\n' "${_f%.gpg}"
    done
}

_secrets_backend_pass_remove() {
    pass rm -f "${SECRETS_PASS_PREFIX}/$1" >/dev/null
}

# ── backend: gnome-keyring (via secret-tool / libsecret) ────────────────────

_secrets_backend_gnome_keyring_store() {
    # secret-tool reads the secret from stdin when no tty is forced
    secret-tool store --label "${SECRETS_PASS_PREFIX}/$1" \
        service "${SECRETS_PASS_PREFIX}" name "$1"
}

_secrets_backend_gnome_keyring_retrieve() {
    secret-tool lookup service "${SECRETS_PASS_PREFIX}" name "$1"
}

_secrets_backend_gnome_keyring_exists() {
    secret-tool lookup service "${SECRETS_PASS_PREFIX}" name "$1" >/dev/null 2>&1
}

_secrets_backend_gnome_keyring_list() {
    secret-tool search --all service "${SECRETS_PASS_PREFIX}" 2>/dev/null | \
        sed -n 's/^attribute\.name = //p'
}

_secrets_backend_gnome_keyring_remove() {
    secret-tool clear service "${SECRETS_PASS_PREFIX}" name "$1"
}

# ── backend: encrypted-file (openssl enc; PRD §14.3 fallback) ───────────────

_secrets_file_dir() {
    printf '%s' "${INIT_UBUNTU_SECRETS_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/init_ubuntu/secrets}"
}

# _secrets_passphrase_read <outvar> <encrypt|decrypt>
#   Source priority:
#     1. $INIT_UBUNTU_SECRETS_PASSPHRASE_FILE (first line; automation/tests)
#     2. interactive /dev/tty prompt via `read -rs` (never echoed, never in
#        argv/history); encrypt mode asks twice and compares.
_secrets_passphrase_read() {
    local -n _pp_out="${1:?_secrets_passphrase_read needs <outvar>}"
    local _mode="${2:?_secrets_passphrase_read needs <encrypt|decrypt>}"

    if [[ -n "${INIT_UBUNTU_SECRETS_PASSPHRASE_FILE:-}" ]]; then
        IFS= read -r _pp_out < "${INIT_UBUNTU_SECRETS_PASSPHRASE_FILE}" || true
        if [[ -z "${_pp_out}" ]]; then
            log_error "passphrase file is empty: ${INIT_UBUNTU_SECRETS_PASSPHRASE_FILE}"
            return 1
        fi
        return 0
    fi

    if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        log_error "no tty available for the passphrase prompt (set INIT_UBUNTU_SECRETS_PASSPHRASE_FILE for non-interactive use)"
        return 1
    fi

    local _p1="" _p2=""
    i18n_t SECRETS_I18N passphrase_prompt > /dev/tty
    IFS= read -rs _p1 < /dev/tty
    printf '\n' > /dev/tty
    if [[ -z "${_p1}" ]]; then
        log_error "empty passphrase rejected"
        return 1
    fi
    if [[ "${_mode}" == "encrypt" ]]; then
        i18n_t SECRETS_I18N passphrase_confirm > /dev/tty
        IFS= read -rs _p2 < /dev/tty
        printf '\n' > /dev/tty
        if [[ "${_p1}" != "${_p2}" ]]; then
            log_error "passphrases do not match"
            return 1
        fi
    fi
    _pp_out="${_p1}"
}

_secrets_backend_encrypted_file_store() {
    local _name="$1"
    local _dir; _dir="$(_secrets_file_dir)"
    local _pp=""
    _secrets_passphrase_read _pp encrypt || return 1

    ( umask 077; mkdir -p "${_dir}" ) || return 1
    chmod 700 "${_dir}"

    # Plaintext flows stdin -> openssl pipe; the passphrase rides the child
    # env (`-pass env:`) — neither ever touches argv or the filesystem.
    # Write ciphertext to a temp file first, then rename (atomic-ish).
    local _tmp="${_dir}/.${_name}.enc.tmp.$$"
    if ! ( umask 077
           INIT_UBUNTU_SECRETS_PASS="${_pp}" openssl enc \
               -aes-256-cbc -md sha512 -pbkdf2 -iter "${SECRETS_PBKDF2_ITER}" \
               -salt -pass env:INIT_UBUNTU_SECRETS_PASS > "${_tmp}" ); then
        rm -f "${_tmp}"
        log_error "encryption failed for '${_name}'"
        return 1
    fi
    mv -f "${_tmp}" "${_dir}/${_name}.enc"
    chmod 600 "${_dir}/${_name}.enc"
}

_secrets_backend_encrypted_file_retrieve() {
    local _name="$1"
    local _file; _file="$(_secrets_file_dir)/${_name}.enc"
    if [[ ! -f "${_file}" ]]; then
        log_error "no stored secret named '${_name}'"
        return 1
    fi
    local _pp=""
    _secrets_passphrase_read _pp decrypt || return 1

    if ! INIT_UBUNTU_SECRETS_PASS="${_pp}" openssl enc -d \
            -aes-256-cbc -md sha512 -pbkdf2 -iter "${SECRETS_PBKDF2_ITER}" \
            -pass env:INIT_UBUNTU_SECRETS_PASS -in "${_file}"; then
        log_error "decryption failed for '${_name}' (wrong passphrase?)"
        return 1
    fi
}

_secrets_backend_encrypted_file_exists() {
    [[ -f "$(_secrets_file_dir)/$1.enc" ]]
}

_secrets_backend_encrypted_file_list() {
    local _dir; _dir="$(_secrets_file_dir)"
    [[ -d "${_dir}" ]] || return 0
    local _f
    for _f in "${_dir}"/*.enc; do
        [[ -e "${_f}" ]] || continue
        _f="${_f##*/}"
        printf '%s\n' "${_f%.enc}"
    done
}

_secrets_backend_encrypted_file_remove() {
    local _file; _file="$(_secrets_file_dir)/$1.enc"
    if [[ ! -f "${_file}" ]]; then
        log_error "no stored secret named '$1'"
        return 1
    fi
    rm -f "${_file}"
}
