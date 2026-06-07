#!/usr/bin/env bash
# shellcheck disable=SC2029  # SSH cmd strings intentionally expand ${_remote_path} client-side; value is a controlled tmpfile name, never user-tainted — https://www.shellcheck.net/wiki/SC2029
# lib/sync.sh — SSH push / pull of the install state across machines
#
# Per PRD §16 (Sync mechanism) and doc/architecture.md §16.
#
# Public API:
#   sync_push <user@host> [--modules=<csv>] [--dry-run] [--apply]
#   sync_pull <user@host> [--dry-run]
#     Both delegate to lib/state_io.sh + ssh/scp. The receiving side runs
#     the ADR-0013 conflict pipeline (dry-run default; --apply commits —
#     for push it is forwarded to the remote `import` invocation).
#
# Security (PRD §16.4):
#   - StrictHostKeyChecking=yes, key auth only (BatchMode=yes prevents any
#     password prompt). We never run ssh-copy-id — the user is told to use
#     setup_secrets ssh-key copy first.
#   - Payload NEVER contains secrets — only module names + their
#     machine-portable `synced` metadata (ADR-0018; `local` never ships).
#
# Remote tool check (PRD §16.3 step 2):
#   - A remote without `setup_ubuntu` is a hard stop: exit 7 + the 3-line
#     §3.4 bootstrap. NO auto-rsync (an orphan install without `.git`
#     breaks self-upgrade) and NO unattended remote sudo.
#   - Tool version skew is warn-only; the real gate is the state payload
#     schema version, enforced by state_io inside the import pipeline on
#     whichever side imports (ADR-0008).
#   - Remote import/export output streams back over the ssh channel
#     (PRD §16.3 step 6) — we run ssh in the foreground, unredirected.

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

# ── Remote tool check (PRD §16.3 step 2) ────────────────────────────────────

_sync_print_bootstrap() {
    local _target="$1"
    {
        printf "[sync] ERROR: setup_ubuntu not found on %s.\n" "${_target}"
        printf "[sync] Bootstrap the remote first (PRD §3.4) — run there:\n"
        printf "    sudo apt install -y git\n"
        printf "    git clone https://github.com/ycpss91255/initialization.git\n"
        printf "    cd initialization && ./setup_ubuntu_tui.sh\n"
    } >&2
}

# Exit 7 when the remote has no `setup_ubuntu`. The remote command exits
# with sentinel 9 so a missing tool is distinguishable from ssh transport
# failures (which surface as other non-zero codes).
_sync_check_remote_tool() {
    local _target="$1"
    ssh "${SYNC_SSH_OPTS[@]}" "${_target}" \
        "command -v setup_ubuntu >/dev/null 2>&1 || exit 9"
    local _rc=$?
    if [[ "${_rc}" -eq 9 ]]; then
        _sync_print_bootstrap "${_target}"
        return 7
    fi
    if [[ "${_rc}" -ne 0 ]]; then
        printf "[sync] ERROR: remote tool check failed (ssh exit %s)\n" "${_rc}" >&2
        return 7
    fi
}

# Tool version skew only warns (PRD §16.3 step 2). The hard gate is the
# state payload schema version, checked by state_io inside the import
# pipeline on whichever side imports (ADR-0008) — a too-new payload fails
# the remote/local import with its own error, never silently.
_sync_warn_tool_version_skew() {
    local _target="$1"
    local _local_ver="${INIT_UBUNTU_VERSION:-}"
    [[ -z "${_local_ver}" ]] && return 0
    local _remote_out _remote_ver
    if ! _remote_out="$(ssh "${SYNC_SSH_OPTS[@]}" "${_target}" "setup_ubuntu version" 2>/dev/null)"; then
        return 0
    fi
    _remote_ver="$(awk '/^init_ubuntu /{print $2; exit}' <<< "${_remote_out}")"
    [[ -z "${_remote_ver}" ]] && return 0
    if [[ "${_remote_ver}" != "${_local_ver}" ]]; then
        printf "[sync] WARN: tool version skew — local %s vs remote %s (continuing; payload schema compatibility is enforced by the import pipeline, ADR-0008)\n" \
            "${_local_ver}" "${_remote_ver}" >&2
    fi
    return 0
}

# ── Public: push ────────────────────────────────────────────────────────────

sync_push() {
    _sync_require_ssh || return 1

    local _target=""
    local _modules_csv=""
    local _dry="false"
    local _apply="false"
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            --modules=*) _modules_csv="${_arg#*=}" ;;
            --dry-run) _dry="true" ;;
            --apply) _apply="true" ;;
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
    _sync_check_remote_tool "${_target}" || return $?
    _sync_warn_tool_version_skew "${_target}"

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

    # ADR-0013: the remote import is dry-run by default (prints its diff
    # back over ssh); --apply commits on the remote side.
    local _import_cmd="setup_ubuntu import ${_remote_path}"
    [[ "${_apply}" == "true" ]] && _import_cmd+=" --apply"
    ssh "${SYNC_SSH_OPTS[@]}" "${_target}" "${_import_cmd}" || {
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
    _sync_check_remote_tool "${_target}" || return $?
    _sync_warn_tool_version_skew "${_target}"

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
