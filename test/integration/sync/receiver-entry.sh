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
#      ever committed — .tmp/ is gitignored and `just -f justfile.ci clean` removes it).
#   2. Creates a non-root `syncuser` (key-only auth; password stays locked
#      so PasswordAuthentication can never succeed — PRD §16.4).
#   3. Drops a no-op `e2e-probe` fixture module into syncuser's user-local
#      module dir so the remote `setup_ubuntu import --apply` can run a
#      real install lifecycle without apt/sudo (this image is alpine).
#   3b. (AC-15 mixed archetypes, issue #178) Stages a REAL github-release
#      archetype module `e2e-ghr` in syncuser's user-local catalog — driven
#      offline + sudo-free through the #175 INIT_UBUNTU_TEST_GH_* fixture
#      seam — plus its pre-built release tarball. This exercises the real
#      non-dry-run github-release path (fetch seam → gzip sniff → tar
#      --strip-components extract → symlink → Sidecar) on the RECEIVING side
#      of a sync, alongside the config archetype (repo `ssh-config`). The
#      module carries no apt dependency, so import's dep resolver never drags
#      curl (uninstallable on this alpine image).
#   4. Exposes `setup_ubuntu` on sshd's default PATH via a /usr/bin wrapper
#      (sync's remote tool check + import/export need it, PRD §16.3). The
#      wrapper exports the github-release fixture seam so the wrapped real
#      import lifecycle resolves e2e-ghr's asset offline.
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
# ── Mixed-archetype: a REAL github-release module + offline fixture (AC-15) ──
# `e2e-ghr` uses the github-release archetype macro exactly like a shipped
# module (gum/eza/…), but is user-home + sudo-free + dependency-free so it
# installs as syncuser on this apt-less alpine image without dragging
# curl. The fetch boundary is stubbed by the #175 seam
# (INIT_UBUNTU_TEST_GH_FIXTURE_DIR, exported from the wrapper below); the
# whole downstream chain — gzip sniff, tar --strip-components extract,
# symlink, Sidecar — runs for real inside the wrapped import lifecycle.
GHR_ARCH="$(uname -m)"
GHR_VERSION="1.2.3"
GHR_STEM="e2e-ghr_${GHR_VERSION}_Linux_${GHR_ARCH}"
GHR_ASSET="${GHR_STEM}.tar.gz"
GHR_FIXTURE_DIR="${SYNC_HOME}/.local/share/init_ubuntu/e2e-ghr-fixture"

# Build the release tarball: a single top-level dir (STRIP_COMPONENTS=1
# strips it) holding a fake executable that reports its version.
mkdir -p "${GHR_FIXTURE_DIR}/${GHR_STEM}"
printf '#!/bin/sh\necho "e2e-ghr version v%s"\n' "${GHR_VERSION}" \
    > "${GHR_FIXTURE_DIR}/${GHR_STEM}/e2e-ghr"
chmod +x "${GHR_FIXTURE_DIR}/${GHR_STEM}/e2e-ghr"
( cd "${GHR_FIXTURE_DIR}" && tar -czf "${GHR_ASSET}" "${GHR_STEM}" && rm -rf "${GHR_STEM}" )

# Static-pattern github-release module (no run-time asset resolver, so the
# fixture name is deterministic). USE_SUDO=false + user-home targets keep it
# sudo-free; DEPENDS_ON=() keeps import's dep closure to itself.
cat > "${SYNC_HOME}/.config/init_ubuntu/module/e2e-ghr.module.sh" <<EOF
NAME="e2e-ghr"
VERSION_PROVIDED="latest"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=true
INSTALL_TARGET_DEFAULT="user-home"

GITHUB_REPO="init-ubuntu/e2e-ghr"
GITHUB_ASSET_PATTERN="${GHR_ASSET}"
INSTALL_DIR="\${HOME}/.local/share/init_ubuntu/e2e-ghr"
BIN_NAME="e2e-ghr"
BIN_PATH_IN_TAR="e2e-ghr"
BIN_LINK="\${HOME}/.local/bin/e2e-ghr"
STRIP_COMPONENTS=1
USE_SUDO=false
CONFIG_PATHS=()
module_use_github_release_archetype

# Write the Sidecar on success so state/Sidecar invariants hold (ADR-0001).
# The archetype default fetch symlinks straight into BIN_LINK but does not
# create its parent dir; mirror the shipped github-release modules (gum) and
# ensure ~/.local/bin exists first.
install() {
    module_dryrun_guard install "fetch + symlink \${BIN_LINK}" && return 0
    module_skip_if_installed && return 0
    mkdir -p "\${BIN_LINK%/*}"
    _module_github_release_fetch_and_install || return \$?
    module_sidecar_write "\${NAME}" "${GHR_VERSION}"
}
remove() {
    module_default_github_release_remove || return \$?
    module_sidecar_remove "\${NAME}"
}
purge() { remove; }
detect() { return 0; }
is_recommended() { ! is_installed; }
EOF
chown -R "${SYNC_USER}:${SYNC_USER}" "${SYNC_HOME}/.config" "${SYNC_HOME}/.local"

# ── setup_ubuntu on sshd's default non-login PATH ────────────────────────────
# A plain symlink breaks the entrypoint's BASH_SOURCE-based REPO_ROOT
# resolution, so use an exec wrapper. The wrapper also exports the #175
# github-release fixture seam: sshd command execs get a non-login env that
# drops custom vars, so baking them into the wrapper is what lets the wrapped
# real import lifecycle resolve e2e-ghr's asset offline (the version seam is
# log-only for a static-pattern module but kept for parity with the harness).
cat > /usr/bin/setup_ubuntu <<EOF
#!/bin/sh
export INIT_UBUNTU_TEST_MODE=1
export INIT_UBUNTU_TEST_GH_FIXTURE_DIR="${GHR_FIXTURE_DIR}"
export INIT_UBUNTU_TEST_GH_VERSION="${GHR_VERSION}"
exec /source/setup_ubuntu.sh "\$@"
EOF
chmod +x /usr/bin/setup_ubuntu

touch "${E2E_DIR}/ready"
exec /usr/sbin/sshd -D -e
