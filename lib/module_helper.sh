#!/usr/bin/env bash
# shellcheck disable=SC2317  # archetype-macro inner wrappers dispatched indirectly via ${_phase} (lib/runner.sh) — https://www.shellcheck.net/wiki/SC2317
# lib/module_helper.sh — Reusable lifecycle helpers + i18n + archetype macros.
#
# Module authors declare DATA (APT_PKGS / GITHUB_REPO / CONFIG_DEST / ...) and
# call ONE archetype macro (module_use_apt_archetype etc.) to wire up all
# lifecycle functions in a single line. They can still override individual
# lifecycle functions after the macro if a tool needs special handling.
#
# Sections:
#   1. Library guard
#   2. i18n (list + key:value)
#   3. Generic guards (dryrun / idempotency)
#   4. APT archetype          — lifecycle + macro
#   5. GitHub-release archetype
#   6. Config-drop archetype
#   7. Standalone CLI entry   — module_standalone_main, info, status
#   8. Engine-side aggregators

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not an executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# ─── 2. i18n ────────────────────────────────────────────────────────────────
#
# Modules declare translatable fields as associative arrays keyed by lang:
#
#   declare -A DESCRIPTION=(
#       [en]="Docker Engine + Compose plugin"
#       [zh-TW]="Docker 容器引擎 + Compose 外掛"
#   )
#
# module_i18n_get <ARRAY_NAME> [lang]   ← assoc lookup, fallback to en
# module_get_description / _post_install_message / _warn_message — thin wrappers

module_i18n_get() {
    local _name="${1:?module_i18n_get needs <array-name>}"
    local _lang="${2:-${INIT_UBUNTU_LANG:-en}}"
    local -n _arr="${_name}"
    printf '%s' "${_arr[${_lang}]:-${_arr[en]:-}}"
}

module_get_description()          { module_i18n_get DESCRIPTION          "$@"; }
# shellcheck disable=SC2120  # optional <lang> arg; in-module callers may omit, tests pass "en" — https://www.shellcheck.net/wiki/SC2120
module_get_post_install_message() { module_i18n_get POST_INSTALL_MESSAGE "$@"; }
module_get_warn_message()         { module_i18n_get WARN_MESSAGE         "$@"; }

# ─── 3. Generic guards ──────────────────────────────────────────────────────

# module_dryrun_guard <phase> "<description>"
#   Returns 0 (= caller should `return 0`) if INIT_UBUNTU_DRY_RUN=true,
#   logs the description; returns 1 otherwise.
module_dryrun_guard() {
    local _phase="${1:-install}"; shift || true
    local _desc="${*:-}"
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] || return 1
    log_info "[${NAME:-?}] [DRY-RUN] ${_phase}: ${_desc}"
    return 0
}

module_skip_if_installed() {
    is_installed 2>/dev/null || return 1
    log_info "[${NAME:-?}] already installed; skipping"
    return 0
}

module_skip_if_not_installed() {
    is_installed 2>/dev/null && return 1
    log_info "[${NAME:-?}] not installed; nothing to do"
    return 0
}

# ─── 4. APT archetype ───────────────────────────────────────────────────────
#
# Reads:
#   APT_PKGS      string[]  (required)
#   APT_PPA       string    (optional, e.g. ppa:fish-shell/release-4)
#   CONFIG_PATHS  string[]  (optional, dirs to rm on purge)

module_default_apt_is_installed() {
    # ${#APT_PKGS[@]:-0} is a bad-substitution under strict mode (set -u);
    # use declare -p to check the array is declared, then count elements.
    declare -p APT_PKGS >/dev/null 2>&1 || return 1
    [[ "${#APT_PKGS[@]}" -gt 0 ]] || return 1
    local _p
    for _p in "${APT_PKGS[@]}"; do
        [[ -n "${_p}" ]] || continue
        dpkg -l "${_p}" 2>/dev/null | grep -q '^ii' || return 1
    done
    return 0
}

