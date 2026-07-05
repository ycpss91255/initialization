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
#   6.5 Sidecar helpers       — ADR-0001 / module-spec §4.7.4
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

# _module_test_mode_active — SR-01 gate. The github-release OFFLINE seams
# (INIT_UBUNTU_TEST_GH_FIXTURE_DIR / INIT_UBUNTU_TEST_GH_VERSION) swap the
# install payload / version resolver, so they MUST NOT be reachable in a normal
# production run merely by setting an env var (a poisoned rc, an env-preserving
# sudo policy, a compromised parent process). They now activate ONLY when this
# dedicated flag is set — a signal production NEVER sets and the bats harness
# always does. Setting a TEST_GH_* var alone (without INIT_UBUNTU_TEST_MODE=1)
# is ignored, so "can set one env var" can no longer plant a root-path binary.
_module_test_mode_active() {
    [[ "${INIT_UBUNTU_TEST_MODE:-}" == "1" ]]
}

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

# ─── 3b. Sidecar (ADR-0001) ─────────────────────────────────────────────────
#
# The Sidecar version file (${INIT_UBUNTU_STATE_DIR}/versions/<name>) and its
# write/remove/get helpers live in §6.5 below (single definition — they were
# historically duplicated here). The phase-invocation wrapper
# (_module_sidecar_after_phase, §6.5) is the single write site for BOTH
# Standalone and Engine modes (refines ADR-0001: WHERE, not WHETHER).

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

# Default doctor (ADR-0002 / ADR-0009): baseline runtime health = is_installed,
# log_warn on failure. ~20 archetype modules hand-wrote exactly this pattern;
# the macros now wire it by default. Modules with a runtime surface (daemon,
# group requirement, metadata self-check, Sidecar-drift detection) MUST still
# override doctor() after the archetype macro — late-binding lets them.
module_default_doctor() {
    if ! is_installed 2>/dev/null; then
        log_warn "[${NAME:-?}] doctor: not installed"
        return 1
    fi
    return 0
}

# ─── module_provided_version (phase-invocation Sidecar hook) ────────────────
#
# The Sidecar version string the phase-invocation wrapper records on a
# successful install/upgrade (see _module_sidecar_after_phase below). It is
# archetype-defaulted and per-module overridable. The wrapper — not the
# module's install() — calls this and writes the Sidecar, so both Engine and
# Standalone modes share one write site (refines ADR-0001: WHERE, not WHETHER).

# Generic default: the declared VERSION_PROVIDED. Hand-written (archetype D)
# modules work without defining anything; they override when they have a real
# runtime-resolved version.
module_default_provided_version() {
    printf '%s' "${VERSION_PROVIDED:-unknown}"
}

# apt archetype: dpkg-reported version of APT_PKGS[0], falling back to
# VERSION_PROVIDED (the logic the per-module _xxx_pkg_version helpers
# duplicated). No dpkg / empty answer -> VERSION_PROVIDED.
module_default_apt_provided_version() {
    local _pkg="" _ver=""
    if declare -p APT_PKGS >/dev/null 2>&1 && [[ "${#APT_PKGS[@]}" -gt 0 ]]; then
        _pkg="${APT_PKGS[0]}"
    fi
    if [[ -n "${_pkg}" ]]; then
        _ver="$(dpkg-query -W -f='${Version}' "${_pkg}" 2>/dev/null)" || _ver=""
    fi
    printf '%s' "${_ver:-${VERSION_PROVIDED:-apt-managed}}"
}

# github-release archetype: the release tag the B-archetype resolved during the
# fetch. The archetype fetch and every module-specific resolver set
# MODULE_GH_RESOLVED_VERSION. When unset — e.g. an idempotent re-install that
# short-circuited via module_skip_if_installed without re-resolving — preserve
# the EXISTING Sidecar version rather than clobbering it with the
# VERSION_PROVIDED fallback (AC-5/6: a no-op re-install must not downgrade the
# recorded version). Final fallback is VERSION_PROVIDED.
module_default_github_release_provided_version() {
    if [[ -n "${MODULE_GH_RESOLVED_VERSION:-}" ]]; then
        printf '%s' "${MODULE_GH_RESOLVED_VERSION}"
        return 0
    fi
    local _existing=""
    _existing="$(module_sidecar_get_version "${NAME}" 2>/dev/null)" || _existing=""
    printf '%s' "${_existing:-${VERSION_PROVIDED:-unknown}}"
}

