#!/usr/bin/env bats
# test/unit/secrets_spec.bats — lib/secrets.sh + setup_secrets.sh (issue #44)
#
# Covers:
#   - backend autoselect priority (pass -> gnome-keyring -> encrypted-file)
#     with `command -v` mocked via PATH stubs
#   - config.ini [secrets] backend honored + explicit-backend validation
#   - encrypted-file backend real round-trip (openssl baked in test-tools)
#   - plaintext-leak assertions (secret never readable outside the backend)
#   - ssh-key generate argv hygiene: no secret material ever passes through
#     process args / shell history (AC-20)
#
# External binaries (pass / secret-tool / ssh-keygen / ssh-add / ssh-copy-id)
# are stubbed via PATH override, same style as sync_spec.bats.

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false

    export INIT_UBUNTU_CONFIG_DIR="${INIT_UBUNTU_TEST_SCRATCH}/config/init_ubuntu"
    export INIT_UBUNTU_SECRETS_DIR="${INIT_UBUNTU_TEST_SCRATCH}/config/init_ubuntu/secrets"
    unset INIT_UBUNTU_SECRETS_BACKEND INIT_UBUNTU_SECRETS_PASSPHRASE_FILE \
        DBUS_SESSION_BUS_ADDRESS SSH_AUTH_SOCK 2>/dev/null || true

    SECRETS_STUB_DIR="${INIT_UBUNTU_TEST_SCRATCH}/stubs"
    SECRETS_STUB_LOG="${INIT_UBUNTU_TEST_SCRATCH}/stub-calls.log"
    mkdir -p "${SECRETS_STUB_DIR}"
    : > "${SECRETS_STUB_LOG}"
    export PATH="${SECRETS_STUB_DIR}:${PATH}"
}

teardown() {
    teardown_test_env
}

_load_secrets() {
    # shellcheck source=../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../lib/config.sh
    source "${LIB_DIR}/config.sh"
    # shellcheck source=../../lib/secrets.sh
    source "${LIB_DIR}/secrets.sh"
}

