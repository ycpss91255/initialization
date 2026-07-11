#!/usr/bin/env bash
# module/python3.module.sh — Python 3 toolchain base (apt)  [archetype: apt]
#
# Foundation module for the small-tools modularization program: the Python 3
# runtime + the packaging/build toolchain (pip, dev headers, setuptools) that
# higher-level Python tools build on. Higher-level modules DEPEND ON this one
# (python3 <- pipx <- tmuxp / claude-monitor / qmk-firmware), so the engine
# installs the toolchain first. There is no single `python3` metapackage that
# pulls all of these, so APT_PKGS lists them explicitly and verify/doctor
# probe the `python3` interpreter.
#
# Standalone usage:
#   bash module/python3.module.sh install [--dry-run]
#   bash module/python3.module.sh upgrade / remove / purge / verify / doctor
#   bash module/python3.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/python3.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install python3

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
NAME="python3"
VERSION_PROVIDED="apt-managed"
CATEGORY="base"
TAGS=("python" "runtime")
HOMEPAGE="https://www.python.org/"
declare -gA DESCRIPTION=(
    [en]="python3 — Python 3 runtime + packaging toolchain (pip, dev headers, setuptools)"
    [zh-TW]="python3 — Python 3 執行環境 + 打包工具鏈(pip、dev 標頭、setuptools)"
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
TEST_VERIFY_CMD="command -v python3 && python3 --version"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=("python3" "python3-pip" "python3-dev" "python3-setuptools")
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

# doctor: the toolchain is only healthy if the interpreter actually runs. The
# apt archetype's is_installed just checks dpkg state; a real health check runs
# `python3 --version` over and above the packaging bits.
doctor() {
    if ! is_installed; then
        log_warn "[${NAME}] doctor: python3 toolchain is not fully installed"
        return 1
    fi
    if ! python3 --version >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: python3 is present but 'python3 --version' failed"
        return 1
    fi
    return 0
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
