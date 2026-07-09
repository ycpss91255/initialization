#!/usr/bin/env bash
# set-address-pool.sh — pin Docker's default network address pool.
#
# Docker's built-in pool (172.17.0.0/16 ... 172.31.0.0/16, 15 x /16 blocks)
# exhausts under heavy docker-compose churn and silently falls back to
# slicing 192.168.0.0/16 into /20 blocks. Pinning one larger, predictable
# pool avoids both the overflow and the resulting range jump.
#
# Usage:
#   sudo script/docker-tool/set-address-pool.sh                 # 172.16.0.0/12, /24
#   sudo script/docker-tool/set-address-pool.sh 172.16.0.0/12 24
#
# DOCKER_DAEMON_JSON_PATH overrides the daemon.json location (tests point it
# at a scratch file); it defaults to the real /etc/docker/daemon.json.

set -euo pipefail

DAEMON_JSON="${DOCKER_DAEMON_JSON_PATH:-/etc/docker/daemon.json}"
TMP="${DAEMON_JSON}.tmp"
BASE_POOL="${1:-172.16.0.0/12}"
POOL_SIZE="${2:-24}"

# Always clean up the scratch file on exit — success, validation failure, or
# an early jq/arg error all funnel through here so nothing is left behind in
# /etc/docker/.
trap 'rm -f "$TMP"' EXIT

if [ "$EUID" -ne 0 ]; then
  echo "This script edits ${DAEMON_JSON} and must run as root." >&2
  echo "Re-run with: sudo $0 [base] [size]" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "jq is required." >&2; exit 1; }

mkdir -p "$(dirname "$DAEMON_JSON")"
[ -f "$DAEMON_JSON" ] || echo '{}' > "$DAEMON_JSON"

BACKUP="${DAEMON_JSON}.bak.$(date +%Y%m%d%H%M%S)"
cp "$DAEMON_JSON" "$BACKUP"
echo "Backed up existing config to ${BACKUP}"

jq --arg base "$BASE_POOL" --argjson size "$POOL_SIZE" \
  '.["default-address-pools"] = [{"base": $base, "size": $size}]' \
  "$DAEMON_JSON" > "$TMP"

# Validate the candidate config BEFORE it ever touches the live file — if it's
# broken, leave the original daemon.json (and its backup) untouched instead of
# overwriting first and only warning after the fact.
if command -v dockerd >/dev/null 2>&1; then
  if ! dockerd --validate --config-file "$TMP" 2>&1 | grep -q "configuration OK"; then
    echo "New config failed dockerd --validate — leaving ${DAEMON_JSON} untouched." >&2
    exit 1
  fi
fi

mv "$TMP" "$DAEMON_JSON"
echo "Updated ${DAEMON_JSON}:"
cat "$DAEMON_JSON"

cat <<'EOM'

Not restarted automatically. Restarting the Docker daemon stops every running
container whose restart-policy is not "always"/"unless-stopped" (and a
container started with --rm is deleted outright, not just stopped).

Check what is running first:
  docker ps -a --format '{{.Names}}  restart={{.HostConfig.RestartPolicy.Name}}'

Then apply when ready:
  sudo systemctl restart docker

Verify afterwards:
  docker network inspect bridge --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
EOM
