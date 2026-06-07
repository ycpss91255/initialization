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

_set_dbus() {
    export DBUS_SESSION_BUS_ADDRESS="$1"
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
    _set_dbus "unix:path=/tmp/fake-bus"
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

# ── name validation across the generic API ─────────────────────────────────

@test "secrets_retrieve rejects an invalid name (exit 2)" {
    _load_secrets
    _set_backend encrypted-file
    run secrets_retrieve "../evil"
    assert_failure 2
    assert_output --partial "invalid secret name"
}

@test "secrets_exists rejects an invalid name (exit 2)" {
    _load_secrets
    _set_backend encrypted-file
    run secrets_exists "-leading-dash"
    assert_failure 2
}

@test "secrets_remove rejects an invalid name (exit 2)" {
    _load_secrets
    _set_backend encrypted-file
    run secrets_remove "a/b"
    assert_failure 2
}

@test "secrets_list propagates a backend resolve failure" {
    command -v pass >/dev/null 2>&1 && skip "real pass installed in image"
    _load_secrets
    _set_backend pass
    run secrets_list
    assert_failure 3
}

# ── encrypted-file backend: error paths ─────────────────────────────────────

@test "encrypted-file retrieve of a never-stored name fails before any passphrase use" {
    _load_secrets
    _set_backend encrypted-file
    run secrets_retrieve never-stored
    assert_failure
    assert_output --partial "no stored secret"
}

@test "encrypted-file remove of a never-stored name fails non-zero" {
    _load_secrets
    _set_backend encrypted-file
    run secrets_remove never-stored
    assert_failure
    assert_output --partial "no stored secret"
}

@test "secrets_list on a fresh encrypted-file backend prints nothing" {
    _load_secrets
    _set_backend encrypted-file
    run secrets_list
    assert_success
    assert_output ""
}

@test "empty passphrase file is rejected on store" {
    _load_secrets
    _set_backend encrypted-file
    PASSPHRASE_FILE="${INIT_UBUNTU_TEST_SCRATCH}/pp-empty.txt"
    : > "${PASSPHRASE_FILE}"
    export INIT_UBUNTU_SECRETS_PASSPHRASE_FILE="${PASSPHRASE_FILE}"
    run secrets_store foo <<< "plaintext-x"
    assert_failure
    assert_output --partial "empty"
    [[ ! -e "${INIT_UBUNTU_SECRETS_DIR}/foo.enc" ]]
}

# ── pass backend: list / remove via stub ────────────────────────────────────

@test "pass backend lists stored names from the password store dir" {
    _load_secrets
    _stub pass
    _set_backend pass
    export PASSWORD_STORE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/pstore"
    mkdir -p "${PASSWORD_STORE_DIR}/${SECRETS_PASS_PREFIX}"
    touch "${PASSWORD_STORE_DIR}/${SECRETS_PASS_PREFIX}/api.gpg" \
          "${PASSWORD_STORE_DIR}/${SECRETS_PASS_PREFIX}/gh-token.gpg"
    run secrets_list
    assert_success
    assert_line "api"
    assert_line "gh-token"
}

@test "pass backend list with no store dir prints nothing" {
    _load_secrets
    _stub pass
    _set_backend pass
    export PASSWORD_STORE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/no-such-store"
    run secrets_list
    assert_success
    assert_output ""
}

@test "pass backend remove delegates to pass rm -f under the prefix" {
    _load_secrets
    _stub pass
    _set_backend pass
    run secrets_remove gh-token
    assert_success
    grep -q "^pass rm -f init_ubuntu/gh-token" "${SECRETS_STUB_LOG}"
}

# ── gnome-keyring backend: list / remove via stub ───────────────────────────

@test "gnome-keyring backend list parses secret-tool search output" {
    _load_secrets
    _set_backend gnome-keyring
    _set_dbus "unix:path=/tmp/fake-bus"
    _stub secret-tool "case \"\$1\" in
        search) printf 'attribute.name = alpha\nattribute.name = beta\n' ;;
    esac"
    run secrets_list
    assert_success
    assert_line "alpha"
    assert_line "beta"
}

