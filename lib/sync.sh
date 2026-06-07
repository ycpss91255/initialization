#!/usr/bin/env bash
# shellcheck disable=SC2029  # SSH cmd strings intentionally expand ${_remote_path} client-side; value is a controlled tmpfile name, never user-tainted — https://www.shellcheck.net/wiki/SC2029
# lib/sync.sh — SSH push / pull of the install state across machines
#
# Per PRD §16 (Sync mechanism) and doc/architecture.md §16.
#
# Public API:
#   sync_push <user@host> [--modules=<csv>] [--dry-run]
#   sync_pull <user@host> [--dry-run]
#     Both delegate to lib/state_io.sh + ssh/scp.
#
# Security (PRD §16.4):
#   - StrictHostKeyChecking=yes, key auth only (BatchMode=yes prevents any
#     password prompt). We never run ssh-copy-id — the user is told to use
#     setup_secrets ssh-key copy first.
#   - Payload NEVER contains secrets — only module names + manual flags.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

readonly SYNC_SSH_OPTS=(
    -o "StrictHostKeyChecking=yes"
    -o "BatchMode=yes"
    -o "PasswordAuthentication=no"
    -o "ConnectTimeout=10"
)

_sync_require_ssh() {
    if ! command -v ssh >/dev/null 2>&1; then
        printf "[sync] ERROR: ssh not found. Install openssh-client.\n" >&2
        return 1
    fi
    if ! command -v scp >/dev/null 2>&1; then
        printf "[sync] ERROR: scp not found.\n" >&2
        return 1
    fi
}

_sync_test_connection() {
    local _target="$1"
    local _err
    _err="$(ssh "${SYNC_SSH_OPTS[@]}" "${_target}" true 2>&1)"
    local _rc=$?
    if [[ "${_rc}" -ne 0 ]]; then
        printf "[sync] ERROR: cannot ssh to %s\n" "${_target}" >&2
        printf "[sync] ssh said: %s\n" "${_err}" >&2
        printf "[sync] hint: run 'setup_secrets ssh-key copy %s' to install your key first.\n" "${_target}" >&2
        return 7
    fi
}

# ── Public: push ────────────────────────────────────────────────────────────

sync_push() {
    _sync_require_ssh || return 1

    local _target=""
    local _modules_csv=""
    local _dry="false"
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            --modules=*) _modules_csv="${_arg#*=}" ;;
            --dry-run) _dry="true" ;;
            -*) printf "[sync] ERROR: unknown flag %s\n" "${_arg}" >&2; return 2 ;;
            *)
                if [[ -z "${_target}" ]]; then
                    _target="${_arg}"
                else
                    printf "[sync] ERROR: sync_push takes one <user@host>\n" >&2
                    return 2
                fi
                ;;
        esac
    done
    if [[ -z "${_target}" ]]; then
        printf "[sync] ERROR: sync_push needs <user@host>\n" >&2
        return 2
    fi

    if ! declare -F state_io_export >/dev/null 2>&1; then
        printf "[sync] ERROR: lib/state_io.sh not loaded\n" >&2
        return 1
    fi

    if [[ "${_dry}" == "true" ]]; then
        printf "[sync] DRY-RUN: would push to %s\n" "${_target}"
        [[ -n "${_modules_csv}" ]] && printf "[sync] DRY-RUN: filtered modules: %s\n" "${_modules_csv}"
        return 0
    fi

    _sync_test_connection "${_target}" || return $?

    local _tmp
    _tmp="$(mktemp /tmp/init_ubuntu_sync.XXXXXX.json)"
    local -a _export_args=("${_tmp}")
    [[ -n "${_modules_csv}" ]] && _export_args+=("--modules=${_modules_csv}")

    if ! state_io_export "${_export_args[@]}"; then
        rm -f "${_tmp}"
        return 1
    fi

    local _remote_path="/tmp/init_ubuntu_sync.json"
    scp "${SYNC_SSH_OPTS[@]}" "${_tmp}" "${_target}:${_remote_path}" || {
        rm -f "${_tmp}"
        printf "[sync] ERROR: scp upload failed\n" >&2
        return 7
    }
    rm -f "${_tmp}"

    ssh "${SYNC_SSH_OPTS[@]}" "${_target}" "setup_ubuntu import ${_remote_path}" || {
        printf "[sync] ERROR: remote import failed\n" >&2
        return 7
    }
    ssh "${SYNC_SSH_OPTS[@]}" "${_target}" "rm -f ${_remote_path}" || true

    printf "[sync] pushed state to %s OK\n" "${_target}"
}

# ── Public: pull ────────────────────────────────────────────────────────────

sync_pull() {
    _sync_require_ssh || return 1

    local _target=""
    local _dry="false"
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            --dry-run) _dry="true" ;;
            -*) printf "[sync] ERROR: unknown flag %s\n" "${_arg}" >&2; return 2 ;;
            *)
                if [[ -z "${_target}" ]]; then
                    _target="${_arg}"
                else
                    printf "[sync] ERROR: sync_pull takes one <user@host>\n" >&2
                    return 2
                fi
                ;;
        esac
    done
    if [[ -z "${_target}" ]]; then
        printf "[sync] ERROR: sync_pull needs <user@host>\n" >&2
        return 2
    fi

    if [[ "${_dry}" == "true" ]]; then
        printf "[sync] DRY-RUN: would pull from %s\n" "${_target}"
        return 0
    fi

    _sync_test_connection "${_target}" || return $?

    local _remote_path="/tmp/init_ubuntu_sync.json"
    ssh "${SYNC_SSH_OPTS[@]}" "${_target}" "setup_ubuntu export ${_remote_path}" || {
        printf "[sync] ERROR: remote export failed\n" >&2
        return 7
    }

    local _tmp
    _tmp="$(mktemp /tmp/init_ubuntu_sync.XXXXXX.json)"
    scp "${SYNC_SSH_OPTS[@]}" "${_target}:${_remote_path}" "${_tmp}" || {
        rm -f "${_tmp}"
        printf "[sync] ERROR: scp download failed\n" >&2
        return 7
    }

    ssh "${SYNC_SSH_OPTS[@]}" "${_target}" "rm -f ${_remote_path}" || true

    # Print the downloaded file path on stdout so the dispatcher can hand
    # it to the local import pipeline.
    printf '%s\n' "${_tmp}"
}
