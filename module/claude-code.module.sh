#!/usr/bin/env bash
# module/claude-code.module.sh — Anthropic Claude Code CLI  [archetype: custom]
#
# New module per PRD §6.3.2 (agent CLIs). Ships via the official native
# installer (https://claude.ai/install.sh) which drops a self-contained
# binary at ~/.local/bin/claude with versioned payloads under
# ~/.local/share/claude — no apt package, no GitHub-release tarball, so
# archetype D (custom, doc/guide/archetype-cookbook.md §D).
#
# The tool ships its own auto-updater: `is_outdated` delegates to it by
# always returning 1 (this tool never drives the upgrade decision);
# `upgrade` runs the binary's own `update` subcommand; `doctor` checks the
# binary still answers `--version`.
#
# Standalone usage:
#   bash module/claude-code.module.sh install [--dry-run]
#   bash module/claude-code.module.sh upgrade / remove / purge / verify
#   bash module/claude-code.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/claude-code.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install claude-code

# ── Dual-mode header ────────────────────────────────────────────────────────
MODULE_STANDALONE="true"
[[ "${BASH_SOURCE[0]:-}" != "${0:-}" ]] && MODULE_STANDALONE="false"
if [[ "${MODULE_STANDALONE}" == "true" ]]; then
    # shellcheck source=../lib/module_bootstrap.sh
    source "${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)}/module_bootstrap.sh"
    module_bootstrap
fi
# Static-analysis hint (never executed: the guard is always false; wrapped in
# kcov-exclude so the dead line is not counted against coverage). module_bootstrap
# sources the lib helpers at runtime, but shellcheck cannot trace that 2-level
# dynamic source — this guarded line lets `shellcheck -x` follow module_helper.sh
# so it sees the metadata + archetype vars below are used externally (avoids SC2034).
# kcov-exclude-start
# shellcheck source=../lib/module_helper.sh
[[ -n "${__module_lint_hint:-}" ]] && source "${LIB_DIR}/module_helper.sh"
# kcov-exclude-end

# ── Metadata (doc/module-spec.md §3) ────────────────────────────────────────
NAME="claude-code"
VERSION_PROVIDED="latest"
CATEGORY="optional"
TAGS=("agent")
HOMEPAGE="https://code.claude.com/docs/en/overview"
declare -gA DESCRIPTION=(
    [en]="Anthropic Claude Code CLI agent (official native installer, self-updating)"
    [zh-TW]="Anthropic Claude Code CLI agent(官方原生安裝器,內建自動更新)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Run 'claude' once to sign in. The tool keeps itself current via its built-in auto-updater; make sure ~/.local/bin is on your PATH."
    [zh-TW]="首次執行 'claude' 完成登入。工具內建 auto-updater 會自行保持最新;請確認 ~/.local/bin 在 PATH 內。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=true
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="user-home"
TEST_VERIFY_CMD="command -v claude && claude --version"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype D data ────────────────────────────────────────────────────────
# Official native installer endpoint + the paths it manages. Tests override
# CLAUDE_BIN / CLAUDE_DATA_DIR to point at a scratch prefix.
CLAUDE_CODE_INSTALLER_URL="https://claude.ai/install.sh"
CLAUDE_BIN="${HOME}/.local/bin/claude"        # launcher symlink/binary
CLAUDE_DATA_DIR="${HOME}/.local/share/claude" # versioned payloads
CONFIG_PATHS=(                                # user config, purge-only
    "${HOME}/.claude"
    "${HOME}/.claude.json"
)

# ── Lifecycle ───────────────────────────────────────────────────────────────

is_installed() {
    [[ -x "${CLAUDE_BIN}" ]] && return 0
    command -v claude >/dev/null 2>&1
}

# Native installer ships x64 + arm64 Linux builds only.
detect() {
    case "$(uname -m)" in
        x86_64|aarch64|arm64) return 0 ;;
        *)                    return 1 ;;
    esac
}

is_recommended() {
    ! is_installed
}

install() {
    module_dryrun_guard install \
        "curl ${CLAUDE_CODE_INSTALLER_URL} | bash (installs ${CLAUDE_BIN}), write sidecar" \
        && return 0
    module_skip_if_installed && return 0
    _claude_code_run_installer || return $?
    module_sidecar_write "${NAME}" "$(_claude_code_version)"
}