# _stub <name> [body...] — drop an executable stub on the stub PATH that
# logs its argv to $SECRETS_STUB_LOG, then runs the optional body.
_stub() {
    local _name="$1"; shift
    {
        printf '#!/usr/bin/env bash\n'
        printf 'echo "%s $*" >> "%s"\n' "${_name}" "${SECRETS_STUB_LOG}"
        if (( $# > 0 )); then printf '%s\n' "$@"; else printf 'exit 0\n'; fi
    } > "${SECRETS_STUB_DIR}/${_name}"
    chmod +x "${SECRETS_STUB_DIR}/${_name}"
}

_write_passphrase() {
    PASSPHRASE_FILE="${INIT_UBUNTU_TEST_SCRATCH}/pp.txt"
    printf '%s\n' "$1" > "${PASSPHRASE_FILE}"
    export INIT_UBUNTU_SECRETS_PASSPHRASE_FILE="${PASSPHRASE_FILE}"
}

_set_backend() {
    export INIT_UBUNTU_SECRETS_BACKEND="$1"
}

_set_agent_sock() {
    export SSH_AUTH_SOCK="$1"
}

# ── backend autoselect ──────────────────────────────────────────────────────

@test "autoselect prefers pass when installed" {
    _load_secrets
    _stub pass
    run secrets_backend_resolve
    assert_success
    assert_output "pass"
}

@test "autoselect falls back to gnome-keyring (secret-tool + DBus) when pass absent" {
    command -v pass >/dev/null 2>&1 && skip "real pass installed in image"
    _load_secrets
    _stub secret-tool
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/fake-bus"
    run secrets_backend_resolve
    assert_success
    assert_output "gnome-keyring"
}

@test "autoselect skips gnome-keyring without a DBus session" {
    command -v pass >/dev/null 2>&1 && skip "real pass installed in image"
    _load_secrets
    _stub secret-tool
    run secrets_backend_resolve
    assert_success
    assert_output "encrypted-file"
}

@test "autoselect bottoms out at encrypted-file" {
    command -v pass >/dev/null 2>&1 && skip "real pass installed in image"
    command -v secret-tool >/dev/null 2>&1 && skip "real secret-tool installed in image"
    _load_secrets
    run secrets_backend_resolve
    assert_success
    assert_output "encrypted-file"
}

@test "config.ini [secrets] backend overrides autoselect" {
    _load_secrets
    _stub pass
    config_init
    config_set secrets.backend encrypted-file
    run secrets_backend_resolve
    assert_success
    assert_output "encrypted-file"
}

@test "config.ini [secrets] backend = auto keeps autoselect" {
    _load_secrets
    _stub pass
    config_init
    config_set secrets.backend auto
    run secrets_backend_resolve
    assert_success
    assert_output "pass"
}

@test "INIT_UBUNTU_SECRETS_BACKEND env wins over config.ini" {
    _load_secrets
    _stub pass
    config_init
    config_set secrets.backend pass
    _set_backend encrypted-file
    run secrets_backend_resolve
    assert_success
    assert_output "encrypted-file"
}

@test "explicitly requested backend that is unavailable fails with exit 3" {
    command -v pass >/dev/null 2>&1 && skip "real pass installed in image"
    _load_secrets
    _set_backend pass
    run secrets_backend_resolve
    assert_failure 3
    assert_output --partial "pass"
}

@test "unknown backend name fails with exit 2" {
    _load_secrets
    _set_backend vault9000
    run secrets_backend_resolve
    assert_failure 2
}

# ── generic store API (backend dispatch; #68 mounts token/list/remove here) ─

@test "secrets_store routes to the pass backend and feeds the secret via stdin" {
    _load_secrets
    _set_backend pass
    export SECRETS_FAKE_PASS_STORE="${INIT_UBUNTU_TEST_SCRATCH}/fake-pass-store"
    _stub pass "cat > \"\${SECRETS_FAKE_PASS_STORE:?}\""
    printf '%s' 'tok-12345' | secrets_store gh-token
    grep -q '^pass insert' "${SECRETS_STUB_LOG}"
    grep -q 'init_ubuntu/gh-token' "${SECRETS_STUB_LOG}"
    [[ "$(cat "${SECRETS_FAKE_PASS_STORE}")" == "tok-12345" ]]
    # secret must never appear in the argv recorded by the stub
    run ! grep -q 'tok-12345' "${SECRETS_STUB_LOG}"
}

@test "secrets_store rejects names with path separators (exit 2)" {
    _load_secrets
    _set_backend encrypted-file
    _write_passphrase "pp"
    run bash -c 'source "${LIB_DIR}/logger.sh"; source "${LIB_DIR}/config.sh";
        source "${LIB_DIR}/secrets.sh";
        printf x | secrets_store "../evil"'
    assert_failure 2
}

@test "secrets_store takes the secret on stdin only — a value argv is rejected" {
    _load_secrets
    _set_backend encrypted-file
    _write_passphrase "pp"
    run bash -c 'source "${LIB_DIR}/logger.sh"; source "${LIB_DIR}/config.sh";
        source "${LIB_DIR}/secrets.sh";
        secrets_store myname my-secret-value </dev/null'
    assert_failure 2
}

# ── encrypted-file backend: real round-trip in container ───────────────────

@test "encrypted-file round-trip: store then retrieve returns the secret" {
    _load_secrets
    _set_backend encrypted-file
    _write_passphrase "correct horse battery staple"
    printf '%s' 's3cret-payload-XYZ' | secrets_store api-token
    [[ -f "${INIT_UBUNTU_SECRETS_DIR}/api-token.enc" ]]
    run secrets_retrieve api-token
    assert_success
    assert_output "s3cret-payload-XYZ"
}

@test "encrypted-file store never writes plaintext anywhere under config dir" {
    _load_secrets
    _set_backend encrypted-file
    _write_passphrase "pp-secret-123"
    printf '%s' 'leak-canary-7f3a9' | secrets_store canary
    # neither the secret nor the passphrase may be greppable on disk
    run ! grep -RFq 'leak-canary-7f3a9' "${INIT_UBUNTU_TEST_SCRATCH}/config"
    run ! grep -RFq 'pp-secret-123' "${INIT_UBUNTU_TEST_SCRATCH}/config"
}

@test "encrypted-file artifacts get owner-only permissions" {
    _load_secrets
    _set_backend encrypted-file
    _write_passphrase "pp"
    printf '%s' 'x' | secrets_store permcheck
    run stat -c '%a' "${INIT_UBUNTU_SECRETS_DIR}"
    assert_output "700"
    run stat -c '%a' "${INIT_UBUNTU_SECRETS_DIR}/permcheck.enc"
    assert_output "600"
}

@test "encrypted-file retrieve with wrong passphrase fails without plaintext" {
    _load_secrets
    _set_backend encrypted-file
    _write_passphrase "right-passphrase"
    printf '%s' 'super-secret' | secrets_store locked
    _write_passphrase "wrong-passphrase"
    run secrets_retrieve locked
    assert_failure
    refute_output --partial 'super-secret'
}

@test "encrypted-file passphrase never passes through openssl argv" {
    _load_secrets
    _set_backend encrypted-file
    _write_passphrase "argv-canary-passphrase"
    _stub openssl 'cat > /dev/null'
    printf '%s' 'payload' | secrets_store argvcheck
    grep -q '^openssl ' "${SECRETS_STUB_LOG}"
    run ! grep -q 'argv-canary-passphrase' "${SECRETS_STUB_LOG}"
    run ! grep -q 'payload' "${SECRETS_STUB_LOG}"
}

@test "secrets_exists / secrets_list / secrets_remove work on encrypted-file" {
    _load_secrets
    _set_backend encrypted-file
    _write_passphrase "pp"
    printf '%s' 'v1' | secrets_store alpha
    printf '%s' 'v2' | secrets_store beta
    secrets_exists alpha
    run secrets_list
    assert_success
    assert_line "alpha"
    assert_line "beta"
    secrets_remove alpha
    run secrets_exists alpha
    assert_failure
    [[ ! -e "${INIT_UBUNTU_SECRETS_DIR}/alpha.enc" ]]
}

# ── setup_secrets.sh CLI dispatcher ─────────────────────────────────────────

@test "setup_secrets.sh --help prints usage and exits 0" {
    run "${REPO_ROOT}/setup_secrets.sh" --help
    assert_success
    assert_output --partial "ssh-key"
}

@test "setup_secrets.sh with no args prints usage and exits 2" {
    run "${REPO_ROOT}/setup_secrets.sh"
    assert_failure 2
}

@test "setup_secrets.sh unknown subcommand exits 2" {
    run "${REPO_ROOT}/setup_secrets.sh" frobnicate
    assert_failure 2
}

# ── token set / token get (issue #68) ───────────────────────────────────────

@test "token set/get round-trip via CLI on encrypted-file backend" {
    _set_backend encrypted-file
    _write_passphrase "pp"
    run bash -c "printf '%s' 'cli-tok-9f2' | '${REPO_ROOT}/setup_secrets.sh' token set gh-token"
    assert_success
    run --separate-stderr "${REPO_ROOT}/setup_secrets.sh" token get gh-token
    assert_success
    assert_output "cli-tok-9f2"
}

@test "setup_secrets.sh gpg subcommand is reserved for #68 (exit 2)" {
    run "${REPO_ROOT}/setup_secrets.sh" gpg generate
    assert_failure 2
    assert_output --partial "#68"
}

@test "setup_secrets.sh list subcommand is reserved for #68 (exit 2)" {
    run "${REPO_ROOT}/setup_secrets.sh" list
    assert_failure 2
    assert_output --partial "#68"
}

@test "setup_secrets.sh remove subcommand is reserved for #68 (exit 2)" {
    run "${REPO_ROOT}/setup_secrets.sh" remove gh
    assert_failure 2
    assert_output --partial "#68"
}

# ── ssh-key generate: argv hygiene (AC-20) ──────────────────────────────────

@test "ssh-key generate calls ssh-keygen without any passphrase in argv" {
    _stub ssh-keygen
    run "${REPO_ROOT}/setup_secrets.sh" ssh-key generate \
        --file "${INIT_UBUNTU_TEST_SCRATCH}/sshkey" --comment test@host
    assert_success
    grep -q '^ssh-keygen ' "${SECRETS_STUB_LOG}"
    grep -q -- '-t ed25519' "${SECRETS_STUB_LOG}"
    grep -q -- "-f ${INIT_UBUNTU_TEST_SCRATCH}/sshkey" "${SECRETS_STUB_LOG}"
    grep -q -- '-C test@host' "${SECRETS_STUB_LOG}"
    # passphrase prompting is delegated to ssh-keygen's own tty prompt:
    # nothing sensitive may ever travel through argv (AC-20)
    run ! grep -q -- '-N' "${SECRETS_STUB_LOG}"
}

@test "ssh-key generate --no-passphrase passes only an empty -N" {
    _stub ssh-keygen
    run "${REPO_ROOT}/setup_secrets.sh" ssh-key generate --no-passphrase \
        --file "${INIT_UBUNTU_TEST_SCRATCH}/sshkey"
    assert_success
    grep -q -- '-N ' "${SECRETS_STUB_LOG}"
}

@test "ssh-key generate refuses to overwrite an existing key" {
    _stub ssh-keygen
    touch "${INIT_UBUNTU_TEST_SCRATCH}/sshkey"
    run "${REPO_ROOT}/setup_secrets.sh" ssh-key generate \
        --file "${INIT_UBUNTU_TEST_SCRATCH}/sshkey"
    assert_failure 1
    run ! grep -q '^ssh-keygen' "${SECRETS_STUB_LOG}"
}

@test "ssh-key generate rejects unknown key type (exit 2)" {
    _stub ssh-keygen
    run "${REPO_ROOT}/setup_secrets.sh" ssh-key generate --type dsa-9000 \
        --file "${INIT_UBUNTU_TEST_SCRATCH}/sshkey"
    assert_failure 2
}

# ── ssh-key load ────────────────────────────────────────────────────────────

@test "ssh-key load without ssh-agent fails with exit 3 and a hint" {
    _stub ssh-add
    touch "${INIT_UBUNTU_TEST_SCRATCH}/sshkey"
    run "${REPO_ROOT}/setup_secrets.sh" ssh-key load \
        --file "${INIT_UBUNTU_TEST_SCRATCH}/sshkey"
    assert_failure 3
    assert_output --partial "ssh-agent"
}

@test "ssh-key load adds the key via ssh-add" {
    _stub ssh-add
    touch "${INIT_UBUNTU_TEST_SCRATCH}/sshkey"
    _set_agent_sock "${INIT_UBUNTU_TEST_SCRATCH}/fake.sock"
    run "${REPO_ROOT}/setup_secrets.sh" ssh-key load \
        --file "${INIT_UBUNTU_TEST_SCRATCH}/sshkey"
    assert_success
    grep -q "^ssh-add ${INIT_UBUNTU_TEST_SCRATCH}/sshkey" "${SECRETS_STUB_LOG}"
}

@test "ssh-key load fails on missing key file" {
    _stub ssh-add
    _set_agent_sock "${INIT_UBUNTU_TEST_SCRATCH}/fake.sock"
    run "${REPO_ROOT}/setup_secrets.sh" ssh-key load \
        --file "${INIT_UBUNTU_TEST_SCRATCH}/nope"
    assert_failure 1
}

# ── ssh-key copy ────────────────────────────────────────────────────────────

@test "ssh-key copy requires a user@host target (exit 2)" {
    _stub ssh-copy-id
    run "${REPO_ROOT}/setup_secrets.sh" ssh-key copy
    assert_failure 2
}

@test "ssh-key copy delegates to ssh-copy-id with -i <pubkey>" {
    _stub ssh-copy-id
    touch "${INIT_UBUNTU_TEST_SCRATCH}/sshkey.pub"
    run "${REPO_ROOT}/setup_secrets.sh" ssh-key copy alice@example.com \
        --file "${INIT_UBUNTU_TEST_SCRATCH}/sshkey"
    assert_success
    grep -q "^ssh-copy-id -i ${INIT_UBUNTU_TEST_SCRATCH}/sshkey.pub alice@example.com" \
        "${SECRETS_STUB_LOG}"
}

@test "ssh-key copy maps remote failure to exit 7" {
    _stub ssh-copy-id 'exit 1'
    touch "${INIT_UBUNTU_TEST_SCRATCH}/sshkey.pub"
    run "${REPO_ROOT}/setup_secrets.sh" ssh-key copy alice@example.com \
        --file "${INIT_UBUNTU_TEST_SCRATCH}/sshkey"
    assert_failure 7
}