module_default_apt_install() {
    module_dryrun_guard install "apt-install ${APT_PKGS[*]:-}" && return 0
    module_skip_if_installed && return 0

    if [[ -n "${APT_PPA:-}" ]]; then
        if have_sudo_access 2>/dev/null; then
            log_info "[${NAME}] add PPA ${APT_PPA}"
            sudo apt-add-repository -y "${APT_PPA}" \
                || log_warn "[${NAME}] apt-add-repository ${APT_PPA} failed"
        else
            log_warn "[${NAME}] no sudo: cannot add PPA ${APT_PPA}"
            return 1
        fi
    fi

    if ! have_sudo_access 2>/dev/null; then
        log_warn "[${NAME}] no sudo: please install manually: ${APT_PKGS[*]:-}"
        return 1
    fi

    sudo apt-get update -qq || log_warn "[${NAME}] apt-get update failed (continuing)"
    sudo apt-get install -y --no-install-recommends "${APT_PKGS[@]}"
}

module_default_apt_upgrade() {
    module_dryrun_guard upgrade "apt-install --only-upgrade ${APT_PKGS[*]:-}" && return 0
    if ! is_installed 2>/dev/null; then
        log_info "[${NAME}] not installed yet — running install instead"
        install
        return $?
    fi
    have_sudo_access 2>/dev/null || { log_warn "[${NAME}] no sudo: cannot update"; return 1; }
    sudo apt-get update -qq || log_warn "[${NAME}] apt-get update failed (continuing)"
    sudo apt-get install --only-upgrade -y "${APT_PKGS[@]}"
}

module_default_apt_remove() {
    module_dryrun_guard remove "apt-remove ${APT_PKGS[*]:-}" && return 0
    module_skip_if_not_installed && return 0
    sudo apt-get remove -y "${APT_PKGS[@]}" || true
}

module_default_apt_purge() {
    module_dryrun_guard purge "apt-purge ${APT_PKGS[*]:-} + CONFIG_PATHS" && return 0
    sudo apt-get purge -y "${APT_PKGS[@]}" 2>/dev/null || true
    if [[ -n "${APT_PPA:-}" ]] && have_sudo_access 2>/dev/null; then
        sudo apt-add-repository -y --remove "${APT_PPA}" || true
    fi
    local _p
    for _p in "${CONFIG_PATHS[@]:-}"; do
        [[ -n "${_p}" ]] || continue
        rm -rf "${_p}"
    done
}

# Default verify: just check is_installed succeeds, then optionally run
# TEST_VERIFY_CMD if the module declared one.
module_default_verify() {
    module_dryrun_guard verify "is_installed ${TEST_VERIFY_CMD:+&& ${TEST_VERIFY_CMD}}" && return 0
    is_installed || { log_warn "[${NAME}] verify failed: not installed"; return 1; }
    if [[ -n "${TEST_VERIFY_CMD:-}" ]]; then
        log_info "[${NAME}] verify: ${TEST_VERIFY_CMD}"
        bash -c "${TEST_VERIFY_CMD}"
    fi
}

# module_default_apt_is_outdated — `apt list --upgradable` query.
#   Returns 0 (= outdated) if any package in APT_PKGS appears in the
#   apt-managed upgradable list, 1 otherwise. No sudo required;
#   degrades gracefully on hosts without apt (apt -> empty -> 1).
module_default_apt_is_outdated() {
    declare -p APT_PKGS >/dev/null 2>&1 || return 1
    [[ "${#APT_PKGS[@]}" -gt 0 ]] || return 1
    local _upgradable _pkg
    _upgradable="$(apt list --upgradable 2>/dev/null)"
    [[ -n "${_upgradable}" ]] || return 1
    for _pkg in "${APT_PKGS[@]}"; do
        [[ -n "${_pkg}" ]] || continue
        printf '%s\n' "${_upgradable}" | grep -q "^${_pkg}/" && return 0
    done
    return 1
}

# Wire 7 lifecycle functions in one call (6 mutation + is_outdated read).
# Module can still override any of them by re-declaring after the macro.
module_use_apt_archetype() {
    is_installed() { module_default_apt_is_installed; }
    is_outdated()  { module_default_apt_is_outdated; }
    install()      { module_default_apt_install; }
    upgrade()      { module_default_apt_upgrade; }
    remove()       { module_default_apt_remove; }
    purge()        { module_default_apt_purge; }
    verify()       { module_default_verify; }
}

