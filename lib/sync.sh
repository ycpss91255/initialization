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

# i18n_t (issue #185) lives in lib/i18n.sh. The entrypoint sources it before
# dispatching, but make this lib self-sufficient (unit specs source sync.sh
# directly) by loading it on demand when the helper is not yet defined.
if ! declare -F i18n_t >/dev/null 2>&1; then
    # shellcheck source=lib/i18n.sh
    source "${BASH_SOURCE[0]%/*}/i18n.sh"
fi

# File-local message catalog (issue #185, Phase 2). `en.<key>` MUST stay
# byte-identical to the previous English literal. log_* lines stay English
# (machine-grep'd); only human-facing stdout/stderr status goes through i18n_t.
declare -gA SYNC_I18N=(
    [en.ssh_not_found]="[sync] ERROR: ssh not found. Install openssh-client."
    [zh-TW.ssh_not_found]="[sync] 錯誤：找不到 ssh，請安裝 openssh-client。"

    [en.scp_not_found]="[sync] ERROR: scp not found."
    [zh-TW.scp_not_found]="[sync] 錯誤：找不到 scp。"

    [en.cannot_ssh]="[sync] ERROR: cannot ssh to {0}"
    [zh-TW.cannot_ssh]="[sync] 錯誤：無法以 ssh 連線到 {0}"

    [en.ssh_said]="[sync] ssh said: {0}"
    [zh-TW.ssh_said]="[sync] ssh 訊息：{0}"

    [en.ssh_key_hint]="[sync] hint: run 'setup_secrets ssh-key copy {0}' to install your key first."
    [zh-TW.ssh_key_hint]="[sync] 提示：請先執行 'setup_secrets ssh-key copy {0}' 以安裝你的金鑰。"

    [en.bootstrap_not_found]="[sync] ERROR: setup_ubuntu not found on {0}."
    [zh-TW.bootstrap_not_found]="[sync] 錯誤：在 {0} 上找不到 setup_ubuntu。"

    [en.bootstrap_intro]="[sync] Bootstrap the remote first (PRD §3.4) — run there:"
    [zh-TW.bootstrap_intro]="[sync] 請先初始化遠端（PRD §3.4）— 在該機器上執行："

    [en.remote_tool_check_failed]="[sync] ERROR: remote tool check failed (ssh exit {0})"
    [zh-TW.remote_tool_check_failed]="[sync] 錯誤：遠端工具檢查失敗（ssh 結束碼 {0}）"

    [en.version_skew]="[sync] WARN: tool version skew — local {0} vs remote {1} (continuing; payload schema compatibility is enforced by the import pipeline, ADR-0008)"
    [zh-TW.version_skew]="[sync] 警告：工具版本不一致 — 本機 {0} 與遠端 {1}（將繼續；負載結構相容性由匯入流程強制檢查，ADR-0008）"

    [en.unknown_flag]="[sync] ERROR: unknown flag {0}"
    [zh-TW.unknown_flag]="[sync] 錯誤：未知的旗標 {0}"

    [en.push_one_target]="[sync] ERROR: sync_push takes one <user@host>"
    [zh-TW.push_one_target]="[sync] 錯誤：sync_push 只接受一個 <user@host>"

    [en.push_needs_target]="[sync] ERROR: sync_push needs <user@host>"
    [zh-TW.push_needs_target]="[sync] 錯誤：sync_push 需要 <user@host>"

    [en.pull_one_target]="[sync] ERROR: sync_pull takes one <user@host>"
    [zh-TW.pull_one_target]="[sync] 錯誤：sync_pull 只接受一個 <user@host>"

    [en.pull_needs_target]="[sync] ERROR: sync_pull needs <user@host>"
    [zh-TW.pull_needs_target]="[sync] 錯誤：sync_pull 需要 <user@host>"

    [en.state_io_not_loaded]="[sync] ERROR: lib/state_io.sh not loaded"
    [zh-TW.state_io_not_loaded]="[sync] 錯誤：尚未載入 lib/state_io.sh"

    [en.dry_push]="[sync] DRY-RUN: would push to {0}"
    [zh-TW.dry_push]="[sync] DRY-RUN：將會推送到 {0}"

    [en.dry_push_modules]="[sync] DRY-RUN: filtered modules: {0}"
    [zh-TW.dry_push_modules]="[sync] DRY-RUN：篩選的模組：{0}"

    [en.dry_pull]="[sync] DRY-RUN: would pull from {0}"
    [zh-TW.dry_pull]="[sync] DRY-RUN：將會從 {0} 拉取"

    [en.scp_upload_failed]="[sync] ERROR: scp upload failed"
    [zh-TW.scp_upload_failed]="[sync] 錯誤：scp 上傳失敗"

    [en.remote_import_failed]="[sync] ERROR: remote import failed"
    [zh-TW.remote_import_failed]="[sync] 錯誤：遠端匯入失敗"

    [en.pushed_ok]="[sync] pushed state to {0} OK"
    [zh-TW.pushed_ok]="[sync] 已成功將狀態推送到 {0}"

    [en.remote_export_failed]="[sync] ERROR: remote export failed"
    [zh-TW.remote_export_failed]="[sync] 錯誤：遠端匯出失敗"

    [en.scp_download_failed]="[sync] ERROR: scp download failed"
    [zh-TW.scp_download_failed]="[sync] 錯誤：scp 下載失敗"
)