# config archetype: the declared VERSION_PROVIDED (config drops are versioned
# by the template, not a package manager).
module_default_config_provided_version() {
    printf '%s' "${VERSION_PROVIDED:-unknown}"
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

# Wire the full lifecycle in one call. ADR-0002: the macro emits ALL the
# archetype-defaultable functions — the 6 mutation phases plus is_installed,
# is_outdated, verify, doctor, and the module_provided_version Sidecar hook.
# Only detect() + is_recommended() stay module-defined (genuinely
# module-specific). A module can still override any of these by re-declaring
# after the macro (bash late-binding).
module_use_apt_archetype() {
    is_installed()            { module_default_apt_is_installed; }
    is_outdated()             { module_default_apt_is_outdated; }
    install()                 { module_default_apt_install; }
    upgrade()                 { module_default_apt_upgrade; }
    remove()                  { module_default_apt_remove; }
    purge()                   { module_default_apt_purge; }
    verify()                  { module_default_verify; }
    doctor()                  { module_default_doctor; }
    module_provided_version() { module_default_apt_provided_version; }
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
    # Test-only OFFLINE seam (issue #175/#176): under the offline harness the
    # install target is the scratch-scoped BIN_LINK, so the system-PATH
    # fallback below must NOT fire — otherwise a same-named binary baked into
    # the (alpine) test-tools image (e.g. gum, baked for the AC-10 TUI smoke)
    # makes is_installed report a never-installed module as present, masking
    # the very real-install path #174 broke. Scoped to the fixture var so
    # production keeps the PATH fallback (pre-Sidecar installs).
    # SR-01: only honor the offline-fixture signal under an explicit test mode.
    _module_test_mode_active && [[ -n "${INIT_UBUNTU_TEST_GH_FIXTURE_DIR:-}" ]] && return 1
    command -v "${_bin}" >/dev/null 2>&1
}

# Test-only OFFLINE version seam (issue #175/#176): when
# INIT_UBUNTU_TEST_GH_VERSION is set, shadow the real (network) version
# resolver from lib/general.sh with a deterministic constant. module_helper.sh
# is sourced AFTER general.sh in setup_ubuntu.sh, so this redefinition wins
# inside the real install subprocess — letting a module's asset-pattern
# resolver (e.g. _gum_resolve_asset_pattern) run for real but offline. The
# guard means production (var unset) keeps general.sh's GitHub-API lookup
# untouched. Pairs with INIT_UBUNTU_TEST_GH_FIXTURE_DIR (the fetch seam).
# SR-01: gated on _module_test_mode_active — INIT_UBUNTU_TEST_GH_VERSION alone
# (without INIT_UBUNTU_TEST_MODE=1) no longer shadows the real resolver.
if _module_test_mode_active && [[ -n "${INIT_UBUNTU_TEST_GH_VERSION:-}" ]]; then
    get_github_pkg_latest_version() {
        local -n _outvar="${1:?get_github_pkg_latest_version needs <outvar>}"
        _outvar="${INIT_UBUNTU_TEST_GH_VERSION}"
    }
fi

# ─── 5a. Archive-safety + integrity helpers (SR-02 / SR-03) ─────────────────
#
# Downloaded archives are extracted as root; a MITM/compromised-mirror tarball
# could carry `..`/absolute members that escape INSTALL_DIR, or archived
# owner/uid/setuid bits. These helpers are shared by the archetype default AND
# the per-module direct fetchers (fzf/yazi/lazydocker) so the hardening lives
# in one place.

# module_archive_members_safe — read newline-separated archive member paths on
# stdin; return 1 (reject) if ANY member is an absolute path or contains a
# `..` path component (either can escape the extraction dir). Pure + directly
# unit-testable (SR-02).
module_archive_members_safe() {
    local _member
    while IFS= read -r _member; do
        [[ -z "${_member}" ]] && continue
        case "${_member}" in
            /*|..|../*|*/..|*/../*) return 1 ;;
        esac
    done
    return 0
}

# _module_safe_tar_extract <tarball> <install_dir> <strip> [sudo]
#   Reject unsafe members (SR-02 traversal guard), then extract with
#   --no-same-owner --no-same-permissions so a root extraction can NOT restore
#   archived owner/uid or setuid bits.
_module_safe_tar_extract() {
    local _tarball="${1:?tarball}" _dir="${2:?install dir}"
    local _strip="${3:-1}" _sudo="${4:-}"
    if ! tar -tzf "${_tarball}" 2>/dev/null | module_archive_members_safe; then
        log_error "[${NAME:-?}] refusing archive: unsafe (absolute or '..') member path in ${_tarball}"
        return 1
    fi
    ${_sudo} tar --no-same-owner --no-same-permissions \
        -C "${_dir}" --strip-components="${_strip}" -xzf "${_tarball}"
}

# _module_safe_unzip_extract <zipfile> <install_dir> [sudo]
#   Zip equivalent of the tar guard. unzip extracts as the current user (no
#   ownership restore), so the concern is purely member-path traversal (SR-02).
_module_safe_unzip_extract() {
    local _zip="${1:?zipfile}" _dir="${2:?install dir}" _sudo="${3:-}"
    if ! unzip -Z1 "${_zip}" 2>/dev/null | module_archive_members_safe; then
        log_error "[${NAME:-?}] refusing archive: unsafe (absolute or '..') member path in ${_zip}"
        return 1
    fi
    ${_sudo} unzip -q -o "${_zip}" -d "${_dir}"
}

# module_verify_sha256 <file> <expected-hex>
#   0 = digest matches, 1 = mismatch / undeterminable. Pure + directly
#   unit-testable (SR-03).
module_verify_sha256() {
    local _file="${1:?file}" _expected="${2:?expected hex}"
    [[ -f "${_file}" ]] || return 1
    local _actual=""
    _actual="$(sha256sum "${_file}" 2>/dev/null | awk '{print $1}')"
    [[ -n "${_actual}" ]] || return 1
    [[ "${_actual}" == "${_expected}" ]]
}

# _module_checksum_lookup <sums-file> <asset-name>
#   Print the sha256 hex for <asset-name> from a `sha256sum`-format file
#   (`<hex>  <name>`, optionally `*name` for binary mode / `./name`). Empty
#   output => no matching entry.
_module_checksum_lookup() {
    local _sums="${1:?sums file}" _asset="${2:?asset}"
    [[ -f "${_sums}" ]] || return 0
    awk -v a="${_asset}" '
        { n=$2; sub(/^[*]/,"",n); sub(/^\.\//,"",n);
          if (n==a) { print $1; exit } }' "${_sums}"
}

# _module_github_release_verify_checksum <artifact> <asset-name>
#   Best-effort SHA-256 integrity check (SR-03). When the module declares
#   GITHUB_CHECKSUM_ASSET, fetch that checksums file from the SAME release
#   (offline seam mirrors the artifact fetch), look up <asset-name>'s digest,
#   and verify. A MISMATCH returns 1 (abort the install). No declaration /
#   unreachable checksum asset / no matching digest => log_warn + return 0:
#   many upstreams publish no checksums, so this must not hard-fail every
#   github-release install.
_module_github_release_verify_checksum() {
    local _artifact="${1:?artifact}" _asset="${2:?asset}"
    local _checksum_asset="${GITHUB_CHECKSUM_ASSET:-}"
    if [[ -z "${_checksum_asset}" ]]; then
        log_warn "[${NAME:-?}] no GITHUB_CHECKSUM_ASSET declared; skipping integrity check for ${_asset}"
        return 0
    fi
    local _sums
    _sums="$(mktemp 2>/dev/null || printf '/tmp/%s-sums-%s' "${NAME:-x}" "$$")"
    if _module_test_mode_active && [[ -n "${INIT_UBUNTU_TEST_GH_FIXTURE_DIR:-}" ]]; then
        if ! cp "${INIT_UBUNTU_TEST_GH_FIXTURE_DIR%/}/${_checksum_asset}" "${_sums}" 2>/dev/null; then
            rm -f "${_sums}"
            log_warn "[${NAME:-?}] checksum fixture ${_checksum_asset} absent; proceeding without integrity check"
            return 0
        fi
    elif ! curl -fsSL --retry 3 -o "${_sums}" \
            "https://github.com/${GITHUB_REPO}/releases/latest/download/${_checksum_asset}" 2>/dev/null; then
        rm -f "${_sums}"
        log_warn "[${NAME:-?}] checksum download failed for ${_checksum_asset}; proceeding without integrity check"
        return 0
    fi
    local _expected=""
    _expected="$(_module_checksum_lookup "${_sums}" "${_asset}")"
    rm -f "${_sums}"
    if [[ -z "${_expected}" ]]; then
        log_warn "[${NAME:-?}] no digest for ${_asset} in ${_checksum_asset}; proceeding without integrity check"
        return 0
    fi
    if module_verify_sha256 "${_artifact}" "${_expected}"; then
        log_info "[${NAME:-?}] sha256 verified for ${_asset}"
        return 0
    fi
    log_error "[${NAME:-?}] sha256 MISMATCH for ${_asset} — refusing to install"
    return 1
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
    # Publish the resolved tag for module_provided_version (Sidecar hook). A
    # module-specific resolver may already have set this to a concrete tag
    # before super-calling us; only overwrite when we actually resolved one.
    [[ -n "${_ver}" ]] && MODULE_GH_RESOLVED_VERSION="${_ver}"

    _url="https://github.com/${GITHUB_REPO}/releases/latest/download/${GITHUB_ASSET_PATTERN}"
    _tmp="$(mktemp 2>/dev/null || printf '/tmp/%s-%s' "${NAME}" "$$")"
    # Test-only OFFLINE seam (issue #175/#176): when INIT_UBUNTU_TEST_GH_FIXTURE_DIR
    # points at a directory holding a pre-staged release tarball named exactly
    # ${GITHUB_ASSET_PATTERN}, copy it in instead of hitting the network. This
    # injects ONLY the fetch boundary into the real (non-dry-run) install
    # subprocess driven by setup_ubuntu.sh — everything downstream (the gzip
    # sniff, backup, tar --strip-components extract, symlink) still runs for
    # real, so the engine→runner→module-source→archetype-macro chain is
    # exercised end to end while staying deterministic. Never set in
    # production; the curl path below is the default.
    # SR-01: only honor the offline fixture under an explicit test mode. A
    # TEST_GH_FIXTURE_DIR set alone (no INIT_UBUNTU_TEST_MODE=1) is ignored and
    # the real curl path runs — env alone cannot swap the install payload.
    local _use_fixture=false
    if [[ -n "${INIT_UBUNTU_TEST_GH_FIXTURE_DIR:-}" ]]; then
        if _module_test_mode_active; then
            _use_fixture=true
        else
            log_warn "[${NAME}] ignoring INIT_UBUNTU_TEST_GH_FIXTURE_DIR: test seam requires INIT_UBUNTU_TEST_MODE=1"
        fi
    fi
    if [[ "${_use_fixture}" == "true" ]]; then
        local _fixture="${INIT_UBUNTU_TEST_GH_FIXTURE_DIR%/}/${GITHUB_ASSET_PATTERN}"
        log_info "[${NAME}] [test-fixture] copy ${_fixture} (offline; INIT_UBUNTU_TEST_MODE=1)"
        if ! cp "${_fixture}" "${_tmp}"; then
            log_error "[${NAME}] test fixture missing: ${_fixture}"
            rm -f "${_tmp}"
            return 1
        fi
    elif ! curl -fsSL --retry 3 -o "${_tmp}" "${_url}"; then
        log_error "[${NAME}] download failed: ${_url}"
        rm -f "${_tmp}"
        return 1
    fi
    if ! file "${_tmp}" 2>/dev/null | grep -q 'gzip compressed'; then
        log_error "[${NAME}] downloaded file is not gzip: ${_tmp}"
        rm -f "${_tmp}"
        return 1
    fi
    # SR-03: best-effort SHA-256 integrity check (mismatch aborts).
    if ! _module_github_release_verify_checksum "${_tmp}" "${GITHUB_ASSET_PATTERN}"; then
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
    # SR-02: traversal-guarded, --no-same-owner extraction.
    if ! _module_safe_tar_extract "${_tmp}" "${INSTALL_DIR}" "${_strip}" "${_sudo}"; then
        rm -f "${_tmp}"
        return 1
    fi
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
    # No is_installed gate: rm -rf / rm -f are already idempotent, and a partial
    # install (dirs present, Sidecar absent) must still be cleaned up.
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

# Default github-release is_outdated: compare the Sidecar version against the
# latest release tag. Not installed / no Sidecar / no remote answer = not
# outdated (return 1). This is the pattern gum/lazygit/codex hand-wrote;
# modules with a special version shape (notion .deb, eza/yazi binary parse)
# still override after the macro.
module_default_github_release_is_outdated() {
    is_installed 2>/dev/null || return 1
    local _local="" _remote=""
    _local="$(module_sidecar_get_version "${NAME}" 2>/dev/null)" || _local=""
    [[ -n "${_local}" ]] || return 1
    if declare -F get_github_pkg_latest_version >/dev/null 2>&1; then
        get_github_pkg_latest_version _remote "${GITHUB_REPO}" 2>/dev/null || _remote=""
    fi
    [[ -n "${_remote}" && "${_local}" != "${_remote}" ]]
}

# Wire the full lifecycle (ADR-0002). detect()/is_recommended() stay
# module-defined; everything else (incl. is_outdated, doctor, and the
# module_provided_version Sidecar hook) is archetype-defaulted + overridable.
module_use_github_release_archetype() {
    is_installed()            { module_default_github_release_is_installed; }
    is_outdated()             { module_default_github_release_is_outdated; }
    install()                 { module_default_github_release_install; }
    upgrade()                 { module_default_github_release_upgrade; }
    remove()                  { module_default_github_release_remove; }
    purge()                   { module_default_github_release_purge; }
    verify()                  { module_default_verify; }
    doctor()                  { module_default_doctor; }
    module_provided_version() { module_default_github_release_provided_version; }
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

# Default config is_outdated: a config drop has no upstream version channel, so
# the baseline answer is "not outdated" (return 1). Modules that can detect
# drift from the shipped template (e.g. claude-code-config) override after the
# macro.
module_default_config_is_outdated() {
    return 1
}

# Wire the full lifecycle (ADR-0002). detect()/is_recommended() stay
# module-defined; everything else (incl. is_outdated, doctor, and the
# module_provided_version Sidecar hook) is archetype-defaulted + overridable.
module_use_config_archetype() {
    is_installed()            { module_default_config_is_installed; }
    is_outdated()             { module_default_config_is_outdated; }
    install()                 { module_default_config_install; }
    upgrade()                 { module_default_config_upgrade; }
    remove()                  { module_default_config_remove; }
    purge()                   { module_default_config_purge; }
    verify()                  { module_default_verify; }
    doctor()                  { module_default_doctor; }
    module_provided_version() { module_default_config_provided_version; }
}

# ─── 6.5 Sidecar helpers (ADR-0001 / module-spec §4.7.4) ────────────────────
#
# The Sidecar at ${XDG_STATE_HOME}/init_ubuntu/versions/<name> records the
# version string installed for one module. Per ADR-0001 the write logic
# lives here in the module helpers so Standalone and Engine mode share the
# same code path: modules call module_sidecar_write after a successful
# install/upgrade and module_sidecar_remove after remove/purge. Writers are
# dry-run-safe (no-op when INIT_UBUNTU_DRY_RUN=true, AC-12).
# INIT_UBUNTU_STATE_DIR overrides the base dir (same contract as lib/state.sh).

module_sidecar_path() {
    local _name="${1:-${NAME:-}}"
    [[ -n "${_name}" ]] || return 1
    local _dir="${INIT_UBUNTU_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/init_ubuntu}"
    printf '%s/versions/%s' "${_dir}" "${_name}"
}

module_sidecar_write() {
    local _name="${1:?module_sidecar_write needs <name>}"
    local _version="${2:-unknown}"
    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        return 0
    fi
    local _path; _path="$(module_sidecar_path "${_name}")" || return 1
    mkdir -p "${_path%/*}"
    printf '%s\n' "${_version}" > "${_path}"
}

module_sidecar_remove() {
    local _name="${1:?module_sidecar_remove needs <name>}"
    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        return 0
    fi
    local _path; _path="$(module_sidecar_path "${_name}")" || return 1
    rm -f "${_path}"
}

# module_sidecar_get_version <name> — print recorded version; exit 1 if absent.
module_sidecar_get_version() {
    local _name="${1:?module_sidecar_get_version needs <name>}"
    local _path; _path="$(module_sidecar_path "${_name}")" || return 1
    [[ -f "${_path}" ]] || return 1
    cat "${_path}"
}

# _module_sidecar_after_phase <phase> <name>
#   The phase-invocation Sidecar wrapper (refines ADR-0001: the Sidecar
#   write/remove now lives at the invocation layer, shared by BOTH modes).
#   Called by lib/runner.sh (Engine) and module_standalone_main (Standalone)
#   AFTER a phase succeeds — NOT by the module's install()/upgrade()/etc.:
#     install / upgrade -> module_sidecar_write <name> "$(module_provided_version)"
#     remove  / purge   -> module_sidecar_remove <name>
#   No-op on dry-run (the sidecar_* helpers also guard, defense in depth) and
#   for read-only / diagnostic phases. module_provided_version is archetype-
#   defaulted (module_default_*_provided_version) and per-module overridable;
#   it falls back to VERSION_PROVIDED when a module defines nothing.
_module_sidecar_after_phase() {
    local _phase="${1:?_module_sidecar_after_phase needs <phase>}"
    local _name="${2:-${NAME:-}}"
    [[ -n "${_name}" ]] || return 0
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    case "${_phase}" in
        install|upgrade)
            local _ver="unknown"
            if declare -F module_provided_version >/dev/null 2>&1; then
                _ver="$(module_provided_version)" || _ver="${VERSION_PROVIDED:-unknown}"
            else
                _ver="${VERSION_PROVIDED:-unknown}"
            fi
            module_sidecar_write "${_name}" "${_ver}"
            ;;
        remove|purge)
            module_sidecar_remove "${_name}"
            ;;
        *) return 0 ;;
    esac
}

# ─── 7. Standalone CLI entry ────────────────────────────────────────────────

module_standalone_usage() {
    local _name="${NAME:-?}"
    cat <<EOF
Usage: bash module/${_name}.module.sh <phase> [options]

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
  --lang=<code>      override INIT_UBUNTU_LANG for i18n output (en, zh-TW)
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

    # Run the lifecycle function, then — for Action-class phases — drive the
    # Sidecar at this invocation layer (refines ADR-0001). install()/upgrade()
    # etc. mutate the system; the wrapper records/removes the Sidecar so
    # Standalone and Engine share one write site. Read-only / diagnostic
    # phases fall through _module_sidecar_after_phase's no-op branch.
    local _rc=0
    "${_phase}" || _rc=$?
    if [[ "${_rc}" -eq 0 ]]; then
        _module_sidecar_after_phase "${_phase}" "${NAME:-}"
    fi
    return "${_rc}"
}

# ─── 8. Engine-side aggregators ─────────────────────────────────────────────
#
# Called by lib/runner.sh in the module sub-shell right after a successful
# install phase; they read the module-level arrays already in scope and
# emit `action_required` structured events (PRD §7.7.2). The human-readable
# "Action required" block is derived from these events at session end —
# stdout and the JSONL log never diverge (AC-35).

# module_emit_post_install — emit an action_required event (kind=post_install)
# carrying the i18n-resolved POST_INSTALL_MESSAGE; no-op when empty.
module_emit_post_install() {
    # Most modules declare no POST_INSTALL_MESSAGE at all — bail out before
    # module_i18n_get's nameref deref, which would trip `set -u` on an
    # undeclared array.
    declare -p POST_INSTALL_MESSAGE >/dev/null 2>&1 || return 0
    local _msg
    # shellcheck disable=SC2119  # call with no args = use INIT_UBUNTU_LANG default — https://www.shellcheck.net/wiki/SC2119
    _msg="$(module_get_post_install_message)"
    [[ -n "${_msg}" ]] || return 0
    log_event info "${NAME:-}" "action_required" \
        "kind=post_install" \
        "message=${_msg}"
}

# module_emit_reboot_required — emit an action_required event (kind=reboot)
# when the module declared REBOOT_REQUIRED=true; no-op otherwise.
module_emit_reboot_required() {
    [[ "${REBOOT_REQUIRED:-false}" == "true" ]] || return 0
    log_event warn "${NAME:-}" "action_required" \
        "kind=reboot" \
        "message=Reboot required (${NAME:-?}). Run: sudo reboot"
}
