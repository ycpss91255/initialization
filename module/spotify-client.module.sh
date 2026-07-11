#!/usr/bin/env bash
# module/spotify-client.module.sh — Spotify desktop client  [archetype: apt (vendor repo)]
#
# Spotify is not in the Ubuntu archive, so install() first wires the upstream
# signing key under /etc/apt/keyrings and the repository.spotify.com apt source,
# then chains to the apt default (small-tools modularization program). Whatever
# a module adds it removes: remove() drops the vendor key + source (clean
# uninstall), and purge() additionally clears the user config. Desktop-only
# (SUPPORTED_PLATFORMS): a music player GUI is pointless on headless form
# factors.
#
# Standalone usage:
#   bash module/spotify-client.module.sh install [--dry-run]
#   bash module/spotify-client.module.sh upgrade / remove / purge / verify / doctor
#   bash module/spotify-client.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/spotify-client.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install spotify-client

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
NAME="spotify-client"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("media" "gui")
HOMEPAGE="https://www.spotify.com/"
declare -gA DESCRIPTION=(
    [en]="Spotify — music streaming desktop client (upstream apt repository)"
    [zh-TW]="Spotify — 音樂串流桌面用戶端(官方 apt 軟體源)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Launch 'spotify' from a desktop session and sign in with your Spotify account."
    [zh-TW]="於桌面工作階段執行 'spotify' 並以你的 Spotify 帳號登入。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop")
DEPENDS_ON=("curl")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v spotify"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt (vendor repo) ─────────────────────────────────────────
APT_PKGS=("spotify-client")
APT_PPA=""
CONFIG_PATHS=("${HOME}/.config/spotify")
# Vendor repo wiring (https://www.spotify.com/download/linux/): the dearmored
# signing key under /etc/apt/keyrings and the repository.spotify.com source.
SPOTIFY_KEY_URL="https://download.spotify.com/debian/pubkey_6224F9941A8AA6D1.gpg"
SPOTIFY_REPO_URL="http://repository.spotify.com"
SPOTIFY_KEYRING="/etc/apt/keyrings/spotify.gpg"
SPOTIFY_APT_LIST="/etc/apt/sources.list.d/spotify.list"
module_use_apt_archetype

# Override install (super-call pattern): wire the vendor key + source first,
# then chain to the apt default. The Sidecar is written by the phase-invocation
# wrapper (ADR-0001 refinement), not here.
install() {
    module_dryrun_guard install \
        "spotify vendor apt repo (${SPOTIFY_REPO_URL}) + apt-install ${APT_PKGS[*]}" \
        && return 0
    module_skip_if_installed && return 0
    have_sudo_access 2>/dev/null \
        || { log_error "[${NAME}] sudo required for spotify-client install"; return 1; }
    _spotify_setup_apt_repo || return $?
    module_default_apt_install
}

# Override remove: clean uninstall — apt-remove the package, then drop the
# vendor key + source it added (idempotent — a second remove is a no-op).
remove() {
    module_dryrun_guard remove "apt-remove ${APT_PKGS[*]} + drop vendor repo" && return 0
    module_default_apt_remove || return $?
    _spotify_remove_apt_repo
}

# Override purge: apt-purge + config wipe (archetype), then drop the vendor
# key + source.
purge() {
    module_default_apt_purge || return $?
    [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && return 0
    _spotify_remove_apt_repo
}

detect() {
    command -v apt-get >/dev/null 2>&1
}

# Desktop-only recommendation gate (GUI music player): never pre-tick on
# headless / SBC form factors (doc/module-spec.md §4.3.1).
is_recommended() {
    case "${INIT_UBUNTU_FORM_FACTOR:-}" in
        desktop)
            ! is_installed
            ;;
        *)
            return 1
            ;;
    esac
}

# doctor: a real runtime check — the tool must actually be on PATH, not just
# dpkg-registered (the archetype default only checks is_installed).
doctor() {
    if ! command -v spotify >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: spotify binary not found on PATH"
        return 1
    fi
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Wire the Spotify signing key + apt source. Idempotent: an existing keyring is
# kept as-is (re-running install never re-downloads the key), and the sources
# line is rewritten in place.
_spotify_setup_apt_repo() {
    log_info "[${NAME}] adding Spotify apt key + source"
    sudo mkdir -p "$(dirname -- "${SPOTIFY_KEYRING}")"
    sudo chmod 0755 "$(dirname -- "${SPOTIFY_KEYRING}")"
    if [[ ! -f "${SPOTIFY_KEYRING}" ]]; then
        # gpg --dearmor runs unprivileged and streams to stdout; only the
        # keyring write needs root (sudo tee).
        if ! curl -fsSL "${SPOTIFY_KEY_URL}" | gpg --dearmor \
            | sudo tee "${SPOTIFY_KEYRING}" > /dev/null; then
            log_error "[${NAME}] failed to fetch/dearmor key from ${SPOTIFY_KEY_URL}"
            return 1
        fi
        # _apt must be able to read the keyring, or apt fails with NO_PUBKEY.
        sudo chmod 0644 "${SPOTIFY_KEYRING}"
    fi
    sudo mkdir -p "$(dirname -- "${SPOTIFY_APT_LIST}")"
    printf 'deb [signed-by=%s] %s stable non-free\n' \
        "${SPOTIFY_KEYRING}" "${SPOTIFY_REPO_URL}" \
        | sudo tee "${SPOTIFY_APT_LIST}" > /dev/null
}

# Drop the vendor apt source + keyring (remove + purge). Best effort: without
# sudo we leave the files in place and keep the exit code at 0.
_spotify_remove_apt_repo() {
    if ! have_sudo_access 2>/dev/null; then
        log_warn "[${NAME}] no sudo: leaving Spotify apt source + keyring in place"
        return 0
    fi
    log_info "[${NAME}] removing Spotify apt source + keyring"
    sudo rm -f "${SPOTIFY_APT_LIST}" "${SPOTIFY_KEYRING}"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