readonly SYNC_SSH_OPTS=(
    -o "StrictHostKeyChecking=yes"
    -o "BatchMode=yes"
    -o "PasswordAuthentication=no"
    -o "ConnectTimeout=10"
)

_sync_require_ssh() {
    if ! command -v ssh >/dev/null 2>&1; then
        printf '%s\n' "$(i18n_t SYNC_I18N ssh_not_found)" >&2
        return 1
    fi
    if ! command -v scp >/dev/null 2>&1; then
        printf '%s\n' "$(i18n_t SYNC_I18N scp_not_found)" >&2
        return 1
    fi
}

_sync_test_connection() {
    local _target="$1"
    local _err
    _err="$(ssh "${SYNC_SSH_OPTS[@]}" "${_target}" true 2>&1)"
    local _rc=$?
    if [[ "${_rc}" -ne 0 ]]; then
        printf '%s\n' "$(i18n_t SYNC_I18N cannot_ssh "${_target}")" >&2
        printf '%s\n' "$(i18n_t SYNC_I18N ssh_said "${_err}")" >&2
        printf '%s\n' "$(i18n_t SYNC_I18N ssh_key_hint "${_target}")" >&2
        return 7
    fi
}

# ── Remote tool check (PRD §16.3 step 2) ────────────────────────────────────

_sync_print_bootstrap() {
    local _target="$1"
    {
        printf '%s\n' "$(i18n_t SYNC_I18N bootstrap_not_found "${_target}")"
        printf '%s\n' "$(i18n_t SYNC_I18N bootstrap_intro)"
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
        printf '%s\n' "$(i18n_t SYNC_I18N remote_tool_check_failed "${_rc}")" >&2
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
        printf '%s\n' "$(i18n_t SYNC_I18N version_skew "${_local_ver}" "${_remote_ver}")" >&2
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
            -*) printf '%s\n' "$(i18n_t SYNC_I18N unknown_flag "${_arg}")" >&2; return 2 ;;
            *)
                if [[ -z "${_target}" ]]; then
                    _target="${_arg}"
                else
                    printf '%s\n' "$(i18n_t SYNC_I18N push_one_target)" >&2
                    return 2
                fi
                ;;
        esac
    done
    if [[ -z "${_target}" ]]; then
        printf '%s\n' "$(i18n_t SYNC_I18N push_needs_target)" >&2
        return 2
    fi

    if ! declare -F state_io_export >/dev/null 2>&1; then
        printf '%s\n' "$(i18n_t SYNC_I18N state_io_not_loaded)" >&2
        return 1
    fi

    if [[ "${_dry}" == "true" ]]; then
        printf '%s\n' "$(i18n_t SYNC_I18N dry_push "${_target}")"
        [[ -n "${_modules_csv}" ]] && printf '%s\n' "$(i18n_t SYNC_I18N dry_push_modules "${_modules_csv}")"
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
        printf '%s\n' "$(i18n_t SYNC_I18N scp_upload_failed)" >&2
        return 7
    }
    rm -f "${_tmp}"

    # ADR-0013: the remote import is dry-run by default (prints its diff
    # back over ssh); --apply commits on the remote side.
    local _import_cmd="setup_ubuntu import ${_remote_path}"
    [[ "${_apply}" == "true" ]] && _import_cmd+=" --apply"
    ssh "${SYNC_SSH_OPTS[@]}" "${_target}" "${_import_cmd}" || {
        printf '%s\n' "$(i18n_t SYNC_I18N remote_import_failed)" >&2
        return 7
    }
    ssh "${SYNC_SSH_OPTS[@]}" "${_target}" "rm -f ${_remote_path}" || true

    printf '%s\n' "$(i18n_t SYNC_I18N pushed_ok "${_target}")"
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
            -*) printf '%s\n' "$(i18n_t SYNC_I18N unknown_flag "${_arg}")" >&2; return 2 ;;
            *)
                if [[ -z "${_target}" ]]; then
                    _target="${_arg}"
                else
                    printf '%s\n' "$(i18n_t SYNC_I18N pull_one_target)" >&2
                    return 2
                fi
                ;;
        esac
    done
    if [[ -z "${_target}" ]]; then
        printf '%s\n' "$(i18n_t SYNC_I18N pull_needs_target)" >&2
        return 2
    fi

    if [[ "${_dry}" == "true" ]]; then
        printf '%s\n' "$(i18n_t SYNC_I18N dry_pull "${_target}")"
        return 0
    fi

    _sync_test_connection "${_target}" || return $?
    _sync_check_remote_tool "${_target}" || return $?
    _sync_warn_tool_version_skew "${_target}"

    local _remote_path="/tmp/init_ubuntu_sync.json"
    ssh "${SYNC_SSH_OPTS[@]}" "${_target}" "setup_ubuntu export ${_remote_path}" || {
        printf '%s\n' "$(i18n_t SYNC_I18N remote_export_failed)" >&2
        return 7
    }

    local _tmp
    _tmp="$(mktemp /tmp/init_ubuntu_sync.XXXXXX.json)"
    scp "${SYNC_SSH_OPTS[@]}" "${_target}:${_remote_path}" "${_tmp}" || {
        rm -f "${_tmp}"
        printf '%s\n' "$(i18n_t SYNC_I18N scp_download_failed)" >&2
        return 7
    }

    ssh "${SYNC_SSH_OPTS[@]}" "${_target}" "rm -f ${_remote_path}" || true

    # Print the downloaded file path on stdout so the dispatcher can hand
    # it to the local import pipeline.
    printf '%s\n' "${_tmp}"
}