# ─── 5. GitHub-release archetype ────────────────────────────────────────────
#
# Reads:
#   GITHUB_REPO          string  e.g. "neovim/neovim"           (required)
#   GITHUB_ASSET_PATTERN string  e.g. "nvim-linux-x86_64.tar.gz" (required)
#   INSTALL_DIR          path    e.g. "/opt/nvim"                (required)
#   BIN_NAME             string  e.g. "nvim"                     (required)
#   BIN_PATH_IN_TAR      path    default "bin/${BIN_NAME}"
#   BIN_LINK             path    default "/usr/local/bin/${BIN_NAME}"
#   STRIP_COMPONENTS     int     default 1
#   USE_SUDO             bool    default "true"
#   CONFIG_PATHS         string[] dirs to rm on purge

module_default_github_release_is_installed() {
    local _bin="${BIN_NAME:-}"
    [[ -n "${_bin}" ]] || return 1
    local _link="${BIN_LINK:-/usr/local/bin/${_bin}}"
    [[ -x "${_link}" ]] && return 0
    command -v "${_bin}" >/dev/null 2>&1
}

# Internal: do the actual download + extract + symlink, used by install + update.
_module_github_release_fetch_and_install() {
    : "${GITHUB_REPO:?[${NAME:-?}] GITHUB_REPO required}"
    : "${GITHUB_ASSET_PATTERN:?[${NAME:-?}] GITHUB_ASSET_PATTERN required}"
    : "${INSTALL_DIR:?[${NAME:-?}] INSTALL_DIR required}"
    : "${BIN_NAME:?[${NAME:-?}] BIN_NAME required}"

    local _strip="${STRIP_COMPONENTS:-1}"
    local _bin_path="${BIN_PATH_IN_TAR:-bin/${BIN_NAME}}"
    local _bin_link="${BIN_LINK:-/usr/local/bin/${BIN_NAME}}"
    local _use_sudo="${USE_SUDO:-true}"
    local _sudo=""
    [[ "${_use_sudo}" == "true" ]] && _sudo="sudo"

    local _ver="" _tmp _url
    if declare -F get_github_pkg_latest_version >/dev/null 2>&1; then
        get_github_pkg_latest_version _ver "${GITHUB_REPO}" \
            || log_warn "[${NAME}] could not detect latest version (continuing)"
    fi
    [[ -n "${_ver}" ]] && log_info "[${NAME}] target: ${GITHUB_REPO} v${_ver}"

    _url="https://github.com/${GITHUB_REPO}/releases/latests/download/${GITHUB_ASSET_PATTERN}"
    _tmp="$(mktemp 2>/dev/null || printf '/tmp/%s-%s' "${NAME}" "$$")"
    log_info "[${NAME}] download ${_url}"
    if ! curl -fsSL --retry 3 -o "${_tmp}" "${_url}"; then
        log_error "[${NAME}] download failed: ${_url}"
        rm -f "${_tmp}"
        return 1
    fi
    if ! file "${_tmp}" 2>/dev/null | grep -q 'gzip compressed'; then
        log_error "[${NAME}] downloaded file is not gzip: ${_tmp}"
        rm -f "${_tmp}"
        return 1
    fi
    if [[ -e "${INSTALL_DIR}" ]]; then
        if declare -F backup_file >/dev/null 2>&1; then
            backup_file "${INSTALL_DIR}" || true
        fi
        ${_sudo} rm -rf "${INSTALL_DIR}"
    fi
    ${_sudo} mkdir -p "${INSTALL_DIR}"
    ${_sudo} tar -C "${INSTALL_DIR}" --strip-components="${_strip}" -xzf "${_tmp}"
    rm -f "${_tmp}"
    ${_sudo} ln -sfn "${INSTALL_DIR}/${_bin_path}" "${_bin_link}"
    log_info "[${NAME}] installed ${BIN_NAME}${_ver:+ v${_ver}} -> ${_bin_link}"
}

