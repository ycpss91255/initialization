#!/usr/bin/env bash
# shellcheck disable=SC2034  # module metadata vars (NAME / DESCRIPTION / CATEGORY / TAGS / ...) consumed by engine post-source — https://www.shellcheck.net/wiki/SC2034
# module/docker-rootless.module.sh — rootless Docker for a low-privilege account  [archetype: custom (hand-written)]
#
# Sets up rootless Docker (issue #422) for ONE dedicated, non-root account on
# Ubuntu + systemd, GPU-ready. The existing `docker` module (rootful Engine) is
# left untouched; the two coexist and are selected by socket, never by sudo:
#   rootful   /var/run/docker.sock
#   rootless  /run/user/<uid>/docker.sock   (DOCKER_HOST=unix:///run/user/<uid>/docker.sock)
#
# Parameters (environment, because phases take no positional args):
#   DOCKER_ROOTLESS_USER      target account (default: rootless). Created when
#                             missing; must NOT be in the docker/sudo/admin
#                             groups. `remove` deletes the account (userdel -r).
#   DOCKER_ROOTLESS_DELEGATE  true (default) = install the user@<uid>.service
#                             drop-in `Delegate=cpu cpuset io memory pids`
#                             (io/cpuset limits are silently ignored otherwise).
#
# Lifecycle: install = packages -> account -> subuid/subgid -> linger ->
# user@<uid> up -> Delegate drop-in -> dockerd-rootless-setuptool -> docker.service
# drop-in (socket wait + Restart) -> enable --now -> (NVIDIA) user-level runtime
# config + user docker restart. Never touches the rootful daemon. remove reverses all of it and
# removes only the packages this module itself installed (recorded in a marker).
#
# ── BEGIN: shared-bootstrap ─────────────────────────────────────────────────
# Dual-mode entry detection.
# When invoked directly (`bash module/<x>.module.sh ...`), MODULE_STANDALONE
# becomes "true": module_bootstrap flips on strict mode, resolves
# MODULE_DIR / REPO_ROOT / LIB_DIR, and sources the lib helpers; the footer
# below then dispatches to module_standalone_main "$@".
# When source'd by lib/runner.sh into its sub-shell, MODULE_STANDALONE is
# "false": runner already sourced lib helpers + set strict mode, so the stub
# never sources the bootstrap and module_bootstrap would be a no-op anyway.
# All the shared boilerplate lives in lib/module_bootstrap.sh.

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

# ── BEGIN: shared-metadata ──────────────────────────────────────────────────
NAME="docker-rootless"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("container" "devops" "security")
HOMEPAGE="https://docs.docker.com/engine/security/rootless/"

declare -gA DESCRIPTION=(
    [en]="Rootless Docker for a dedicated non-root account (systemd user service, GPU-ready)"
    [zh-TW]="為專用非 root 帳號設定 Rootless Docker(systemd 使用者服務,支援 GPU)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Use it as the target account with DOCKER_HOST=unix:///run/user/<uid>/docker.sock (never 'sudo docker'). Consumers ordered After=docker.service see the socket."
    [zh-TW]="以目標帳號使用並設定 DOCKER_HOST=unix:///run/user/<uid>/docker.sock(不要用 'sudo docker')。"
)
declare -gA WARN_MESSAGE=(
    [en]="Creates a dedicated account; 'remove' DELETES that account and its home (userdel -r)."
    [zh-TW]="會建立專用帳號;'remove' 會刪除該帳號與其家目錄(userdel -r)。"
)

SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop" "server")
DEPENDS_ON=("docker")
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="medium"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v dockerd-rootless-setuptool.sh"
# ── END: shared-metadata ────────────────────────────────────────────────────

# Engine-consumed metadata (see mscorefonts): one in-file use keeps SC2034 quiet.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── BEGIN: archetype-data ───────────────────────────────────────────────────
# Archetype D: custom. Parameters + overridable roots (tests point
# DOCKER_ROOTLESS_ROOT at a scratch dir; production leaves it empty).
: "${DOCKER_ROOTLESS_USER:=rootless}"
: "${DOCKER_ROOTLESS_DELEGATE:=true}"
: "${DOCKER_ROOTLESS_ROOT:=}"
# Packages this module may install (and later remove only if it installed them).
_DR_PKGS=("uidmap" "docker-ce-rootless-extras")
# ── END: archetype-data ─────────────────────────────────────────────────────

# ── Helpers ─────────────────────────────────────────────────────────────────
# Reads never need root; everything that changes the system or looks inside the
# (mode 750) target home goes through `sudo` so it can be mocked.

