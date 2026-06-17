#!/usr/bin/env bash
# test/integration/sync/receiver-entry.sh — sshd receiver for the AC-15
# dual-container sync E2E (PRD §16, Q52; issue #67).
#
# Runs as PID 1 (root) of the `sync-receiver` compose service (profile
# sync-e2e; see compose.yaml). It models "the other machine" of
# `setup_ubuntu sync user@host`:
#
#   1. Generates sshd host keys + a throwaway client keypair, sharing the
#      client key and the host public key with the sender ci container
#      through the bind-mounted repo at /source/.tmp/sync-e2e/ (nothing is
#      ever committed — .tmp/ is gitignored and `make clean` removes it).
#   2. Creates a non-root `syncuser` (key-only auth; password stays locked
#      so PasswordAuthentication can never succeed — PRD §16.4).
#   3. Drops a no-op `e2e-probe` fixture module into syncuser's user-local
#      module dir so the remote `setup_ubuntu import --apply` can run a
#      real install lifecycle without apt/sudo (this image is alpine).
#   4. Exposes `setup_ubuntu` on sshd's default PATH via a /usr/bin wrapper
#      (sync's remote tool check + import/export need it, PRD §16.3).
#   5. Touches the `ready` marker and execs sshd in the foreground.
#
# Always-act semantics: every step below must succeed for the receiver to
# be usable, so fail-fast -euo applies (ADR-0007 Exception).

set -euo pipefail

E2E_DIR="/source/.tmp/sync-e2e"
SYNC_USER="syncuser"
SYNC_HOME="/home/${SYNC_USER}"

# openssh is baked into test-tools:local (dockerfile/Dockerfile.test-tools);
# the apk fallback only covers a stale pre-#67 image.
if ! command -v sshd >/dev/null 2>&1 && [[ ! -x /usr/sbin/sshd ]]; then
    apk add --no-cache openssh
fi

rm -rf "${E2E_DIR}"
mkdir -p "${E2E_DIR}"

# ── sshd host keys (shared so the sender can pin known_hosts — sync runs
#    with StrictHostKeyChecking=yes, PRD §16.4) ──────────────────────────────
ssh-keygen -A
cp /etc/ssh/ssh_host_ed25519_key.pub "${E2E_DIR}/"

# ── Non-root login user, key-only auth ──────────────────────────────────────
if ! id "${SYNC_USER}" >/dev/null 2>&1; then
    adduser -D -s /bin/bash "${SYNC_USER}"
fi
# busybox adduser -D locks the account ('!' in /etc/shadow) which makes
# sshd reject even pubkey auth; '*' keeps password login impossible while
# allowing key auth.
sed -i -E "s/^(${SYNC_USER}):!+:/\1:*:/" /etc/shadow

ssh-keygen -t ed25519 -N "" -C "init-ubuntu-sync-e2e" -f "${E2E_DIR}/id_ed25519"
mkdir -p "${SYNC_HOME}/.ssh"
cp "${E2E_DIR}/id_ed25519.pub" "${SYNC_HOME}/.ssh/authorized_keys"
chmod 700 "${SYNC_HOME}/.ssh"
chmod 600 "${SYNC_HOME}/.ssh/authorized_keys"
chown -R "${SYNC_USER}:${SYNC_USER}" "${SYNC_HOME}/.ssh"

# ── Fixture module in syncuser's user-local module dir ──────────────────────
# registry_load_all() picks up ~/.config/init_ubuntu/module/*.module.sh, so
# the import plan classifies e2e-probe as `install` (known in catalog) and
# the apply phase runs its lifecycle — touching a marker instead of apt.
mkdir -p "${SYNC_HOME}/.config/init_ubuntu/module"
cat > "${SYNC_HOME}/.config/init_ubuntu/module/e2e-probe.module.sh" <<'EOF'
NAME="e2e-probe"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=()
CONFLICTS_WITH=()

install() {
    mkdir -p "${HOME}/.local/share"
    touch "${HOME}/.local/share/e2e-probe-installed"
}
remove() { rm -f "${HOME}/.local/share/e2e-probe-installed"; }
purge()  { remove; }
EOF
chown -R "${SYNC_USER}:${SYNC_USER}" "${SYNC_HOME}/.config"

# ── setup_ubuntu on sshd's default non-login PATH ────────────────────────────
# A plain symlink breaks the entrypoint's BASH_SOURCE-based REPO_ROOT
# resolution, so use an exec wrapper.
printf '#!/bin/sh\nexec /source/setup_ubuntu.sh "$@"\n' > /usr/bin/setup_ubuntu
chmod +x /usr/bin/setup_ubuntu

touch "${E2E_DIR}/ready"
exec /usr/sbin/sshd -D -e
