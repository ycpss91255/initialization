#!/usr/bin/env bash
# module/fnm.module.sh — fnm Fast Node Manager  [archetype: custom (hand-written)]
#
# Split out of module/setup_neovim.sh (issue #56, PRD §6.3.1 Batch B, Q3/Q4)
# so the dependency is reusable (neovim and gemini both need Node.js).
# Archetype D (custom): the legacy logic installs via the upstream install
# script (https://fnm.vercel.app/install) into ${HOME}/.local/share/fnm —
# a pure user-home install with no sudo, and upstream GitHub releases ship
# .zip assets, so the github-release archetype (gzip tarball + /opt +
# /usr/local/bin symlink + sudo) does not fit (cookbook: replace 4+ of 6
# lifecycle fns => pick D). GITHUB_REPO is still declared for version
# queries (Sidecar / is_outdated) against Schniz/fnm releases.
#
# Shell integration (idempotent, marker-guarded):
#   fish — drop ${HOME}/.config/fish/conf.d/fnm.fish (skipped if the user
#          already has one); removed on purge only when our marker is found.
#   bash — append a marker-fenced block to an EXISTING ${HOME}/.bashrc
#          (never creates one); the fence is stripped on purge.
#
# Standalone usage:
#   bash module/fnm.module.sh install [--dry-run]
#   bash module/fnm.module.sh upgrade / remove / purge / verify
#   bash module/fnm.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/fnm.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install fnm

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

# ── Metadata (doc/module-spec.md §3, PRD §9.1) ──────────────────────────────
NAME="fnm"
VERSION_PROVIDED="latest"
CATEGORY="optional"
TAGS=("cli-essentials")
HOMEPAGE="https://github.com/Schniz/fnm"
declare -gA DESCRIPTION=(
    [en]="fnm Fast Node Manager (Node.js version manager, user-home install)"
    [zh-TW]="fnm 快速 Node.js 版本管理器(安裝至使用者家目錄)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Restart your shell (or source ~/.bashrc) so fnm and the default Node.js land on PATH."
    [zh-TW]="重新開啟 shell(或 source ~/.bashrc)後 fnm 與預設 Node.js 才會進入 PATH。"
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
TEST_VERIFY_CMD="command -v fnm && fnm --version"
# Consumed post-source by the engine (registry / runner / TUI) or via nameref
# lookups (module_i18n_get) that ShellCheck cannot trace; export marks the
# external use (SC2034 wiki-recommended fix, no disable needed).
export DESCRIPTION POST_INSTALL_MESSAGE WARN_MESSAGE \
       SUPPORTS_USER_HOME INSTALL_TARGET_DEFAULT

# ── Archetype D data — upstream install script + user-home dirs ─────────────
GITHUB_REPO="Schniz/fnm"                          # version queries only
FNM_INSTALL_SCRIPT_URL="https://fnm.vercel.app/install"
FNM_INSTALL_DIR="${FNM_INSTALL_DIR:-${HOME}/.local/share/fnm}"
FNM_DEFAULT_NODE_VERSION="${FNM_DEFAULT_NODE_VERSION:-22}"   # legacy parity
FNM_FISH_CONF="${FNM_FISH_CONF:-${HOME}/.config/fish/conf.d/fnm.fish}"
FNM_BASH_RC="${FNM_BASH_RC:-${HOME}/.bashrc}"
FNM_SHELL_MARKER="# init_ubuntu managed: fnm"
FNM_BASH_BLOCK_BEGIN="# >>> init_ubuntu fnm >>>"
FNM_BASH_BLOCK_END="# <<< init_ubuntu fnm <<<"

# ── Lifecycle (hand-written, ADR-0002: all mandatory) ───────────────────────

is_installed() {
    [[ -x "${FNM_INSTALL_DIR}/fnm" ]] && return 0
    command -v fnm >/dev/null 2>&1
}

install() {
    module_dryrun_guard install \
        "curl ${FNM_INSTALL_SCRIPT_URL} | bash -s -- --install-dir ${FNM_INSTALL_DIR} --skip-shell; shell hooks (fish/bash); default Node ${FNM_DEFAULT_NODE_VERSION}; Sidecar" \
        && return 0
    module_skip_if_installed && return 0
    _fnm_fetch_and_install || return $?
    _fnm_shell_init || return $?
    _fnm_install_default_node
    module_sidecar_write "${NAME}" "$(_fnm_installed_version)"
}

upgrade() {
    module_dryrun_guard upgrade \
        "re-run upstream install script (latest) + refresh shell hooks + Sidecar" \
        && return 0
    _fnm_fetch_and_install || return $?
    _fnm_shell_init || return $?
    module_sidecar_write "${NAME}" "$(_fnm_installed_version)"
}

# remove: drop the fnm binary + Sidecar, keep downloaded Node versions and
# shell hooks (both are inert without the binary; purge wipes them).
remove() {
    module_dryrun_guard remove \
        "rm ${FNM_INSTALL_DIR}/fnm + Sidecar (keep Node versions + shell hooks)" \
        && return 0
    rm -f "${FNM_INSTALL_DIR}/fnm"
    module_sidecar_remove "${NAME}"
}

purge() {
    module_dryrun_guard purge \
        "rm ${FNM_INSTALL_DIR} (incl. Node versions) + fish/bash shell hooks + Sidecar" \
        && return 0
    rm -rf "${FNM_INSTALL_DIR}"
    _fnm_shell_cleanup
    module_sidecar_remove "${NAME}"
}

verify() {
    module_dryrun_guard verify "is_installed && fnm --version" && return 0
    is_installed || { log_warn "[${NAME}] verify failed: not installed"; return 1; }
    local _bin
    _bin="$(_fnm_bin)" || { log_warn "[${NAME}] verify failed: fnm binary not found"; return 1; }
    "${_bin}" --version >/dev/null 2>&1 \
        || { log_warn "[${NAME}] verify failed: ${_bin} --version errored"; return 1; }
}

detect() {
    # Upstream ships fnm-linux.zip (x64) / fnm-arm64.zip / fnm-arm32.zip.
    case "$(uname -m)" in
        x86_64|aarch64|arm64|armv7l) return 0 ;;
        *) return 1 ;;
    esac
}

