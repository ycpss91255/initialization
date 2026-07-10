#!/usr/bin/env bash
# tool/sync_config.sh — bidirectional dotfile sync between the repo and $HOME.
#
# Issue #308. module/config/ is deployed to ~/.config, ~/.ssh, etc. via one-shot
# `cp`/`cp -r` in the setup_*.sh scripts. After deploy, local edits never flow
# back and the two sides drift. Symlinking was rejected (SSH strict-perm checks,
# editor atomic-write replacing the link, directory-symlink leakage, repo-path
# moves breaking every link), so this tool syncs file *content* on demand.
#
# Commands:
#   status | --check   scan every managed pair; classify each as identical /
#                      local-newer / repo-newer / local-missing / repo-missing
#   pull   | --pull    local -> repo   (pull local edits back for commit)
#   push   | --push    repo  -> local  (apply repo version to a machine)
#
# Options:
#   --dry-run | -n     show what would change; write nothing
#   --help    | -h     usage
#
# The repo<->local mapping lives in ONE managed manifest (below), so it is not
# hard-coded across the setup_*.sh scripts. Each write is preceded by a
# $BACKUP_DIR snapshot of the file being overwritten.
#
# Test / override hooks (keep the tool host-safe and unit-testable):
#   SYNC_CONFIG_SRC       repo-side config root      (default <repo>/module/config)
#   SYNC_CONFIG_MANIFEST  manifest file override     (default: embedded manifest)
#   HOME                  local-side target base
#   BACKUP_DIR            pre-write snapshot dir      (see lib/general.sh)

set -uo pipefail

_SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd -P)"
_REPO_ROOT="$(cd -- "${_SCRIPT_DIR}/.." && pwd -P)"

# shellcheck source=../lib/general.sh
source "${_REPO_ROOT}/lib/general.sh"

# Repo-side source root and local-side target base.
SYNC_CONFIG_SRC="${SYNC_CONFIG_SRC:-${_REPO_ROOT}/module/config}"
_TARGET_HOME="${HOME}"

# Embedded managed manifest: <repo-relpath>\t<local-relpath-under-HOME>.
# Validated first on the footgun-prone files called out in the issue
# (ssh_config, git_config, fish/config.fish). Extend as pairs are confirmed.
_default_manifest() {
    cat <<'MANIFEST'
ssh_config	.ssh/config
git_config	.gitconfig
fish/config.fish	.config/fish/config.fish
MANIFEST
}

_usage() {
    cat <<'USAGE'
Usage: sync_config.sh <command> [--dry-run]

Commands:
  status, --check   Compare every managed file and report drift
  pull,   --pull    Copy local edits back into the repo (local -> repo)
  push,   --push    Apply the repo version to the local target (repo -> local)

Options:
  --dry-run, -n     Show files that would change; write nothing
  --help,    -h     Show this help

The repo<->local mapping is defined by a single managed manifest. Every write
is backed up to $BACKUP_DIR first.
USAGE
}

# Emit manifest rows as "<repo-relpath>\t<local-relpath>", skipping blank lines
# and # comments. Uses SYNC_CONFIG_MANIFEST when it points at a readable file,
# otherwise the embedded default.
_read_manifest() {
    local _src
    if [[ -n "${SYNC_CONFIG_MANIFEST:-}" && -r "${SYNC_CONFIG_MANIFEST}" ]]; then
        _src="$(cat -- "${SYNC_CONFIG_MANIFEST}")"
    else
        _src="$(_default_manifest)"
    fi

    local _line _repo _local
    while IFS= read -r _line; do
        [[ -z "${_line//[[:space:]]/}" ]] && continue
        [[ "${_line#\#}" != "${_line}" ]] && continue
        # Split on the first run of whitespace (tab or spaces).
        _repo="${_line%%[[:space:]]*}"
        _local="${_line#"${_repo}"}"
        _local="${_local#"${_local%%[![:space:]]*}"}"
        [[ -z "${_repo}" || -z "${_local}" ]] && continue
        printf '%s\t%s\n' "${_repo}" "${_local}"
    done <<< "${_src}"
}

