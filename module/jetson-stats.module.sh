#!/usr/bin/env bash
# module/jetson-stats.module.sh — jetson-stats: jtop monitor TUI for Jetson  [archetype: custom]
#
# New module per issue #37 / PRD Q51 (Sec 6.3.3): on Jetson Orin the de-facto
# GPU/power monitor is `jtop` (from the `jetson-stats` PyPI package) — L4T
# does not preinstall it. Custom archetype: pip install (`sudo pip3 install
# -U jetson-stats`), falling back to pipx on PEP 668 (externally-managed)
# Python environments. The installer drops a root `jtop.service`; the user
# must re-login (or `sudo systemctl restart jtop.service`) before `jtop`
# can talk to it — doctor() checks the service state.
#
# Standalone usage:
#   bash module/jetson-stats.module.sh install [--dry-run]
#   bash module/jetson-stats.module.sh upgrade / remove / purge / verify
#   bash module/jetson-stats.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/jetson-stats.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install jetson-stats

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
NAME="jetson-stats"
VERSION_PROVIDED="pip-managed"
CATEGORY="optional"
TAGS=("hardware")
HOMEPAGE="https://github.com/rbonghi/jetson_stats"
declare -gA DESCRIPTION=(
    [en]="jetson-stats — jtop monitor TUI for NVIDIA Jetson (iGPU, nvpmodel, clocks, fan)"
    [zh-TW]="jetson-stats — NVIDIA Jetson 的 jtop 監控 TUI(iGPU、nvpmodel、時脈、風扇)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="jtop.service was installed as a root service — re-login (or run 'sudo systemctl restart jtop.service') before launching jtop."
    [zh-TW]="jtop.service 已安裝為 root 服務 — 請重新登入(或執行 'sudo systemctl restart jtop.service')後再啟動 jtop。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04")
SUPPORTED_PLATFORMS=("jetson-orin")
DEPENDS_ON=("git" "curl")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v jtop && jtop --version"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# Version recorded in the Sidecar by the phase-invocation wrapper after a
# successful install/upgrade (overrides the generic VERSION_PROVIDED default).
module_provided_version() { _jetson_stats_version; }

# ── Archetype D — custom (pip install, pipx fallback on PEP 668) ────────────
PIP_PKG="jetson-stats"
# jtop's post-install drops a root systemd unit; pip uninstall does not
# clean it up, so purge() does. Overridable for tests.
JTOP_SERVICE_UNIT="${JTOP_SERVICE_UNIT:-/etc/systemd/system/jtop.service}"
# L4T marker file used by detect(). Overridable for tests.
JETSON_TEGRA_RELEASE="${JETSON_TEGRA_RELEASE:-/etc/nv_tegra_release}"

# is_installed: pip metadata is authoritative; fall back to a jtop binary on
# PATH (covers pipx installs whose metadata lives in the root pipx home).
is_installed() {
    if pip3 show "${PIP_PKG}" >/dev/null 2>&1; then
        return 0
    fi
    command -v jtop >/dev/null 2>&1
}

# install: pick the installer (pip vs pipx per PEP 668), run it under sudo
# (jtop.service must be a root service).
install() {
    module_dryrun_guard install \
        "sudo pip3 install -U ${PIP_PKG} (PEP 668 env -> sudo pipx install) + jtop.service" \
        && return 0
    module_skip_if_installed && return 0
    _jetson_stats_pkg_install || return $?
}

# upgrade: same installer split (pip -U / pipx upgrade). Falls through to
# install when nothing is installed yet.
upgrade() {
    module_dryrun_guard upgrade \
        "sudo pip3 install -U ${PIP_PKG} (PEP 668 env -> sudo pipx upgrade)" \
        && return 0
    if ! is_installed; then
        log_info "[${NAME}] not installed yet — running install instead"
        install
        return $?
    fi
    _jetson_stats_pkg_upgrade || return $?
}

# remove: uninstall the package (whichever of pip/pipx owns it) but KEEP the
# leftover jtop.service unit (remove vs purge semantics).
remove() {
    module_dryrun_guard remove \
        "sudo pip3/pipx uninstall ${PIP_PKG} (jtop.service unit kept: ${JTOP_SERVICE_UNIT})" \
        && return 0
    module_skip_if_not_installed && return 0
    _jetson_stats_pkg_uninstall || return $?
}

# purge: remove + stop/disable jtop.service and delete the leftover unit
# file (pip uninstall never cleans up the post-install service drop).
purge() {
    module_dryrun_guard purge \
        "sudo pip3/pipx uninstall ${PIP_PKG} + disable jtop.service + rm ${JTOP_SERVICE_UNIT}" \
        && return 0
    if is_installed; then
        _jetson_stats_pkg_uninstall || return $?
    fi
    sudo systemctl disable --now jtop.service 2>/dev/null || true
    sudo rm -f "${JTOP_SERVICE_UNIT}"
}

verify() {
    module_default_verify
}

# detect: jetson hardware only — the engine's form-factor classification or
# the L4T BSP marker file.
detect() {
    [[ "${INIT_UBUNTU_FORM_FACTOR:-}" == "jetson-orin" ]] && return 0
    [[ -f "${JETSON_TEGRA_RELEASE}" ]]
}