# upgrade: the tool self-updates; delegate to its own `update` subcommand
# instead of re-running the installer, then refresh the sidecar.
upgrade() {
    module_dryrun_guard upgrade "claude update (self-updater), refresh sidecar" \
        && return 0
    if ! is_installed; then
        log_info "[${NAME}] not installed yet — running install instead"
        install
        return $?
    fi
    _claude_code_self_update || return $?
    module_sidecar_write "${NAME}" "$(_claude_code_version)"
}

# remove: drop the launcher + versioned payloads, keep user config
# (~/.claude*). The sidecar is state, not config — drop it too.
remove() {
    module_dryrun_guard remove \
        "rm ${CLAUDE_BIN} + ${CLAUDE_DATA_DIR}, drop sidecar" \
        && return 0
    rm -f "${CLAUDE_BIN}"
    rm -rf "${CLAUDE_DATA_DIR}"
    module_sidecar_remove "${NAME}"
}

purge() {
    module_dryrun_guard purge \
        "remove + rm ${CONFIG_PATHS[*]}" \
        && return 0
    remove || return $?
    local _p
    for _p in "${CONFIG_PATHS[@]}"; do
        rm -rf "${_p}"
    done
}

verify() {
    module_default_verify
}

# is_outdated: Claude Code manages its own updates (built-in auto-updater).
# Always 1 = never reported as outdated by this tool; `setup_ubuntu upgrade
# --all` therefore skips it and the self-updater stays in charge.
is_outdated() {
    return 1
}

# doctor: health check — binary present, still answers --version, sidecar
# consistent (warn-only: a missing sidecar = installed outside init_ubuntu).
doctor() {
    if ! is_installed; then
        log_warn "[${NAME}] doctor: claude is not installed"
        return 1
    fi
    local _bin
    _bin="$(_claude_code_bin)" || {
        log_warn "[${NAME}] doctor: claude binary not found on PATH"
        return 1
    }
    if ! "${_bin}" --version >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: ${_bin} --version failed"
        return 1
    fi
    module_sidecar_get_version "${NAME}" >/dev/null 2>&1 \
        || log_warn "[${NAME}] doctor: sidecar missing (installed outside init_ubuntu?)"
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Resolve the claude binary: managed launcher path first, PATH fallback.
_claude_code_bin() {
    if [[ -x "${CLAUDE_BIN}" ]]; then
        printf '%s' "${CLAUDE_BIN}"
        return 0
    fi
    command -v claude 2>/dev/null
}

# Run the official native installer (curl | bash). The installer is
# idempotent upstream: it always fetches the latest stable build.
_claude_code_run_installer() {
    command -v curl >/dev/null 2>&1 || {
        log_error "[${NAME}] curl is required to fetch ${CLAUDE_CODE_INSTALLER_URL}"
        return 1
    }
    log_info "[${NAME}] running official installer: ${CLAUDE_CODE_INSTALLER_URL}"
    curl -fsSL --retry 3 "${CLAUDE_CODE_INSTALLER_URL}" | bash || {
        log_error "[${NAME}] installer failed: ${CLAUDE_CODE_INSTALLER_URL}"
        return 1
    }
    is_installed || {
        log_error "[${NAME}] installer finished but ${CLAUDE_BIN} is missing"
        return 1
    }
}

# Delegate to the tool's own updater (`claude update`).
_claude_code_self_update() {
    local _bin
    _bin="$(_claude_code_bin)" || {
        log_error "[${NAME}] claude binary not found — cannot self-update"
        return 1
    }
    log_info "[${NAME}] delegating to self-updater: ${_bin} update"
    "${_bin}" update || {
        log_error "[${NAME}] '${_bin} update' failed"
        return 1
    }
}

# Version string for the sidecar: first token of `claude --version`
# (e.g. "2.0.13 (Claude Code)" -> "2.0.13"); falls back to "latest".
_claude_code_version() {
    local _bin _ver=""
    _bin="$(_claude_code_bin)" || { printf 'latest'; return 0; }
    _ver="$("${_bin}" --version 2>/dev/null | awk '{print $1; exit}')" || _ver=""
    printf '%s' "${_ver:-latest}"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
