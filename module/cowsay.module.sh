#!/usr/bin/env bash
# module/cowsay.module.sh — cowsay: talking cow ASCII art  [archetype: apt]
#
# Renders a message as speech from an ASCII cow (and other creatures). A
# terminal novelty. Ubuntu ships the `cowsay` package; the binary is `cowsay`.
#
# Standalone usage:
#   bash module/cowsay.module.sh install [--dry-run]
#   bash module/cowsay.module.sh upgrade / remove / purge / verify / doctor
#   bash module/cowsay.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/cowsay.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install cowsay

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
NAME="cowsay"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("novelty" "fun")
HOMEPAGE="https://github.com/cowsay-org/cowsay"
declare -gA DESCRIPTION=(
    [en]="cowsay — render a message as speech from an ASCII cow"
    [zh-TW]="cowsay — 讓 ASCII 母牛在終端機說出訊息"
)
declare -gA POST_INSTALL_MESSAGE=()
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl" "container" "vm")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
# The Debian/Ubuntu cowsay package installs its binary at /usr/games/cowsay,
# and /usr/games is absent from the default non-login PATH used by `bash -c`,
# `docker exec ... bash -c`, and cron. Probe PATH first (command -v), then fall
# back to the packaged location so a correctly-installed cowsay verifies even
# when /usr/games is off PATH. COWSAY_GAMES_BIN overrides the packaged path
# (tests inject a stub). The command -v branch stays first so a PATH-resolvable
# cowsay still wins.
TEST_VERIFY_CMD="command -v cowsay >/dev/null 2>&1 || [ -x \"${COWSAY_GAMES_BIN:-/usr/games/cowsay}\" ]"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=("cowsay")
APT_PPA=""
CONFIG_PATHS=()
module_use_apt_archetype

# ── Required hooks (detect + is_recommended stay module-specific) ────────────
detect() {
    command -v apt-get >/dev/null 2>&1
}

is_recommended() {
    ! is_installed
}

# doctor: real runtime health check — the cowsay binary must resolve on PATH
# or at its packaged location. The Debian/Ubuntu package installs
# /usr/games/cowsay, and /usr/games is not on the default non-login PATH, so a
# bare `command -v cowsay` probe falsely fails while dpkg-based is_installed
# still reports installed. Probe PATH first, then fall back to the packaged
# path (COWSAY_GAMES_BIN overrides it for tests).
doctor() {
    is_installed || { log_warn "[${NAME}] doctor: not installed"; return 1; }
    local _games_bin="${COWSAY_GAMES_BIN:-/usr/games/cowsay}"
    command -v cowsay >/dev/null 2>&1 || [ -x "${_games_bin}" ] || {
        log_warn "[${NAME}] doctor: 'cowsay' not found on PATH or at ${_games_bin}"
        return 1
    }
    return 0
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
