#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata vars (NAME / DESCRIPTION / CATEGORY / TAGS / ...) consumed by engine post-source — https://www.shellcheck.net/wiki/SC2034
# module/nvidia-driver.module.sh — NVIDIA proprietary driver via graphics-drivers PPA

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

# ── Metadata ────────────────────────────────────────────────────────────────
NAME="nvidia-driver"
VERSION_PROVIDED="ubuntu-recommended"
CATEGORY="optional"
TAGS=("gpu" "nvidia" "hardware")
HOMEPAGE="https://launchpad.net/~graphics-drivers/+archive/ubuntu/ppa"
declare -gA DESCRIPTION=(
    [en]="NVIDIA proprietary driver (auto-detected recommended version via ubuntu-drivers)"
    [zh-TW]="NVIDIA 專有驅動(自動透過 ubuntu-drivers 取建議版)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Reboot is required for the new NVIDIA driver to take effect."
    [zh-TW]="NVIDIA 驅動安裝後需要 reboot 才會生效。"
)
declare -gA WARN_MESSAGE=(
    [en]="Switching GPU driver may temporarily break the desktop session. Save your work first."
    [zh-TW]="切換 GPU 驅動可能暫時影響桌面 session,請先儲存工作。"
)
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop")
DEPENDS_ON=("git" "curl")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="high"
REBOOT_REQUIRED=true
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v nvidia-smi && nvidia-smi"

APT_PPA="ppa:graphics-drivers/ppa"
_APT_PREREQ=("ubuntu-drivers-common" "linux-headers-generic" "dkms")

# ── Lifecycle (hand-written — uses ubuntu-drivers autoinstall) ──────────────
is_installed() {
    command -v nvidia-smi >/dev/null 2>&1
}

detect() {
    command -v lspci >/dev/null 2>&1 || return 1
    lspci 2>/dev/null | grep -qi 'nvidia'
}

is_recommended() {
    is_installed && return 1
    [[ "${INIT_UBUNTU_FORM_FACTOR:-desktop}" == "desktop" ]] || return 1
    if command -v systemd-detect-virt >/dev/null 2>&1 \
        && systemd-detect-virt --container --quiet 2>/dev/null; then
        return 1
    fi
    detect
}

install() {
    module_dryrun_guard install "add ${APT_PPA} + ubuntu-drivers autoinstall" && return 0
    module_skip_if_installed && return 0

    have_sudo_access 2>/dev/null \
        || { log_error "[${NAME}] sudo required"; return 1; }

    if ! lspci 2>/dev/null | grep -qi 'nvidia'; then
        log_warn "[${NAME}] no NVIDIA GPU detected — aborting"
        return 1
    fi

    log_info "[${NAME}] adding ${APT_PPA}"
    sudo add-apt-repository -y "${APT_PPA}" \
        || log_warn "[${NAME}] add-apt-repository failed (continuing)"

    sudo apt-get update -qq || log_warn "[${NAME}] apt-get update failed (continuing)"

    log_info "[${NAME}] installing prereqs: ${_APT_PREREQ[*]}"
    sudo apt-get install -y --no-install-recommends "${_APT_PREREQ[@]}" \
        || { log_error "[${NAME}] prereq install failed"; return 1; }

    log_info "[${NAME}] running ubuntu-drivers autoinstall"
    sudo ubuntu-drivers autoinstall \
        || { log_error "[${NAME}] ubuntu-drivers autoinstall failed"; return 1; }

    log_warn "[${NAME}] reboot required for driver to take effect"
}

upgrade() {
    module_dryrun_guard upgrade "apt-get update + dist-upgrade nvidia-*" && return 0
    have_sudo_access 2>/dev/null || { log_error "[${NAME}] sudo required"; return 1; }
    sudo apt-get update -qq || log_warn "[${NAME}] apt-get update failed (continuing)"
    sudo apt-get install --only-upgrade -y "nvidia-driver-*" || true
}

remove() {
    module_dryrun_guard remove "apt-get purge nvidia-* + restore nouveau" && return 0
    module_skip_if_not_installed && return 0
    sudo apt-get purge -y 'nvidia-*' || true
    sudo apt autoremove -y || true
    log_warn "[${NAME}] reboot to fall back to ${RECOVERY_FALLBACK:-nouveau}"
}

purge() {
    module_dryrun_guard purge "apt-purge nvidia-* + remove PPA" && return 0
    remove
    sudo add-apt-repository -y --remove "${APT_PPA}" 2>/dev/null || true
}

verify() {
    module_default_verify
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