module_default_github_release_install() {
    module_dryrun_guard install \
        "fetch ${GITHUB_REPO:-?} latest -> ${INSTALL_DIR:-?}, symlink ${BIN_LINK:-/usr/local/bin/${BIN_NAME:-?}}" \
        && return 0
    module_skip_if_installed && return 0
    _module_github_release_fetch_and_install
}

module_default_github_release_upgrade() {
    module_dryrun_guard upgrade "force re-download ${GITHUB_REPO:-?} latest" && return 0
    # GitHub releases: easiest "update" is a fresh download (latest URL
    # always points to newest). Skip the is_installed guard.
    _module_github_release_fetch_and_install
}

module_default_github_release_remove() {
    : "${BIN_NAME:?[${NAME:-?}] BIN_NAME required}"
    local _bin_link="${BIN_LINK:-/usr/local/bin/${BIN_NAME}}"
    local _use_sudo="${USE_SUDO:-true}"
    local _sudo=""
    [[ "${_use_sudo}" == "true" ]] && _sudo="sudo"
    module_dryrun_guard remove "rm ${INSTALL_DIR:-?} + ${_bin_link}" && return 0
    [[ -n "${INSTALL_DIR:-}" && -e "${INSTALL_DIR}" ]] && ${_sudo} rm -rf "${INSTALL_DIR}"
    ${_sudo} rm -f "${_bin_link}"
}

module_default_github_release_purge() {
    module_dryrun_guard purge "rm ${INSTALL_DIR:-?} + ${BIN_LINK:-/usr/local/bin/${BIN_NAME:-?}} + CONFIG_PATHS" && return 0
    module_default_github_release_remove
    local _p
    for _p in "${CONFIG_PATHS[@]:-}"; do
        [[ -n "${_p}" ]] || continue
        rm -rf "${_p}"
    done
}

module_use_github_release_archetype() {
    is_installed() { module_default_github_release_is_installed; }
    install()      { module_default_github_release_install; }
    upgrade()       { module_default_github_release_upgrade; }
    remove()       { module_default_github_release_remove; }
    purge()        { module_default_github_release_purge; }
    verify()       { module_default_verify; }
}

# ─── 6. Config-drop archetype ───────────────────────────────────────────────
#
# Reads:
#   CONFIG_TEMPLATE_SRC  path    file shipped with the module        (optional)
#   CONFIG_DEST          path    user-facing target path             (required)
#   CONFIG_MARKER        string  default '# init_ubuntu managed'
#   CONFIG_MODE          string  chmod on dest file (e.g. '600')     (optional)
#   CONFIG_DIR_MODE      string  chmod on dest's parent dir          (optional)
#   CONFIG_STUB          string  fallback content                    (optional)

module_default_config_is_installed() {
    [[ -f "${CONFIG_DEST:-}" ]] || return 1
    grep -q "${CONFIG_MARKER:-# init_ubuntu managed}" "${CONFIG_DEST}" 2>/dev/null
}

_module_config_drop() {
    local _marker="${CONFIG_MARKER:-# init_ubuntu managed}"
    local _dest_dir="${CONFIG_DEST%/*}"
    [[ -n "${_dest_dir}" && "${_dest_dir}" != "${CONFIG_DEST}" ]] && mkdir -p "${_dest_dir}"

    if [[ -n "${CONFIG_TEMPLATE_SRC:-}" && -f "${CONFIG_TEMPLATE_SRC}" ]]; then
        cp "${CONFIG_TEMPLATE_SRC}" "${CONFIG_DEST}"
    elif [[ -n "${CONFIG_STUB:-}" ]]; then
        printf '%s\n' "${CONFIG_STUB}" > "${CONFIG_DEST}"
    else
        log_warn "[${NAME}] CONFIG_TEMPLATE_SRC missing — writing marker-only stub"
        : > "${CONFIG_DEST}"
    fi
    grep -q "${_marker}" "${CONFIG_DEST}" 2>/dev/null || \
        sed -i "1i ${_marker}" "${CONFIG_DEST}"
    [[ -n "${CONFIG_MODE:-}"     ]] && chmod "${CONFIG_MODE}"     "${CONFIG_DEST}"
    [[ -n "${CONFIG_DIR_MODE:-}" && -n "${_dest_dir}" ]] && chmod "${CONFIG_DIR_MODE}" "${_dest_dir}"
    return 0
}