is_recommended() {
    ! is_installed
}

# is_outdated: compare Sidecar (or binary-reported) version against the
# latest GitHub release tag. Not installed / remote unknown = not outdated.
is_outdated() {
    is_installed || return 1
    local _local="" _remote=""
    _local="$(module_sidecar_get_version "${NAME}" 2>/dev/null)" \
        || _local="$(_fnm_installed_version)"
    if declare -F get_github_pkg_latest_version >/dev/null 2>&1; then
        get_github_pkg_latest_version _remote "${GITHUB_REPO}" 2>/dev/null \
            || _remote=""
    fi
    [[ -n "${_remote}" && "${_local}" != "${_remote}" ]]
}

# doctor: binary runnable + Sidecar invariant (module-spec §4.7.4:
# is_installed <-> Sidecar exists). Read-only — flags drift, never heals.
doctor() {
    local _ok=0 _sidecar
    _sidecar="$(module_sidecar_path "${NAME}")"
    if is_installed; then
        local _bin
        if ! _bin="$(_fnm_bin)" || ! "${_bin}" --version >/dev/null 2>&1; then
            log_warn "[${NAME}] doctor: fnm binary not runnable"
            _ok=1
        fi
        if [[ ! -f "${_sidecar}" ]]; then
            log_warn "[${NAME}] doctor: installed but Sidecar missing (ADR-0001 drift; re-run install/upgrade to heal)"
            _ok=1
        fi
    else
        if [[ -e "${_sidecar}" ]]; then
            log_warn "[${NAME}] doctor: Sidecar present but fnm not installed (ADR-0001 drift; rm ${_sidecar} or reinstall)"
            _ok=1
        fi
    fi
    return "${_ok}"
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Print the fnm binary path (install dir first, PATH fallback); 1 if absent.
_fnm_bin() {
    if [[ -x "${FNM_INSTALL_DIR}/fnm" ]]; then
        printf '%s' "${FNM_INSTALL_DIR}/fnm"
        return 0
    fi
    command -v fnm 2>/dev/null
}

# Parse the installed binary's version ("fnm 1.38.1" -> "1.38.1").
_fnm_installed_version() {
    local _bin _ver=""
    if _bin="$(_fnm_bin)"; then
        _ver="$("${_bin}" --version 2>/dev/null \
            | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true)"
    fi
    printf '%s' "${_ver:-unknown}"
}

# Run the upstream install script (same flow as legacy setup_neovim.sh,
# plus --install-dir so tests/relocations can redirect it).
_fnm_fetch_and_install() {
    local _dep
    for _dep in curl unzip; do
        command -v "${_dep}" >/dev/null 2>&1 || {
            log_error "[${NAME}] '${_dep}' is required by the upstream install script"
            return 1
        }
    done
    log_info "[${NAME}] run upstream install script -> ${FNM_INSTALL_DIR}"
    if ! curl -fsSL --retry 3 "${FNM_INSTALL_SCRIPT_URL}" \
        | bash -s -- --install-dir "${FNM_INSTALL_DIR}" --skip-shell; then
        log_error "[${NAME}] upstream install script failed"
        return 1
    fi
    [[ -x "${FNM_INSTALL_DIR}/fnm" ]] || {
        log_error "[${NAME}] fnm binary missing after install: ${FNM_INSTALL_DIR}/fnm"
        return 1
    }
    log_info "[${NAME}] installed fnm $(_fnm_installed_version) -> ${FNM_INSTALL_DIR}"
}

# Install + alias the default Node.js (legacy parity: fnm install 22).
# Fail-soft: fnm itself is installed; a Node download hiccup only warns.
_fnm_install_default_node() {
    local _bin
    _bin="$(_fnm_bin)" || return 0
    log_info "[${NAME}] install default Node.js ${FNM_DEFAULT_NODE_VERSION} via fnm"
    if ! FNM_DIR="${FNM_INSTALL_DIR}" "${_bin}" install "${FNM_DEFAULT_NODE_VERSION}" \
        || ! FNM_DIR="${FNM_INSTALL_DIR}" "${_bin}" alias default "${FNM_DEFAULT_NODE_VERSION}"; then
        log_warn "[${NAME}] default Node.js ${FNM_DEFAULT_NODE_VERSION} install failed (fnm itself is installed; run 'fnm install ${FNM_DEFAULT_NODE_VERSION}' manually)"
    fi
    return 0
}

# Idempotent shell hooks: each writer is guarded by FNM_SHELL_MARKER so a
# second install/upgrade run never duplicates content.
_fnm_shell_init() {
    _fnm_fish_init || return $?
    _fnm_bash_init || return $?
}

# fish: drop a conf.d snippet. Skipped when the user already ships their own
# fnm.fish (legacy behavior: never clobber); re-runs with our marker are
# no-ops because content is only written once.
_fnm_fish_init() {
    if [[ -f "${FNM_FISH_CONF}" ]]; then
        if grep -Fq "${FNM_SHELL_MARKER}" "${FNM_FISH_CONF}"; then
            log_info "[${NAME}] fish hook already present: ${FNM_FISH_CONF}"
        else
            log_info "[${NAME}] ${FNM_FISH_CONF} exists (user-owned); leaving untouched"
        fi
        return 0
    fi
    mkdir -p "${FNM_FISH_CONF%/*}"
    cat > "${FNM_FISH_CONF}" <<EOF
${FNM_SHELL_MARKER}
set -gx FNM_PATH "${FNM_INSTALL_DIR}"
if test -d "\$FNM_PATH"
    if not contains \$FNM_PATH \$PATH
        set -gx PATH \$FNM_PATH \$PATH
    end
    fnm env --use-on-cd --shell fish | source
end
EOF
    log_info "[${NAME}] wrote fish hook ${FNM_FISH_CONF}"
}

# bash: append a marker-fenced block to an EXISTING ~/.bashrc only (never
# create one — legacy behavior). The begin fence doubles as the grep guard.
_fnm_bash_init() {
    if [[ ! -f "${FNM_BASH_RC}" ]]; then
        log_info "[${NAME}] no ${FNM_BASH_RC}; skipping bash hook"
        return 0
    fi
    if grep -Fq "${FNM_BASH_BLOCK_BEGIN}" "${FNM_BASH_RC}"; then
        log_info "[${NAME}] bash hook already present: ${FNM_BASH_RC}"
        return 0
    fi
    cat >> "${FNM_BASH_RC}" <<EOF

${FNM_BASH_BLOCK_BEGIN}
export FNM_PATH="${FNM_INSTALL_DIR}"
if [ -d "\$FNM_PATH" ]; then
  case ":\$PATH:" in
    *":\$FNM_PATH:"*) ;;
    *) export PATH="\$FNM_PATH:\$PATH" ;;
  esac
  eval "\$(fnm env --use-on-cd)"