_dr_user()      { printf '%s' "${DOCKER_ROOTLESS_USER}"; }
_dr_uid()       { id -u "$(_dr_user)" 2>/dev/null; }
_dr_user_exists() { id -u "$(_dr_user)" >/dev/null 2>&1; }
_dr_home()      { getent passwd "$(_dr_user)" | cut -d: -f6; }
_dr_dropin()    { printf '%s/etc/systemd/system/user@%s.service.d/delegate.conf' "${DOCKER_ROOTLESS_ROOT}" "$(_dr_uid)"; }
_dr_state_dir() { printf '%s/var/lib/init_ubuntu/docker-rootless' "${DOCKER_ROOTLESS_ROOT}"; }
_dr_marker()    { printf '%s/%s.pkgs' "$(_dr_state_dir)" "$(_dr_user)"; }
_dr_linger_file() { printf '%s/var/lib/systemd/linger/%s' "${DOCKER_ROOTLESS_ROOT}" "$(_dr_user)"; }
_dr_unit_file() { printf '%s/.config/systemd/user/docker.service' "$(_dr_home)"; }
_dr_wait_dropin() { printf '%s/.config/systemd/user/docker.service.d/10-wait-socket.conf' "$(_dr_home)"; }
_dr_sock()      { printf '/run/user/%s/docker.sock' "$(_dr_uid)"; }

# Run a command as the target account with a working user-systemd environment.
_dr_as_user() {
    local _uid; _uid="$(_dr_uid)"
    sudo -H -u "$(_dr_user)" env "XDG_RUNTIME_DIR=/run/user/${_uid}" \
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${_uid}/bus" "$@"
}

# Account name must be a plain, non-root login name (also protects userdel -r).
_dr_valid_user() {
    [[ "$(_dr_user)" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] && [[ "$(_dr_user)" != "root" ]]
}

# 0 when the account is in a privileged group (docker / sudo / admin) or is the
# invoking account: never acceptable for a dedicated rootless account.
_dr_privileged_reason() {
    local _g
    for _g in $(id -nG "$(_dr_user)" 2>/dev/null); do
        case "${_g}" in docker|sudo|admin) printf 'member of group %s' "${_g}"; return 0 ;; esac
    done
    if [[ "$(_dr_user)" == "${SUDO_USER:-}" || "$(_dr_user)" == "${USER:-}" ]]; then
        printf 'is the invoking account'; return 0
    fi
    return 1
}

# Write <content> to <path> as root (or as the target user when mode=user) only
# if it differs. Sets _DR_CHANGED=1 when it wrote.
_DR_CHANGED=0
_dr_put() {
    local _mode="$1" _path="$2" _content="$3" _cur=""
    local -a _pfx=(sudo)
    [[ "${_mode}" == "user" ]] && _pfx=(sudo -H -u "$(_dr_user)")
    _cur="$("${_pfx[@]}" cat "${_path}" 2>/dev/null || true)"
    [[ "${_cur}" == "${_content}" ]] && return 0
    "${_pfx[@]}" mkdir -p "$(dirname -- "${_path}")" || return 1
    printf '%s\n' "${_content}" | "${_pfx[@]}" tee "${_path}" >/dev/null || return 1
    _DR_CHANGED=1
}

_dr_pkg_installed() { dpkg -s "$1" 2>/dev/null | grep -q '^Status: install ok installed'; }

_dr_has_subid() {
    local _f
    for _f in subuid subgid; do
        grep -q "^$(_dr_user):" "${DOCKER_ROOTLESS_ROOT}/etc/${_f}" 2>/dev/null || return 1
    done
}

