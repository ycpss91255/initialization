#!/usr/bin/env bash
# install-auto-power-profile.sh — install/remove the auto-power-profile tool.
#
#   bash install-auto-power-profile.sh          # install + enable
#   bash install-auto-power-profile.sh remove   # uninstall
#
# Self-elevates with sudo if not already root (prompts for the password), so
# there is no need to prepend `sudo` manually. The tool is system-wide; the
# invoking user is derived from $SUDO_USER for the informational summary only,
# never hardcoded.
#
# NOTE: the copy functions are named install_tool / remove_tool (NOT install /
# remove) and use `command install`, so the coreutil `install` is always the
# external binary and can never be shadowed by a same-named shell function
# (that shadowing caused an unbounded-recursion SIGSEGV in an earlier draft).
set -euo pipefail

# Re-exec under sudo when not root, preserving the requested action.
if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- bash "$0" "$@"
fi

# Resolve paths relative to this script so it works from any cwd.
SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Whoever invoked sudo (informational only; the tool itself is system-wide).
TARGET_USER="${SUDO_USER:-root}"

BIN_DST="/usr/local/bin/auto-power-profile"
SERVICE_DST="/etc/systemd/system/auto-power-profile.service"
TIMER_DST="/etc/systemd/system/auto-power-profile.timer"
RULES_DST="/etc/udev/rules.d/99-auto-power-profile.rules"

install_tool() {
    echo "==> target user: ${TARGET_USER}"
    echo "==> install decision script + units"
    command install -m0755 "${SRC_DIR}/auto-power-profile"            "${BIN_DST}"
    command install -m0644 "${SRC_DIR}/auto-power-profile.service"    "${SERVICE_DST}"
    command install -m0644 "${SRC_DIR}/auto-power-profile.timer"      "${TIMER_DST}"
    command install -m0644 "${SRC_DIR}/99-auto-power-profile.rules"   "${RULES_DST}"

    echo "==> enable timer + reload udev"
    systemctl daemon-reload
    systemctl enable --now auto-power-profile.timer
    udevadm control --reload-rules
    udevadm trigger --subsystem-match=power_supply

    echo "Installed. It re-evaluates on AC plug/unplug and every 2 minutes."
    echo "View switches with: journalctl -t auto-power-profile"
}

remove_tool() {
    echo "==> disable timer + remove files"
    systemctl disable --now auto-power-profile.timer 2>/dev/null || true
    rm -f "${BIN_DST}" "${SERVICE_DST}" "${TIMER_DST}" "${RULES_DST}"
    systemctl daemon-reload
    udevadm control --reload-rules

    echo "Removed. The current power profile is left untouched;"
    echo "set it manually with e.g. powerprofilesctl set balanced."
}

case "${1:-install}" in
    install) install_tool ;;
    remove)  remove_tool ;;
    *) echo "usage: $0 [install|remove]" >&2; exit 2 ;;
esac