module_default_config_install() {
    : "${CONFIG_DEST:?[${NAME:-?}] CONFIG_DEST required}"
    module_dryrun_guard install "drop config -> ${CONFIG_DEST}" && return 0
    module_skip_if_installed && return 0
    _module_config_drop || return $?
    return 0
}

module_default_config_upgrade() {
    : "${CONFIG_DEST:?[${NAME:-?}] CONFIG_DEST required}"
    module_dryrun_guard upgrade "backup + re-drop config -> ${CONFIG_DEST}" && return 0
    if [[ -f "${CONFIG_DEST}" ]] && declare -F backup_file >/dev/null 2>&1; then
        backup_file "${CONFIG_DEST}" || true
    fi
    _module_config_drop
}

module_default_config_remove() {
    : "${CONFIG_DEST:?[${NAME:-?}] CONFIG_DEST required}"
    module_dryrun_guard remove "rm ${CONFIG_DEST}" && return 0
    rm -f "${CONFIG_DEST}"
}

module_default_config_purge() {
    module_default_config_remove
}

module_use_config_archetype() {
    is_installed() { module_default_config_is_installed; }
    install()      { module_default_config_install; }
    upgrade()       { module_default_config_upgrade; }
    remove()       { module_default_config_remove; }
    purge()        { module_default_config_purge; }
    verify()       { module_default_verify; }
}

# ─── 7. Standalone CLI entry ────────────────────────────────────────────────

module_standalone_usage() {
    local _name="${NAME:-?}"
    cat <<EOF
Usage: bash modules/${_name}.module.sh <phase> [options]

Phases:
  install            run install()
  upgrade            run upgrade()
  remove             run remove()
  purge              run purge()
  verify             run verify()
  doctor             run doctor()         (if implemented)
  detect             run detect()         (read-only)
  is-installed       run is_installed()   (read-only)
  is-recommended     run is_recommended() (read-only)
  is-outdated        run is_outdated()    (read-only, if implemented)
  status             print install/version/outdated status (engine-side)
  info               print metadata (engine-side)

Options:
  --dry-run, -n      do not perform side effects; log what would happen
  --lang=<code>      override INIT_UBUNTU_LANG for i18n output (en, zh-TW, ...)
  --help,    -h
  --version, -V

Notes:
  Standalone invocation does NOT resolve DEPENDS_ON. Use setup_ubuntu for the
  engine-level flow (dep tree, batched session, state.json updates).
EOF
}

# module_standalone_info — print metadata to stdout (no side effects).
module_standalone_info() {
    local _lang="${INIT_UBUNTU_LANG:-en}"
    printf 'name:        %s\n'   "${NAME:-?}"
    printf 'version:     %s\n'   "${VERSION_PROVIDED:-unknown}"
    printf 'category:    %s\n'   "${CATEGORY:-?}"
    printf 'description: %s\n'   "$(module_get_description "${_lang}")"
    [[ -n "${HOMEPAGE:-}"   ]] && printf 'homepage:    %s\n' "${HOMEPAGE}"
    [[ -n "${MAINTAINER:-}" ]] && printf 'maintainer:  %s\n' "${MAINTAINER}"
    [[ -v TAGS               && "${#TAGS[@]}"               -gt 0 ]] && printf 'tags:        %s\n' "${TAGS[*]}"
    [[ -v DEPENDS_ON         && "${#DEPENDS_ON[@]}"         -gt 0 ]] && printf 'depends_on:  %s\n' "${DEPENDS_ON[*]}"
    [[ -v CONFLICTS_WITH     && "${#CONFLICTS_WITH[@]}"     -gt 0 ]] && printf 'conflicts:   %s\n' "${CONFLICTS_WITH[*]}"
    [[ -v SUPPORTED_UBUNTU   && "${#SUPPORTED_UBUNTU[@]}"   -gt 0 ]] && printf 'ubuntu:      %s\n' "${SUPPORTED_UBUNTU[*]}"
    [[ -v SUPPORTED_PLATFORMS && "${#SUPPORTED_PLATFORMS[@]}" -gt 0 ]] && printf 'platforms:   %s\n' "${SUPPORTED_PLATFORMS[*]}"
    [[ -n "${RISK_LEVEL:-}"            ]] && printf 'risk:        %s\n' "${RISK_LEVEL}"
    [[ "${REBOOT_REQUIRED:-false}" == "true" ]] && printf 'reboot:      required\n'
    [[ -n "${INSTALL_TIME_ESTIMATE:-}" ]] && printf 'install_time: %s\n' "${INSTALL_TIME_ESTIMATE}"
    [[ -n "${DISK_SPACE_ESTIMATE:-}"   ]] && printf 'disk_space:   %s\n' "${DISK_SPACE_ESTIMATE}"
    [[ -n "${TEST_VERIFY_CMD:-}"       ]] && printf 'verify_cmd:   %s\n' "${TEST_VERIFY_CMD}"
    return 0
}