# AppArmor (Ubuntu 24.04+) blocks unprivileged userns unless a profile allows
# rootlesskit. 0 = restriction active and no rootlesskit profile found.
_dr_apparmor_blocks() {
    [[ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || true)" == "1" ]] || return 1
    ! grep -rqs rootlesskit "${DOCKER_ROOTLESS_ROOT}/etc/apparmor.d" 2>/dev/null
}

_dr_has_subid_any() {
    grep -q "^$(_dr_user):" "${DOCKER_ROOTLESS_ROOT}/etc/subuid" "${DOCKER_ROOTLESS_ROOT}/etc/subgid" 2>/dev/null
}

_dr_has_nvidia() {
    command -v nvidia-smi >/dev/null 2>&1 || command -v nvidia-ctk >/dev/null 2>&1
}

# Register the nvidia runtime in the ACCOUNT's own daemon.json
# (~/.config/docker/daemon.json) so `--gpus all` and `--device nvidia.com/gpu=all`
# work rootless. User-level only: never touches /etc/docker, the rootful daemon
# or /etc/nvidia-container-runtime/config.toml. Idempotent: skipped when the
# runtime is already registered. Sets _DR_GPU_CONFIGURED=1 when it changed
# something (the caller then restarts the USER docker service). The file lives in
# the account's home, so `remove` (userdel -r) discards it with the account.
_DR_GPU_CONFIGURED=0
_dr_gpu_configure() {
    _DR_GPU_CONFIGURED=0
    command -v nvidia-ctk >/dev/null 2>&1 || return 0
    local _cfg; _cfg="$(_dr_home)/.config/docker/daemon.json"
    if sudo -H -u "$(_dr_user)" grep -q '"nvidia"' "${_cfg}" 2>/dev/null; then
        return 0
    fi
    log_info "[${NAME}] registering the nvidia runtime in ${_cfg} (user-level)"
    _dr_as_user nvidia-ctk runtime configure --runtime=docker "--config=${_cfg}" || return 1
    _DR_GPU_CONFIGURED=1
}

# GPU readiness: advisory only (never changes the host's NVIDIA stack).
_dr_gpu_check() {
    _dr_has_nvidia || return 0
    if ! systemctl list-unit-files 'nvidia-cdi-refresh*' 2>/dev/null | grep -q nvidia-cdi-refresh; then
        log_warn "[${NAME}] NVIDIA present but nvidia-cdi-refresh unit not found: the CDI spec will not be regenerated at boot (install/upgrade nvidia-container-toolkit)"
    fi
    if grep -Eqs '^[[:space:]]*no-cgroups[[:space:]]*=[[:space:]]*true' \
        "${DOCKER_ROOTLESS_ROOT}/etc/nvidia-container-runtime/config.toml"; then
        log_warn "[${NAME}] nvidia-container-runtime 'no-cgroups = true' is set; keep it at the default (false) for rootless GPU"
    fi
}

# ── Lifecycle ───────────────────────────────────────────────────────────────

detect() {
    command -v lsb_release >/dev/null 2>&1 \
        && [[ "$(lsb_release -is 2>/dev/null)" == "Ubuntu" ]] \
        && [[ -d "${DOCKER_ROOTLESS_ROOT}/run/systemd/system" ]]
}

# Creates an account and later deletes it: opt-in only, never in Quick Setup.
is_recommended() {
    return 1
}

# The account exists and rootless docker's user unit was generated for it.
is_installed() {
    _dr_valid_user || return 1
    _dr_user_exists || return 1
    sudo test -f "$(_dr_unit_file)" 2>/dev/null
}

# Steps shared by install and upgrade; every step is a no-op when already done.
_dr_converge() {
    local _uid
    _uid="$(_dr_uid)"

    if ! _dr_has_subid; then
        log_info "[${NAME}] adding subuid/subgid range for $(_dr_user)"
        sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$(_dr_user)" || return 1
    fi

    if [[ ! -e "$(_dr_linger_file)" ]]; then
        log_info "[${NAME}] enabling linger for $(_dr_user)"
        sudo loginctl enable-linger "$(_dr_user)" || return 1
    fi

    _DR_CHANGED=0
    if [[ "${DOCKER_ROOTLESS_DELEGATE}" == "true" ]]; then
        _dr_put root "$(_dr_dropin)" "[Service]
Delegate=cpu cpuset io memory pids" || return 1
        if [[ "${_DR_CHANGED}" == "1" ]]; then
            log_info "[${NAME}] installed Delegate drop-in $(_dr_dropin)"
            sudo systemctl daemon-reload || return 1
        fi
    fi

    # user@<uid> (and its runtime dir) must be up before any `systemctl --user`.
    # Starting an active unit is a no-op; a changed Delegate needs a restart,
    # which stops that user's services, so it only applies at next user@ start.
    sudo systemctl start "user@${_uid}.service" || return 1

    if ! sudo test -f "$(_dr_unit_file)"; then
        log_info "[${NAME}] running dockerd-rootless-setuptool.sh install as $(_dr_user)"
        _dr_as_user dockerd-rootless-setuptool.sh install || return 1
    fi

    # After=user@UID.service alone is NOT enough: docker.sock appears later.
    # ExecStartPost holds docker.service in 'activating' until the socket exists,
    # so units ordered After=docker.service see it; Restart rides out a slow start.
    _DR_CHANGED=0
    _dr_put user "$(_dr_wait_dropin)" "[Service]
Restart=on-failure
RestartSec=3
ExecStartPost=/usr/bin/timeout 60 /bin/bash -c 'until [ -S \"%t/docker.sock\" ]; do sleep 1; done'" || return 1
    if [[ "${_DR_CHANGED}" == "1" ]]; then
        log_info "[${NAME}] installed socket-wait drop-in"
        _dr_as_user systemctl --user daemon-reload || return 1
    fi

    _dr_as_user systemctl --user enable --now docker.service || return 1

    # GPU: user-level nvidia runtime config, then restart ONLY the user daemon.
    _dr_gpu_configure || return 1
    if [[ "${_DR_GPU_CONFIGURED}" == "1" ]]; then
        _dr_as_user systemctl --user restart docker.service || return 1
    fi
}

install() {
    module_dryrun_guard install "apt-install uidmap docker-ce-rootless-extras (if missing) + create account ${DOCKER_ROOTLESS_USER} + subuid/subgid + linger + Delegate drop-in + dockerd-rootless-setuptool + socket-wait drop-in + enable --now docker" && return 0
    module_skip_if_installed && return 0

    have_sudo_access 2>/dev/null \
        || { log_error "[${NAME}] sudo required"; return 1; }
    _dr_valid_user \
        || { log_error "[${NAME}] invalid DOCKER_ROOTLESS_USER '${DOCKER_ROOTLESS_USER}'"; return 1; }

    # Preflight: refuse before changing anything.
    local _why
    if _dr_user_exists && _why="$(_dr_privileged_reason)"; then
        log_error "[${NAME}] ${DOCKER_ROOTLESS_USER} must be a dedicated unprivileged account (${_why})"
        return 1
    fi
    if _dr_apparmor_blocks; then
        log_warn "[${NAME}] AppArmor restricts unprivileged user namespaces and no rootlesskit profile exists in /etc/apparmor.d; rootless dockerd will likely fail to start (see https://docs.docker.com/engine/security/rootless/)"
    fi

    # Packages: install and RECORD only the ones that were missing.
    local -a _missing=() ; local _p
    for _p in "${_DR_PKGS[@]}"; do
        _dr_pkg_installed "${_p}" || _missing+=("${_p}")
    done
    if [[ "${#_missing[@]}" -gt 0 ]]; then
        log_info "[${NAME}] apt-get install ${_missing[*]}"
        sudo apt-get update -qq || log_warn "[${NAME}] apt-get update failed (continuing)"
        sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${_missing[@]}" || return 1
        sudo mkdir -p "$(_dr_state_dir)" || return 1
        printf '%s\n' "${_missing[@]}" | sudo tee -a "$(_dr_marker)" >/dev/null || return 1
    fi

    if ! _dr_user_exists; then
        log_info "[${NAME}] creating account ${DOCKER_ROOTLESS_USER} (no docker group, no sudo, locked password)"
        sudo useradd --create-home --shell /bin/bash "${DOCKER_ROOTLESS_USER}" || return 1
    fi

    _dr_converge || return 1
    _dr_gpu_check
    return 0
}

upgrade() {
    module_dryrun_guard upgrade "apt-get install --only-upgrade ${_DR_PKGS[*]} + re-apply drop-ins + enable --now docker" && return 0
    if ! is_installed; then
        log_info "[${NAME}] not installed yet; running install instead"
        install
        return $?
    fi
    have_sudo_access 2>/dev/null || { log_error "[${NAME}] sudo required"; return 1; }
    sudo apt-get update -qq || log_warn "[${NAME}] apt-get update failed (continuing)"
    sudo apt-get install --only-upgrade -y "${_DR_PKGS[@]}" || return 1
    _dr_converge || return 1
    _dr_as_user systemctl --user try-restart docker.service || true
    _dr_gpu_check
}

# Reverse everything install did (the sequence verified by hand on two hosts).
remove() {
    module_dryrun_guard remove "stop user@UID + user-runtime-dir@UID, disable linger, userdel -r ${DOCKER_ROOTLESS_USER}, clean subuid/subgid, rm Delegate drop-in, daemon-reload, remove packages this module installed" && return 0

    local _marker; _marker="$(_dr_marker)"
    if ! _dr_user_exists && [[ ! -e "${_marker}" ]] && ! _dr_has_subid_any; then
        log_info "[${NAME}] not installed; nothing to do"
        return 0
    fi

    have_sudo_access 2>/dev/null || { log_error "[${NAME}] sudo required"; return 1; }
    _dr_valid_user \
        || { log_error "[${NAME}] invalid DOCKER_ROOTLESS_USER '${DOCKER_ROOTLESS_USER}'"; return 1; }

    local _uid="" _dropin=""
    if _dr_user_exists; then
        local _why
        if _why="$(_dr_privileged_reason)"; then
            log_error "[${NAME}] refusing to delete ${DOCKER_ROOTLESS_USER}: not a dedicated rootless account (${_why})"
            return 1
        fi
        _uid="$(_dr_uid)"; _dropin="$(_dr_dropin)"
        log_info "[${NAME}] stopping user services of ${DOCKER_ROOTLESS_USER} (uid ${_uid})"
        sudo systemctl stop "user@${_uid}.service" "user-runtime-dir@${_uid}.service" || true
        sudo loginctl disable-linger "${DOCKER_ROOTLESS_USER}" || true
        sudo userdel -r "${DOCKER_ROOTLESS_USER}" || log_warn "[${NAME}] userdel -r reported a problem (continuing)"
    fi

    local _f
    for _f in subuid subgid; do
        if grep -q "^${DOCKER_ROOTLESS_USER}:" "${DOCKER_ROOTLESS_ROOT}/etc/${_f}" 2>/dev/null; then
            sudo sed -i "/^${DOCKER_ROOTLESS_USER}:/d" "${DOCKER_ROOTLESS_ROOT}/etc/${_f}" || true
        fi
    done

    if [[ -n "${_uid}" ]]; then
        sudo rm -f "${_dropin}"
        sudo rmdir --ignore-fail-on-non-empty "$(dirname -- "${_dropin}")" 2>/dev/null || true
        sudo systemctl daemon-reload || true
    fi

    if [[ -f "${_marker}" ]]; then
        local -a _ours=()
        mapfile -t _ours < <(sort -u "${_marker}")
        if [[ "${#_ours[@]}" -gt 0 ]]; then
            log_info "[${NAME}] removing packages installed by this module: ${_ours[*]}"
            sudo apt-get remove -y "${_ours[@]}" || log_warn "[${NAME}] apt-get remove failed (continuing)"
        fi
        sudo rm -f "${_marker}"
    fi
    return 0
}

purge() {
    module_dryrun_guard purge "remove + drop the module state dir" && return 0
    remove || return $?
    sudo rm -rf "$(_dr_state_dir)" 2>/dev/null || true
    return 0
}

verify() {
    module_default_verify
}

is_outdated() {
    _dr_pkg_installed docker-ce-rootless-extras || return 1
    apt list --upgradable docker-ce-rootless-extras 2>/dev/null | grep -q 'upgradable'
}

# Runtime health: dedicated account, linger, user@ up, socket present.
doctor() {
    module_dryrun_guard doctor "account + group + linger + user@UID + docker.sock + AppArmor" && return 0
    if ! is_installed; then
        log_warn "[${NAME}] doctor: not installed"
        return 1
    fi
    local _rc=0 _why
    if _why="$(_dr_privileged_reason)"; then
        log_warn "[${NAME}] doctor: ${DOCKER_ROOTLESS_USER} is not a dedicated account (${_why})"; _rc=1
    fi
    [[ -e "$(_dr_linger_file)" ]] \
        || { log_warn "[${NAME}] doctor: linger is not enabled"; _rc=1; }
    _dr_has_subid \
        || { log_warn "[${NAME}] doctor: no subuid/subgid entry"; _rc=1; }
    systemctl is-active --quiet "user@$(_dr_uid).service" \
        || { log_warn "[${NAME}] doctor: user@$(_dr_uid).service is not active"; _rc=1; }
    sudo test -S "$(_dr_sock)" \
        || { log_warn "[${NAME}] doctor: $(_dr_sock) missing (DOCKER_HOST=unix://$(_dr_sock))"; _rc=1; }
    if _dr_apparmor_blocks; then
        log_warn "[${NAME}] doctor: AppArmor userns restriction active without a rootlesskit profile"; _rc=1
    fi
    _dr_gpu_check
    return "${_rc}"
}

# ── BEGIN: shared-footer ────────────────────────────────────────────────────
# Standalone entry footer — DO NOT REMOVE.
# Lets `bash module/<name>.module.sh install --dry-run` work as a
# self-contained command. Skipped automatically when source'd by lib/runner.sh.

if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
# ── END: shared-footer ──────────────────────────────────────────────────────