# Classify one pair. Echoes one of: identical / local-newer / repo-newer /
# local-missing / repo-missing / differ / absent.
_classify() {
    local _repo_path="$1" _local_path="$2"
    local _repo_exists="false" _local_exists="false"
    [[ -f "${_repo_path}" ]] && _repo_exists="true"
    [[ -f "${_local_path}" ]] && _local_exists="true"

    if [[ "${_repo_exists}" == "false" && "${_local_exists}" == "false" ]]; then
        printf 'absent'; return 0
    fi
    if [[ "${_local_exists}" == "false" ]]; then
        printf 'local-missing'; return 0
    fi
    if [[ "${_repo_exists}" == "false" ]]; then
        printf 'repo-missing'; return 0
    fi
    if cmp -s -- "${_repo_path}" "${_local_path}"; then
        printf 'identical'; return 0
    fi

    local _repo_mtime _local_mtime
    _repo_mtime="$(stat -c %Y -- "${_repo_path}" 2>/dev/null || echo 0)"
    _local_mtime="$(stat -c %Y -- "${_local_path}" 2>/dev/null || echo 0)"
    if (( _local_mtime > _repo_mtime )); then
        printf 'local-newer'
    elif (( _repo_mtime > _local_mtime )); then
        printf 'repo-newer'
    else
        printf 'differ'
    fi
}

_cmd_status() {
    local _repo_rel _local_rel _repo_path _local_path _state
    local _drift=0
    while IFS=$'\t' read -r _repo_rel _local_rel; do
        _repo_path="${SYNC_CONFIG_SRC}/${_repo_rel}"
        _local_path="${_TARGET_HOME}/${_local_rel}"
        _state="$(_classify "${_repo_path}" "${_local_path}")"
        printf '%-14s %s\t%s\n' "${_state}" "${_repo_rel}" "${_local_path}"
        [[ "${_state}" == "identical" || "${_state}" == "absent" ]] || _drift=$((_drift + 1))
    done < <(_read_manifest)
    log_info "sync status: ${_drift} file(s) drifted"
    return 0
}

# Copy _from -> _to, snapshotting the pre-write _to under BACKUP_DIR first.
# Honors dry-run. Skips when already identical.
_apply() {
    local _from="$1" _to="$2" _label="$3" _dry_run="$4"

    if [[ ! -f "${_from}" ]]; then
        log_warn "skip ${_label}: source missing (${_from})"
        return 0
    fi
    if [[ -f "${_to}" ]] && cmp -s -- "${_from}" "${_to}"; then
        log_debug "skip ${_label}: already identical (${_to})"
        return 0
    fi

    if [[ "${_dry_run}" == "true" ]]; then
        log_info "dry-run ${_label}: would write ${_to}"
        return 0
    fi

    if [[ -f "${_to}" ]]; then
        backup_file "${_to}"
    fi
    mkdir -p -- "$(dirname -- "${_to}")"
    cp -a -- "${_from}" "${_to}"
    log_info "${_label}: ${_to}"
}

_cmd_sync() {
    local _direction="$1" _dry_run="$2"
    local _repo_rel _local_rel _repo_path _local_path
    while IFS=$'\t' read -r _repo_rel _local_rel; do
        _repo_path="${SYNC_CONFIG_SRC}/${_repo_rel}"
        _local_path="${_TARGET_HOME}/${_local_rel}"
        if [[ "${_direction}" == "push" ]]; then
            _apply "${_repo_path}" "${_local_path}" "push ${_repo_rel}" "${_dry_run}"
        else
            _apply "${_local_path}" "${_repo_path}" "pull ${_repo_rel}" "${_dry_run}"
        fi
    done < <(_read_manifest)
    return 0
}

main() {
    local _command="" _dry_run="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            status|--check) _command="status" ;;
            pull|--pull)    _command="pull" ;;
            push|--push)    _command="push" ;;
            --dry-run|-n)   _dry_run="true" ;;
            --help|-h)      _usage; return 0 ;;
            *)
                log_error "unknown argument: $1"
                _usage >&2
                return 2
                ;;
        esac
        shift
    done

    case "${_command}" in
        status) _cmd_status ;;
        pull)   _cmd_sync "pull" "${_dry_run}" ;;
        push)   _cmd_sync "push" "${_dry_run}" ;;
        "")
            log_error "no command given"
            _usage >&2
            return 2
            ;;
    esac
}

main "$@"