# module_standalone_status — print installed/outdated state.
module_standalone_status() {
    local _installed="no" _outdated="?" _ver=""
    is_installed 2>/dev/null && _installed="yes"
    if declare -F is_outdated >/dev/null 2>&1; then
        if is_outdated 2>/dev/null; then _outdated="yes"; else _outdated="no"; fi
    else
        _outdated="(no is_outdated)"
    fi
    printf 'name:        %s\n' "${NAME:-?}"
    printf 'installed:   %s\n' "${_installed}"
    printf 'outdated:    %s\n' "${_outdated}"
    printf 'version:     %s\n' "${VERSION_PROVIDED:-unknown}"
}

module_standalone_main() {
    local _phase=""
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            install|upgrade|remove|purge|verify|doctor|detect|status|info)
                _phase="${1}"; shift ;;
            is-installed)   _phase="is_installed"; shift ;;
            is-recommended) _phase="is_recommended"; shift ;;
            is-outdated)    _phase="is_outdated"; shift ;;
            --dry-run|-n)   export INIT_UBUNTU_DRY_RUN=true; shift ;;
            --lang=*)       export INIT_UBUNTU_LANG="${1#*=}"; shift ;;
            --lang)         shift; export INIT_UBUNTU_LANG="${1:-en}"; shift || true ;;
            --help|-h)      module_standalone_usage; return 0 ;;
            --version|-V)   printf '%s %s\n' "${NAME:-?}" "${VERSION_PROVIDED:-unknown}"; return 0 ;;
            *)
                printf '[%s] Unknown argument: %s\n' "${NAME:-?}" "${1}" >&2
                module_standalone_usage >&2
                return 2 ;;
        esac
    done

    if [[ -z "${_phase}" ]]; then
        module_standalone_usage >&2
        return 2
    fi

    case "${_phase}" in
        info)   module_standalone_info; return 0 ;;
        status) module_standalone_status; return 0 ;;
    esac

    if ! declare -F "${_phase}" >/dev/null 2>&1; then
        # is_outdated / doctor / verify are optional — fail gracefully.
        case "${_phase}" in
            is_outdated|doctor|verify|upgrade)
                printf '[%s] %s() not implemented by this module\n' "${NAME:-?}" "${_phase}" >&2
                return 2 ;;
            *)
                printf '[%s] Module does not implement %s()\n' "${NAME:-?}" "${_phase}" >&2
                return 2 ;;
        esac
    fi
    "${_phase}"
}

# ─── 8. Engine-side aggregators ─────────────────────────────────────────────
#
# Called by lib/runner.sh at session end to collect cross-module hints.
# These run in the engine sub-shell after `${_phase}` completes; they read
# the module-level arrays already in scope.

# module_emit_post_install — runner appends this to a session-wide buffer.
module_emit_post_install() {
    local _msg
    # shellcheck disable=SC2119  # call with no args = use INIT_UBUNTU_LANG default — https://www.shellcheck.net/wiki/SC2119
    _msg="$(module_get_post_install_message)"
    [[ -n "${_msg}" ]] || return 0
    printf '[%s] %s\n' "${NAME:-?}" "${_msg}"
}

module_emit_reboot_required() {
    [[ "${REBOOT_REQUIRED:-false}" == "true" ]] || return 0
    printf '[%s] reboot required\n' "${NAME:-?}"
}