fi
${FNM_BASH_BLOCK_END}
EOF
    log_info "[${NAME}] appended bash hook to ${FNM_BASH_RC}"
}

# Strip what _fnm_shell_init added (purge only). fish: delete the file only
# when our marker owns it. bash: delete the marker fence range, cat-over to
# keep perms + inode (same trick as zoxide).
_fnm_shell_cleanup() {
    if [[ -f "${FNM_FISH_CONF}" ]] && grep -Fq "${FNM_SHELL_MARKER}" "${FNM_FISH_CONF}"; then
        rm -f "${FNM_FISH_CONF}"
        log_info "[${NAME}] removed fish hook ${FNM_FISH_CONF}"
    fi
    if [[ -f "${FNM_BASH_RC}" ]] && grep -Fq "${FNM_BASH_BLOCK_BEGIN}" "${FNM_BASH_RC}"; then
        local _tmp
        _tmp="$(mktemp)"
        sed "\|^${FNM_BASH_BLOCK_BEGIN}\$|,\|^${FNM_BASH_BLOCK_END}\$|d" \
            "${FNM_BASH_RC}" > "${_tmp}"
        cat "${_tmp}" > "${FNM_BASH_RC}"   # cat-over keeps perms + inode
        rm -f "${_tmp}"
        log_info "[${NAME}] removed bash hook block from ${FNM_BASH_RC}"
    fi
    return 0
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