# is_recommended: yes on jetson-orin when not yet installed (issue #37 AC
# "init flow installs jetson-stats on Jetson Orin"); never elsewhere.
is_recommended() {
    is_installed && return 1
    [[ "${INIT_UBUNTU_FORM_FACTOR:-}" == "jetson-orin" ]]
}

# is_outdated: pip's own outdated query (no sudo; degrades gracefully on
# hosts without pip3 — empty output means "not outdated").
is_outdated() {
    pip3 list --outdated 2>/dev/null | grep -q "^${PIP_PKG} "
}

# doctor: health check — package installed, jtop binary runnable, then
# jtop.service state + Sidecar presence (both warn-only: a fresh install
# before re-login legitimately has an inactive service).
doctor() {
    if ! is_installed; then
        log_warn "[${NAME}] doctor: jetson-stats is not installed"
        return 1
    fi
    local _bin
    _bin="$(command -v jtop 2>/dev/null)" || {
        log_warn "[${NAME}] doctor: jtop binary not found on PATH"
        return 1
    }
    if ! "${_bin}" --version >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: ${_bin} --version failed"
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet jtop.service 2>/dev/null \
            || log_warn "[${NAME}] doctor: jtop.service is not active — re-login or 'sudo systemctl restart jtop.service'"
    else
        log_warn "[${NAME}] doctor: systemctl not available; cannot check jtop.service"
    fi
    module_sidecar_get_version "${NAME}" >/dev/null 2>&1 \
        || log_warn "[${NAME}] doctor: sidecar missing (installed outside init_ubuntu?)"
    return 0
}

# ── Private helpers ─────────────────────────────────────────────────────────

# Single privileged-execution seam. Tests intercept it by shadowing `sudo`,
# and routing pip3/pipx through one indirection keeps shellcheck from
# pairing a `sudo pip3` literal with the spec's pip3() mock (SC2032 —
# functions cannot cross the sudo boundary anyway, so make the seam explicit).
_jetson_stats_sudo() {
    sudo "$@"
}

# PEP 668 check: an EXTERNALLY-MANAGED marker in the Python stdlib dir means
# bare `pip3 install` is refused and pipx is the sanctioned route.
_jetson_stats_pep668() {
    local _stdlib
    _stdlib="$(python3 -c 'import sysconfig; print(sysconfig.get_path("stdlib"))' 2>/dev/null)" \
        || return 1
    [[ -n "${_stdlib}" && -f "${_stdlib}/EXTERNALLY-MANAGED" ]]
}

# Print which installer this environment wants: "pip" or "pipx".
_jetson_stats_installer() {
    if _jetson_stats_pep668; then
        printf 'pipx'
    else
        printf 'pip'
    fi
}

_jetson_stats_pkg_install() {
    have_sudo_access 2>/dev/null \
        || { log_error "[${NAME}] sudo required (jtop.service is a root service)"; return 1; }
    case "$(_jetson_stats_installer)" in
        pipx)
            command -v pipx >/dev/null 2>&1 \
                || sudo apt-get install -y pipx \
                || { log_error "[${NAME}] PEP 668 environment but pipx is unavailable"; return 1; }
            log_info "[${NAME}] PEP 668 environment — sudo pipx install ${PIP_PKG}"
            _jetson_stats_sudo pipx install "${PIP_PKG}" || return 1
            ;;
        *)
            log_info "[${NAME}] sudo pip3 install -U ${PIP_PKG}"
            _jetson_stats_sudo pip3 install -U "${PIP_PKG}" || return 1
            ;;
    esac
}

_jetson_stats_pkg_upgrade() {
    have_sudo_access 2>/dev/null \
        || { log_error "[${NAME}] sudo required"; return 1; }
    case "$(_jetson_stats_installer)" in
        pipx)
            log_info "[${NAME}] sudo pipx upgrade ${PIP_PKG}"
            _jetson_stats_sudo pipx upgrade "${PIP_PKG}" || return 1
            ;;
        *)
            log_info "[${NAME}] sudo pip3 install -U ${PIP_PKG}"
            _jetson_stats_sudo pip3 install -U "${PIP_PKG}" || return 1
            ;;
    esac
}

# Uninstall via whichever of pip/pipx owns the package: pip metadata visible
# -> pip; otherwise assume the pipx fallback installed it.
_jetson_stats_pkg_uninstall() {
    have_sudo_access 2>/dev/null \
        || { log_error "[${NAME}] sudo required"; return 1; }
    if pip3 show "${PIP_PKG}" >/dev/null 2>&1; then
        log_info "[${NAME}] sudo pip3 uninstall -y ${PIP_PKG}"
        _jetson_stats_sudo pip3 uninstall -y "${PIP_PKG}" || return 1
    else
        log_info "[${NAME}] sudo pipx uninstall ${PIP_PKG}"
        _jetson_stats_sudo pipx uninstall "${PIP_PKG}" || return 1
    fi
}

# Version string for the Sidecar: pip-reported package version, falling
# back to the literal "pip-managed" when pip has no answer (pipx installs).
_jetson_stats_version() {
    local _ver=""
    _ver="$(pip3 show "${PIP_PKG}" 2>/dev/null | awk '/^Version:/{print $2}')" \
        || _ver=""
    printf '%s' "${_ver:-pip-managed}"
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
