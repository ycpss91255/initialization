#!/usr/bin/env bash
# module/gping.module.sh — ping with a live graph  [archetype: apt (vendor repo)]
#
# gping is not in the Ubuntu archive, so install() first wires the azlux signing
# key under /etc/apt/keyrings and the packages.azlux.fr apt source, then chains
# to the apt default (small-tools modularization program). Whatever a module
# adds it removes: remove() drops the vendor key + source (clean uninstall), and
# purge() is the same (gping keeps no user config). Not desktop-gated — a
# terminal ping-with-a-graph is useful on servers and SBCs too.
#
# Standalone usage:
#   bash module/gping.module.sh install [--dry-run]
#   bash module/gping.module.sh upgrade / remove / purge / verify / doctor
#   bash module/gping.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/gping.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install gping

# ── BEGIN: shared-bootstrap ─────────────────────────────────────────────────
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
# ── END: shared-bootstrap ───────────────────────────────────────────────────

# ── Metadata (doc/module-spec.md §3) ────────────────────────────────────────
NAME="gping"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("cli-essentials" "network")
HOMEPAGE="https://github.com/orf/gping"
declare -gA DESCRIPTION=(
    [en]="gping — ping with a live terminal graph (azlux apt repository)"
    [zh-TW]="gping — 帶即時終端機圖表的 ping(azlux apt 軟體源)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Run 'gping <host>' (e.g. gping google.com) to watch latency as a live graph."
    [zh-TW]="執行 'gping <host>'(例如 gping google.com)以即時圖表觀察延遲。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl")
DEPENDS_ON=("curl")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v gping && gping --version"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt (vendor repo) ─────────────────────────────────────────
APT_PKGS=("gping")
APT_PPA=""
CONFIG_PATHS=()
# Vendor repo wiring (https://azlux.fr/repos.html): the dearmored signing key
# under /etc/apt/keyrings and the packages.azlux.fr apt source.
GPING_KEY_URL="https://azlux.fr/repo.gpg"
GPING_REPO_URL="http://packages.azlux.fr/debian/"
GPING_KEYRING="/etc/apt/keyrings/azlux.gpg"
GPING_APT_LIST="/etc/apt/sources.list.d/azlux.list"
module_use_apt_archetype

# Override install (super-call pattern): wire the vendor key + source first,
# then chain to the apt default. The Sidecar is written by the phase-invocation
# wrapper (ADR-0001 refinement), not here.
install() {
    module_dryrun_guard install \
        "azlux vendor apt repo (${GPING_REPO_URL}) + apt-install ${APT_PKGS[*]}" \
        && return 0
    module_skip_if_installed && return 0
    have_sudo_access 2>/dev/null \
        || { log_error "[${NAME}] sudo required for gping install"; return 1; }
    _gping_setup_apt_repo || return $?
    module_default_apt_install
}

# Override remove: clean uninstall — apt-remove the package, then drop the
# vendor key + source it added (idempotent — a second remove is a no-op).
remove() {
    module_dryrun_guard remove "apt-remove ${APT_PKGS[*]} + drop vendor repo" && return 0
    module_default_apt_remove || return $?
    _gping_remove_apt_repo
}

# Override purge: apt-purge (archetype), then drop the vendor key + source.
purge() {
    module_default_apt_purge || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    _gping_remove_apt_repo
}

detect() {
    command -v apt-get >/dev/null 2>&1
}

# Not desktop-gated: recommend whenever it is not already installed, on any
# supported form factor.
is_recommended() {
    ! is_installed
}

# doctor: a real runtime check — the tool must actually run, not just be
# dpkg-registered (the archetype default only checks is_installed).
doctor() {
    if ! command -v gping >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: gping binary not found on PATH"
        return 1
    fi
    gping --version >/dev/null 2>&1 || {
        log_warn "[${NAME}] doctor: 'gping --version' did not run cleanly"
        return 1
    }
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Wire the azlux signing key + apt source. Idempotent: an existing keyring is
# kept as-is (re-running install never re-downloads the key), and the sources
# line is rewritten in place.
_gping_setup_apt_repo() {
    log_info "[${NAME}] adding azlux apt key + source"
    sudo mkdir -p "$(dirname -- "${GPING_KEYRING}")"
    sudo chmod 0755 "$(dirname -- "${GPING_KEYRING}")"
    if [[ ! -f "${GPING_KEYRING}" ]]; then
        # gpg --dearmor runs unprivileged and streams to stdout; only the
        # keyring write needs root (sudo tee).
        if ! curl -fsSL "${GPING_KEY_URL}" | gpg --dearmor \
            | sudo tee "${GPING_KEYRING}" > /dev/null; then
            log_error "[${NAME}] failed to fetch/dearmor key from ${GPING_KEY_URL}"
            return 1
        fi
        # _apt must be able to read the keyring, or apt fails with NO_PUBKEY.
        sudo chmod 0644 "${GPING_KEYRING}"
    fi
    sudo mkdir -p "$(dirname -- "${GPING_APT_LIST}")"
    printf 'deb [signed-by=%s] %s stable main\n' \
        "${GPING_KEYRING}" "${GPING_REPO_URL}" \
        | sudo tee "${GPING_APT_LIST}" > /dev/null
}

# Drop the vendor apt source + keyring (remove + purge). Best effort: without
# sudo we leave the files in place and keep the exit code at 0.
_gping_remove_apt_repo() {
    if ! have_sudo_access 2>/dev/null; then
        log_warn "[${NAME}] no sudo: leaving azlux apt source + keyring in place"
        return 0
    fi
    log_info "[${NAME}] removing azlux apt source + keyring"
    sudo rm -f "${GPING_APT_LIST}" "${GPING_KEYRING}"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
