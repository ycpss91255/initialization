#!/usr/bin/env bash
# module/tealdeer.module.sh — tealdeer: fast tldr client  [archetype: apt]
#
# A fast Rust implementation of the tldr community man-page examples. Ubuntu
# ships the `tealdeer` package; the binary it provides is `tldr`. The page
# cache is seeded once post-install with `tldr --update` — that step needs
# network access, so it is best-effort and must NOT fail the install (mirrors
# the small-tools tealdeer handling, issue #263).
#
# Standalone usage:
#   bash module/tealdeer.module.sh install [--dry-run]
#   bash module/tealdeer.module.sh upgrade / remove / purge / verify / doctor
#   bash module/tealdeer.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/tealdeer.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install tealdeer

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
NAME="tealdeer"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("cli" "documentation")
HOMEPAGE="https://github.com/tealdeer-rs/tealdeer"
declare -gA DESCRIPTION=(
    [en]="tealdeer — fast Rust tldr client (community man-page examples), binary: tldr"
    [zh-TW]="tealdeer — 快速的 Rust tldr 客戶端(社群精簡 man 範例),binary 為 tldr"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="tealdeer provides the 'tldr' command. Cache was seeded with 'tldr --update' (best-effort); re-run 'tldr --update' if it had no network at install time."
    [zh-TW]="tealdeer 提供 'tldr' 指令。快取已以 'tldr --update' 初始化(盡力而為);若安裝時無網路,請稍後自行執行 'tldr --update'。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server" "wsl" "container" "vm")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v tldr && tldr --version | head -n1"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=("tealdeer")
APT_PPA=""
CONFIG_PATHS=("${HOME}/.cache/tealdeer")
module_use_apt_archetype

# Override install: archetype installs the apt package, then seed the tldr page
# cache. Seeding needs the network, so it is best-effort — a failed update logs
# a warning and still returns 0 (issue #263).
install() {
    module_default_apt_install || return $?
    module_dryrun_guard install "tldr --update (seed page cache, best-effort)" && return 0
    _tealdeer_seed_cache
}

# ── Required hooks (detect + is_recommended stay module-specific) ────────────
detect() {
    command -v apt-get >/dev/null 2>&1
}

is_recommended() {
    ! is_installed
}

# doctor: real runtime health check — the tldr binary must answer --version.
doctor() {
    is_installed || { log_warn "[${NAME}] doctor: not installed"; return 1; }
    tldr --version >/dev/null 2>&1 || {
        log_warn "[${NAME}] doctor: 'tldr --version' failed"
        return 1
    }
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────
# Seed the tldr page cache. Best-effort: a missing binary or no network only
# warns — the install must not fail on a cosmetic cache refresh (issue #263).
_tealdeer_seed_cache() {
    command -v tldr >/dev/null 2>&1 || {
        log_warn "[${NAME}] tldr not on PATH; run 'tldr --update' after install"
        return 0
    }
    if tldr --update >/dev/null 2>&1; then
        log_info "[${NAME}] tldr page cache seeded"
    else
        log_warn "[${NAME}] 'tldr --update' failed (needs network); run it later"
    fi
    return 0
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
