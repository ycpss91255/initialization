#!/bin/bash
# Route an internal domain's DNS lookups to the company DNS over the F5 VPN (tun0).
# Per-user, secret values live in the config pointed to by $F5_SPLIT_DNS_CONF
# (set by the systemd drop-in). This script contains no secrets and no username.
# Triggered automatically by f5-split-dns.service when the tun0 interface appears.
set -u
CONF="${F5_SPLIT_DNS_CONF:?F5_SPLIT_DNS_CONF not set (configured by the systemd drop-in)}"
if [ ! -r "$CONF" ]; then
  logger -t f5-split-dns "config not readable: $CONF"
  exit 0
fi
# shellcheck source=/dev/null
. "$CONF"

IFACE="${1:-tun0}"
: "${INTERNAL_DNS_IP:?set INTERNAL_DNS_IP in $CONF}"
: "${COMPANY_DOMAIN:?set COMPANY_DOMAIN in $CONF}"
DOMAIN="~${COMPANY_DOMAIN}"

# tun0 may not be registered with systemd-resolved yet right after creation; retry a few times.
for i in $(seq 1 10); do
  if ip link show "$IFACE" >/dev/null 2>&1; then
    if resolvectl dns "$IFACE" "$INTERNAL_DNS_IP" && resolvectl domain "$IFACE" "$DOMAIN"; then
      logger -t f5-split-dns "applied split-DNS on $IFACE ($DOMAIN -> $INTERNAL_DNS_IP)"
      exit 0
    fi
  fi
  sleep 1
done
logger -t f5-split-dns "failed: $IFACE not ready within timeout"
exit 0
