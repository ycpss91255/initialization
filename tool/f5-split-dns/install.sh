#!/usr/bin/env bash
# Install f5-split-dns: route an internal domain over the F5 VPN (tun0).
#
#   sudo bash install.sh
#
# The target user is derived from $SUDO_USER, so no home path or username is
# hardcoded. The only file holding real values is the per-user config seeded
# from config.example; edit it after install and restart the service.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

# Resolve paths relative to this script so it works from any cwd.
SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

USER_NAME="${SUDO_USER:?run via sudo so the target user can be detected}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
USER_GROUP="$(id -gn "$USER_NAME")"
CONF_DIR="$USER_HOME/.config/f5-split-dns"
CONF="$CONF_DIR/config"
DROPIN="/etc/systemd/system/f5-split-dns.service.d/10-config-path.conf"

# 1. script + base unit (no secrets, no username)
install -m0755 "$SRC_DIR/f5-split-dns.sh"      /usr/local/sbin/f5-split-dns.sh
install -m0644 "$SRC_DIR/f5-split-dns.service" /etc/systemd/system/f5-split-dns.service

# 2. drop-in: point the service at the user's config (derived, not hardcoded)
install -d -m0755 /etc/systemd/system/f5-split-dns.service.d
printf '[Service]\nEnvironment=F5_SPLIT_DNS_CONF=%s\n' "$CONF" > "$DROPIN"

# 3. seed the per-user config from the example (user fills in real values)
install -d -o "$USER_NAME" -g "$USER_GROUP" -m0755 "$CONF_DIR"
[ -f "$CONF" ] || install -o "$USER_NAME" -g "$USER_GROUP" -m0644 "$SRC_DIR/config.example" "$CONF"

# 4. enable (runs once now if tun0 is already up; WantedBy handles future connects)
systemctl daemon-reload
systemctl enable --now f5-split-dns.service

echo "Installed. Now edit $CONF with the real INTERNAL_DNS_IP / COMPANY_DOMAIN,"
echo "then: sudo systemctl restart f5-split-dns.service (or reconnect the VPN)."
