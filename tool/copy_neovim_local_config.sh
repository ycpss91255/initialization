#!/usr/bin/env bash
# tool/copy_neovim_local_config.sh — snapshot a user's Neovim `user/` Lua config
# into this tool's own `config/` directory (to commit the local edits back).
#
# One-off tool (ADR-0029). It used to be a set -euo script with no --help, a
# blind `mv ... || true` that silently swallowed failures, and a `cp -r` with no
# dry-run. It now sources lib/tool_bootstrap.sh and shrinks to usage() +
# do_work(), gaining --help, --dry-run, and host-package-free strict-mode
# operation. Every mutation is routed through tool_run so --dry-run writes
# nothing.
#
# Source:       <user-home>/.config/nvim/lua/user
# Destination:  <this-tool-dir>/config  (previous snapshot rotated to config.bak)
#
# The target user defaults to $USER; override with NEOVIM_CONFIG_USER=<name> or
# by passing the name after `--` (e.g. `copy_neovim_local_config.sh -- alice`).
# NEOVIM_CONFIG_SRC overrides source resolution outright (used by the spec).

# shellcheck source=../lib/tool_bootstrap.sh
source "${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)}/tool_bootstrap.sh"
tool_bootstrap

# ── Identity ─────────────────────────────────────────────────────────────────
TOOL_NAME="copy_neovim_local_config"
TOOL_SUMMARY="snapshot a user's Neovim user/ Lua config into this tool's config/ dir"

# Destination lives in this tool's own directory (overridable for tests).
_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DEST_DIR="${NEOVIM_CONFIG_DEST:-${_SELF_DIR}/config}"

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${TOOL_NAME} — ${TOOL_SUMMARY}

Usage:
  ${TOOL_NAME}                 snapshot \$USER's nvim user/ config
  ${TOOL_NAME} -- <user>       snapshot <user>'s config instead
  ${TOOL_NAME} --dry-run       show what would run, write nothing
  ${TOOL_NAME} -h|--help       show this help and exit

Environment:
  NEOVIM_CONFIG_USER   target user (default: \$USER)
  NEOVIM_CONFIG_SRC    source dir override (default: <user-home>/.config/nvim/lua/user)
  NEOVIM_CONFIG_DEST   destination dir (default: <tool-dir>/config)

Destination:
  ${DEST_DIR}  (previous snapshot rotated to config.bak)

Exit codes:
  0  success (or --help)
  2  usage error (unknown argument)

Notes:
  * Idempotent: the previous snapshot is rotated to config.bak each run.
  * Never installs host packages.
EOF
}

# ── Work ─────────────────────────────────────────────────────────────────────
# Resolve the source directory: an explicit NEOVIM_CONFIG_SRC wins; otherwise
# derive it from the target user's home via getent.
_resolve_src() {
    if [[ -n "${NEOVIM_CONFIG_SRC:-}" ]]; then
        printf '%s\n' "${NEOVIM_CONFIG_SRC}"
        return 0
    fi

    local _user="${1:-${NEOVIM_CONFIG_USER:-${USER:-}}}"
    if [[ -z "${_user}" ]]; then
        log_fatal "cannot determine target user (set NEOVIM_CONFIG_USER or pass -- <user>)"
    fi

    local _home
    _home="$(getent passwd "${_user}" | cut -d: -f6 || true)"
    if [[ -z "${_home}" || ! -d "${_home}" ]]; then
        log_fatal "home directory for user '${_user}' not found"
    fi
    printf '%s\n' "${_home}/.config/nvim/lua/user"
}

do_work() {
    local _src
    _src="$(_resolve_src "${1:-}")"

    if [[ ! -d "${_src}" ]]; then
        log_fatal "Neovim user config not found: ${_src}"
    fi

    # Rotate any existing snapshot out of the way, then copy the fresh one in.
    if [[ -e "${DEST_DIR}" ]]; then
        tool_run "rm -rf -- \"${DEST_DIR}.bak\""
        tool_run "mv -- \"${DEST_DIR}\" \"${DEST_DIR}.bak\""
    fi
    tool_run "cp -r -- \"${_src}\" \"${DEST_DIR}\""
    tool_is_dry_run || log_info "snapshotted ${_src} -> ${DEST_DIR}"
}

# ── Entry ────────────────────────────────────────────────────────────────────
tool_main "$@"