@test "gnome-keyring backend remove delegates to secret-tool clear" {
    _load_secrets
    _set_backend gnome-keyring
    _set_dbus "unix:path=/tmp/fake-bus"
    _stub secret-tool
    run secrets_remove gh-token
    assert_success
    grep -q "^secret-tool clear service init_ubuntu name gh-token" "${SECRETS_STUB_LOG}"
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

@test "token set rejects a value passed as argv (exit 2)" {
    _set_backend encrypted-file
    _write_passphrase "pp"
    run bash -c "'${REPO_ROOT}/setup_secrets.sh' token set gh-token my-secret-value </dev/null"
    assert_failure 2
    refute_output --partial "my-secret-value stored"
}

@test "token get for a missing name fails without leaking anything" {
    _set_backend encrypted-file
    _write_passphrase "pp"
    run --separate-stderr "${REPO_ROOT}/setup_secrets.sh" token get no-such-token
    assert_failure
    assert_output ""
}

@test "token round-trips through a mocked pass backend via CLI" {
    _set_backend pass
    export SECRETS_FAKE_PASS_DB="${INIT_UBUNTU_TEST_SCRATCH}/fake-pass-db"
    _stub pass "case \"\$1\" in
        insert) cat > \"\${SECRETS_FAKE_PASS_DB:?}\" ;;
        show)   cat \"\${SECRETS_FAKE_PASS_DB:?}\" ;;
    esac"
    run bash -c "printf '%s' 'pass-tok-77' | '${REPO_ROOT}/setup_secrets.sh' token set gh-token"
    assert_success
    run --separate-stderr "${REPO_ROOT}/setup_secrets.sh" token get gh-token
    assert_success
    assert_output "pass-tok-77"
    # the secret value must never ride argv into the pass binary
    run ! grep -q 'pass-tok-77' "${SECRETS_STUB_LOG}"
}

@test "token round-trips through a mocked gnome-keyring backend via CLI" {
    _set_backend gnome-keyring
    _set_dbus "unix:path=/tmp/fake-bus"
    export SECRETS_FAKE_KEYRING="${INIT_UBUNTU_TEST_SCRATCH}/fake-keyring"
    _stub secret-tool "case \"\$1\" in
        store)  cat > \"\${SECRETS_FAKE_KEYRING:?}\" ;;
        lookup) cat \"\${SECRETS_FAKE_KEYRING:?}\" ;;
    esac"
    run bash -c "printf '%s' 'gkr-tok-42' | '${REPO_ROOT}/setup_secrets.sh' token set gh-token"
    assert_success
    run --separate-stderr "${REPO_ROOT}/setup_secrets.sh" token get gh-token
    assert_success
    assert_output "gkr-tok-42"
    run ! grep -q 'gkr-tok-42' "${SECRETS_STUB_LOG}"
}

# ── list / remove (issue #68) ───────────────────────────────────────────────

@test "list prints stored names only — never values" {
    _set_backend encrypted-file
    _write_passphrase "pp"
    printf '%s' 'value-A-canary' | "${REPO_ROOT}/setup_secrets.sh" token set alpha
    printf '%s' 'value-B-canary' | "${REPO_ROOT}/setup_secrets.sh" token set beta
    run --separate-stderr "${REPO_ROOT}/setup_secrets.sh" list
    assert_success
    assert_line "alpha"
    assert_line "beta"
    refute_output --partial 'value-A-canary'
    refute_output --partial 'value-B-canary'
}

@test "remove deletes the named secret from the active backend" {
    _set_backend encrypted-file
    _write_passphrase "pp"
    printf '%s' 'v1' | "${REPO_ROOT}/setup_secrets.sh" token set doomed
    [[ -f "${INIT_UBUNTU_SECRETS_DIR}/doomed.enc" ]]
    run "${REPO_ROOT}/setup_secrets.sh" remove doomed
    assert_success
    [[ ! -e "${INIT_UBUNTU_SECRETS_DIR}/doomed.enc" ]]
    run --separate-stderr "${REPO_ROOT}/setup_secrets.sh" list
    assert_success
    refute_output --partial "doomed"
}

@test "remove without a name exits 2" {
    run "${REPO_ROOT}/setup_secrets.sh" remove
    assert_failure 2
}

@test "remove of a missing name fails non-zero" {
    _set_backend encrypted-file
    _write_passphrase "pp"
    run "${REPO_ROOT}/setup_secrets.sh" remove never-stored
    assert_failure
}

# ── gpg generate / import (issue #68) ───────────────────────────────────────

@test "gpg generate delegates to gpg --full-generate-key with a clean argv" {
    _stub gpg
    run "${REPO_ROOT}/setup_secrets.sh" gpg generate
    assert_success
    grep -q -- '^gpg --full-generate-key' "${SECRETS_STUB_LOG}"
    # all prompts (incl. passphrase) belong to gpg's own tty — nothing
    # passphrase-like may ever pass through our argv (AC-20)
    run ! grep -qE -- '--passphrase|--pinentry' "${SECRETS_STUB_LOG}"
}

@test "gpg import imports key material from a file" {
    _stub gpg
    printf '%s\n' 'FAKE KEY BLOCK' > "${INIT_UBUNTU_TEST_SCRATCH}/key.asc"
    run "${REPO_ROOT}/setup_secrets.sh" gpg import "${INIT_UBUNTU_TEST_SCRATCH}/key.asc"
    assert_success
    grep -q -- "^gpg --import ${INIT_UBUNTU_TEST_SCRATCH}/key.asc" "${SECRETS_STUB_LOG}"
}

@test "gpg import reads key material from stdin when no file is given" {
    export SECRETS_FAKE_GPG_IN="${INIT_UBUNTU_TEST_SCRATCH}/gpg-stdin"
    _stub gpg "cat > \"\${SECRETS_FAKE_GPG_IN:?}\""
    run bash -c "printf '%s' 'STDIN KEY BLOCK' | '${REPO_ROOT}/setup_secrets.sh' gpg import"
    assert_success
    grep -q -- '^gpg --import$' "${SECRETS_STUB_LOG}"
    [[ "$(cat "${SECRETS_FAKE_GPG_IN}")" == "STDIN KEY BLOCK" ]]
}

@test "gpg import with a missing file exits 1 without calling gpg" {
    _stub gpg
    run "${REPO_ROOT}/setup_secrets.sh" gpg import "${INIT_UBUNTU_TEST_SCRATCH}/nope.asc"
    assert_failure 1
    run ! grep -q '^gpg' "${SECRETS_STUB_LOG}"
}

@test "gpg unknown action exits 2" {
    _stub gpg
    run "${REPO_ROOT}/setup_secrets.sh" gpg frobnicate
    assert_failure 2
}

# ── ssh-key generate: argv hygiene (AC-20) ──────────────────────────────────

@test "ssh-key generate calls ssh-keygen without any passphrase in argv" {
    _stub ssh-keygen
    run "${REPO_ROOT}/setup_secrets.sh" ssh-key generate \
        --file "${INIT_UBUNTU_TEST_SCRATCH}/sshkey" --comment test@host
    assert_success
    # Exact whole-argv assertion (AC-20): passphrase prompting is delegated
    # to ssh-keygen's own tty prompt, so the recorded argv must be exactly
    # -t/-f/-C and nothing else — no -N, no passphrase, no extra flags.
    #
    # Deliberately NOT a substring `grep -- '-N'` absence check: the -f path
    # lives under bats' mktemp run dir (bats-run-XXXXXX), and whenever the
    # random suffix starts with "N" the path itself contains "-N", which
    # made the old assertion flake (~1/62 runs).
    grep -qxF \
        "ssh-keygen -t ed25519 -f ${INIT_UBUNTU_TEST_SCRATCH}/sshkey -C test@host" \
        "${SECRETS_STUB_LOG}"
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
