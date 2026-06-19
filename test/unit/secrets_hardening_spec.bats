#!/usr/bin/env bats
# test/unit/secrets_hardening_spec.bats — non-functional hardening for the
# secrets sub-tool (audit #178 mediums; AC-20 spirit).
#
# This file complements (does NOT duplicate) test/unit/secrets_spec.bats.
# secrets_spec.bats already pins the happy-path argv hygiene for a few
# binaries (ssh-keygen / openssl / pass / gnome-keyring / gpg) plus a couple
# of name-validation cases. Here we harden the SECURITY posture across the
# whole surface:
#
#   1. Leak hygiene — no secret/passphrase material lands anywhere a shell
#      `ps`, history, or a readable file could expose it. Asserted for the
#      openssl dispatch path (argv + env) and for the passphrase-file source.
#   2. Input validation / injection — secret names and backend names that
#      carry shell metacharacters, command substitution, path traversal,
#      globs, or whitespace are all rejected BEFORE any backend command runs.
#   3. Error messages — failures (wrong passphrase, missing secret, absent
#      backend) never echo the secret value or the passphrase back to the
#      caller.
#   4. Backend-absent safety — when pass / gpg / secret-tool are missing the
#      tool exits non-zero with guidance and never crashes / half-writes.
#
# All external binaries are stubbed via PATH override (same style as
# secrets_spec.bats). No real keys, no real backends.
#
# Note on env hygiene: per-test state (chosen backend / passphrase file) is
# set through the _set_*/_write_passphrase helpers and consumed inside the
# SAME @test body, so no cross-subshell variable reuse (no SC2030/SC2031
# disable directive is needed here, unlike secrets_spec.bats).

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

    export SECRETS_STUB_DIR="${INIT_UBUNTU_TEST_SCRATCH}/stubs"
    export SECRETS_STUB_LOG="${INIT_UBUNTU_TEST_SCRATCH}/stub-calls.log"
    mkdir -p "${SECRETS_STUB_DIR}"
    : > "${SECRETS_STUB_LOG}"
    export PATH="${SECRETS_STUB_DIR}:${PATH}"

    # A literal dollar sign + backtick, assembled at runtime so injection
    # payloads can be built as DATA without shellcheck flagging source-level
    # command substitution (SC2016) that we never intend to expand.
    _DOLLAR='$'
    _BACKTICK='`'
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

# _stub <name> [body...] — executable stub on the stub PATH that records its
# WHOLE argv (and, when given a body, its stdin) for later leak assertions.
_stub() {
    local _name="$1"; shift
    {
        printf '#!/usr/bin/env bash\n'
        printf 'echo "%s $*" >> "%s"\n' "${_name}" "${SECRETS_STUB_LOG}"
        if (( $# > 0 )); then printf '%s\n' "$@"; else printf 'exit 0\n'; fi
    } > "${SECRETS_STUB_DIR}/${_name}"
    chmod +x "${SECRETS_STUB_DIR}/${_name}"
}

# Drop a stub that ALSO records the full process environment, so we can prove
# the only place the passphrase travels is the documented `-pass env:` slot
# (an explicitly-named var) and never argv.
_stub_record_env() {
    local _name="$1"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'echo "%s $*" >> "%s"\n' "${_name}" "${SECRETS_STUB_LOG}"
        printf 'env >> "%s.env"\n' "${SECRETS_STUB_LOG}"
        printf 'cat > /dev/null\n'
    } > "${SECRETS_STUB_DIR}/${_name}"
    chmod +x "${SECRETS_STUB_DIR}/${_name}"
}

_write_passphrase() {
    local _pp_file="${INIT_UBUNTU_TEST_SCRATCH}/pp.txt"
    printf '%s\n' "$1" > "${_pp_file}"
    export INIT_UBUNTU_SECRETS_PASSPHRASE_FILE="${_pp_file}"
}

_set_backend() {
    export INIT_UBUNTU_SECRETS_BACKEND="$1"
}

_set_dbus() {
    export DBUS_SESSION_BUS_ADDRESS="$1"
}

# ── 1. Leak hygiene: passphrase never reaches argv on any openssl call ───────

@test "encrypted-file store: passphrase reaches openssl via env only, never argv" {
    _load_secrets
    _set_backend encrypted-file
    _write_passphrase "env-only-canary-PP"
    _stub_record_env openssl
    printf '%s' 'plaintext' | secrets_store envcheck
    # openssl was invoked and the documented -pass env: slot was used …
    grep -q '^openssl ' "${SECRETS_STUB_LOG}"
    grep -q -- '-pass env:INIT_UBUNTU_SECRETS_PASS' "${SECRETS_STUB_LOG}"
    # … the passphrase VALUE never appears in argv …
    run ! grep -q 'env-only-canary-PP' "${SECRETS_STUB_LOG}"
    # … and it travels only through the one explicitly-named env var.
    run grep -c 'env-only-canary-PP' "${SECRETS_STUB_LOG}.env"
    assert_output "1"
    grep -q '^INIT_UBUNTU_SECRETS_PASS=env-only-canary-PP$' "${SECRETS_STUB_LOG}.env"
}

@test "encrypted-file retrieve: passphrase reaches openssl via env only, never argv" {
    _load_secrets
    _set_backend encrypted-file
    _write_passphrase "retrieve-canary-PP"
    # store for real first (need a valid ciphertext file on disk)
    printf '%s' 'payload' | secrets_store rt
    : > "${SECRETS_STUB_LOG}"
    _stub_record_env openssl
    run secrets_retrieve rt
    grep -q -- '-pass env:INIT_UBUNTU_SECRETS_PASS' "${SECRETS_STUB_LOG}"
    run ! grep -q 'retrieve-canary-PP' "${SECRETS_STUB_LOG}"
}

@test "passphrase file content never echoes onto stdout/stderr on store" {
    _set_backend encrypted-file
    _write_passphrase "file-pp-must-stay-hidden"
    # combined stdout+stderr (no --separate-stderr): the passphrase must not
    # surface on either stream.
    run bash -c \
        "printf '%s' v | '${REPO_ROOT}/setup_secrets.sh' token set hidearg 2>&1"
    assert_success
    refute_output --partial "file-pp-must-stay-hidden"
}

# ── 1b. Leak hygiene: stored plaintext never on disk in the clear ────────────

@test "encrypted-file: plaintext is not recoverable from the .enc artifact by grep" {
    _load_secrets
    _set_backend encrypted-file
    _write_passphrase "pp"
    printf '%s' 'NEEDLE-PLAINTEXT-9ab' | secrets_store needle
    [[ -f "${INIT_UBUNTU_SECRETS_DIR}/needle.enc" ]]
    run ! grep -aFq 'NEEDLE-PLAINTEXT-9ab' "${INIT_UBUNTU_SECRETS_DIR}/needle.enc"
}

@test "encrypted-file: no leftover .tmp file after a successful store" {
    _load_secrets
    _set_backend encrypted-file
    _write_passphrase "pp"
    printf '%s' 'x' | secrets_store cleanstore
    run bash -c "ls -A '${INIT_UBUNTU_SECRETS_DIR}'/.*.tmp.* 2>/dev/null | wc -l"
    assert_output "0"
}

@test "encrypted-file: a failed encryption leaves no plaintext temp behind" {
    _load_secrets
    _set_backend encrypted-file
    _write_passphrase "pp"
    # openssl that fails AFTER receiving stdin — store must clean its temp up
    _stub openssl 'cat > /dev/null; exit 1'
    run bash -c "printf '%s' 'TEMP-LEAK-CANARY' | { source '${LIB_DIR}/logger.sh';
        source '${LIB_DIR}/config.sh'; source '${LIB_DIR}/secrets.sh';
        secrets_store failclean; }"
    assert_failure
    # no temp file, and certainly no greppable plaintext under the secrets dir
    run bash -c "ls -A '${INIT_UBUNTU_SECRETS_DIR}'/.*.tmp.* 2>/dev/null | wc -l"
    assert_output "0"
    run ! grep -RaFq 'TEMP-LEAK-CANARY' "${INIT_UBUNTU_SECRETS_DIR}"
}

# ── 2. Input validation / injection on SECRET NAMES ──────────────────────────
# The regex gate is ^[A-Za-z0-9][A-Za-z0-9._@-]*$ — everything below must be
# rejected with exit 2 BEFORE any backend command is reached. We assert both
# the rejection AND that no backend binary was ever invoked.

@test "secret name with a command-substitution payload is rejected (exit 2)" {
    _load_secrets
    _set_backend pass
    _stub pass
    # Build the payload at runtime so the literal $(...) never sits in source
    # (it is data, not shell to expand): concat a dollar-paren around a body.
    local _evil="name${_DOLLAR}(touch /tmp/pwn)"
    run secrets_retrieve "${_evil}"
    assert_failure 2
    assert_output --partial "invalid secret name"
    run ! grep -q '^pass' "${SECRETS_STUB_LOG}"
}

@test "secret name with a shell metacharacter (semicolon) is rejected (exit 2)" {
    _load_secrets
    _set_backend pass
    _stub pass
    run secrets_retrieve 'gh;rm -rf'
    assert_failure 2
    run ! grep -q '^pass' "${SECRETS_STUB_LOG}"
}

@test "secret name with backticks is rejected (exit 2)" {
    _load_secrets
    _set_backend encrypted-file
    local _evil="tok${_BACKTICK}id${_BACKTICK}"
    run secrets_retrieve "${_evil}"
    assert_failure 2
    assert_output --partial "invalid secret name"
}

@test "secret name with a pipe character is rejected (exit 2)" {
    _load_secrets
    _set_backend encrypted-file
    run secrets_retrieve 'a|b'
    assert_failure 2
}

@test "secret name with a glob/wildcard is rejected (exit 2)" {
    _load_secrets
    _set_backend encrypted-file
    run secrets_retrieve '*'
    assert_failure 2
}

@test "secret name with embedded whitespace is rejected (exit 2)" {
    _load_secrets
    _set_backend encrypted-file
    run secrets_retrieve 'two words'
    assert_failure 2
}

@test "secret name with an absolute path is rejected (exit 2)" {
    _load_secrets
    _set_backend encrypted-file
    run secrets_retrieve '/etc/passwd'
    assert_failure 2
}

@test "empty secret name is rejected (exit 2)" {
    _load_secrets
    _set_backend encrypted-file
    run secrets_store ''
    assert_failure 2
}

@test "store rejects a traversal name before touching the backend" {
    _load_secrets
    _set_backend pass
    _stub pass
    run bash -c "printf x | { source '${LIB_DIR}/logger.sh';
        source '${LIB_DIR}/config.sh'; source '${LIB_DIR}/secrets.sh';
        secrets_store '../../etc/cron.d/evil'; }"
    assert_failure 2
    run ! grep -q '^pass' "${SECRETS_STUB_LOG}"
}

@test "a valid dotted/at-sign name is accepted (boundary positive case)" {
    _load_secrets
    _set_backend encrypted-file
    _write_passphrase "pp"
    printf '%s' 'v' | secrets_store 'user@host.tld_token-1'
    run secrets_exists 'user@host.tld_token-1'
    assert_success
}

# ── 2b. Input validation on the BACKEND name ─────────────────────────────────

@test "backend name with an injection payload is rejected (exit 2), no dispatch" {
    _load_secrets
    _set_backend 'pass; rm -rf /'
    _stub pass
    run secrets_backend_resolve
    assert_failure 2
    assert_output --partial "unknown secrets backend"
    run ! grep -q '^pass' "${SECRETS_STUB_LOG}"
}

@test "backend name with a path-traversal payload is rejected (exit 2)" {
    _load_secrets
    _set_backend '../../bin/evil'
    run secrets_backend_resolve
    assert_failure 2
}

@test "unknown backend is treated as data, not a function-name fragment" {
    # Regression guard: the resolver must treat an unknown backend as DATA,
    # not as a function-name fragment to call.
    _load_secrets
    _set_backend 'bogus_backend_x'
    run secrets_store anyname <<< "v"
    assert_failure 2
    assert_output --partial "unknown secrets backend"
}

# ── 3. Error messages never echo secret material ─────────────────────────────

@test "wrong-passphrase decrypt error names neither the plaintext nor the passphrase" {
    _load_secrets
    _set_backend encrypted-file
    _write_passphrase "RIGHT-PASS-aaa"
    printf '%s' 'TOP-SECRET-zzz' | secrets_store locked2
    _write_passphrase "WRONG-PASS-bbb"
    run secrets_retrieve locked2
    assert_failure
    refute_output --partial 'TOP-SECRET-zzz'
    refute_output --partial 'RIGHT-PASS-aaa'
    refute_output --partial 'WRONG-PASS-bbb'
    assert_output --partial "decryption failed"
}

@test "token get of a missing name emits no value on stdout (pipe-safe)" {
    _set_backend encrypted-file
    _write_passphrase "pp"
    # stdout must be empty (no value); the diagnostic goes to stderr.
    run --separate-stderr "${REPO_ROOT}/setup_secrets.sh" token get ghost
    assert_failure
    assert_output ""
    # Separately capture stderr to confirm the diagnostic names only the KEY.
    run bash -c "'${REPO_ROOT}/setup_secrets.sh' token get ghost 2>&1 1>/dev/null"
    assert_output --partial "ghost"
}

@test "missing-secret remove error names only the key, never any value" {
    _set_backend encrypted-file
    _write_passphrase "pp"
    run bash -c "'${REPO_ROOT}/setup_secrets.sh' remove ghostkey 2>&1"
    assert_failure
    assert_output --partial "ghostkey"
    assert_output --partial "no stored secret"
}

# ── 4. Backend-absent safety ─────────────────────────────────────────────────

@test "explicit pass backend absent: clean exit 3 with guidance, no crash" {
    command -v pass >/dev/null 2>&1 && skip "real pass installed in image"
    _load_secrets
    _set_backend pass
    run secrets_backend_resolve
    assert_failure 3
    assert_output --partial "not available"
}

@test "no backend at all available: resolve fails 3 and lists the options" {
    command -v pass >/dev/null 2>&1 && skip "real pass installed in image"
    command -v secret-tool >/dev/null 2>&1 && skip "real secret-tool installed in image"
    command -v openssl >/dev/null 2>&1 && skip "real openssl installed in image"
    _load_secrets
    run secrets_backend_resolve
    assert_failure 3
    assert_output --partial "no secrets backend available"
}

@test "gpg generate when gpg is absent exits 3 with an install hint" {
    command -v gpg >/dev/null 2>&1 && skip "real gpg installed in image"
    run "${REPO_ROOT}/setup_secrets.sh" gpg generate
    assert_failure 3
    assert_output --partial "gpg is not installed"
}

@test "gpg import when gpg is absent exits 3 before reading any file" {
    command -v gpg >/dev/null 2>&1 && skip "real gpg installed in image"
    printf '%s\n' 'KEY' > "${INIT_UBUNTU_TEST_SCRATCH}/k.asc"
    run "${REPO_ROOT}/setup_secrets.sh" gpg import "${INIT_UBUNTU_TEST_SCRATCH}/k.asc"
    assert_failure 3
    assert_output --partial "gpg is not installed"
}

@test "store against an absent explicit backend never half-writes a file" {
    command -v pass >/dev/null 2>&1 && skip "real pass installed in image"
    _load_secrets
    _set_backend pass
    run bash -c "printf '%s' 'HALF-WRITE-CANARY' | { source '${LIB_DIR}/logger.sh';
        source '${LIB_DIR}/config.sh'; source '${LIB_DIR}/secrets.sh';
        secrets_store wouldbe; }"
    assert_failure 3
    [[ ! -e "${INIT_UBUNTU_SECRETS_DIR}/wouldbe.enc" ]]
    run ! grep -RaFq 'HALF-WRITE-CANARY' "${INIT_UBUNTU_TEST_SCRATCH}/config"
}

# ── 5. ssh-key passphrase handling: never via argv ───────────────────────────

@test "ssh-key generate (default) never puts -N or a passphrase on ssh-keygen argv" {
    _stub ssh-keygen
    run "${REPO_ROOT}/setup_secrets.sh" ssh-key generate \
        --file "${INIT_UBUNTU_TEST_SCRATCH}/hk" --comment c@h
    assert_success
    # whole-argv exact match: only -t/-f/-C, delegating the passphrase prompt
    # to ssh-keygen's own tty (AC-20). Exact-match avoids the -f-path-contains-N
    # flake documented in secrets_spec.bats.
    grep -qxF \
        "ssh-keygen -t ed25519 -f ${INIT_UBUNTU_TEST_SCRATCH}/hk -C c@h" \
        "${SECRETS_STUB_LOG}"
}

@test "token set value passed positionally is refused — stdin is the only channel" {
    # Proving the contract surface: a value passed positionally is refused,
    # so the secret can only travel via stdin (never argv → never `ps`/history).
    _set_backend encrypted-file
    _write_passphrase "pp"
    run bash -c "'${REPO_ROOT}/setup_secrets.sh' token set k VALUE-ON-ARGV </dev/null"
    assert_failure 2
    [[ ! -f "${INIT_UBUNTU_SECRETS_DIR}/k.enc" ]]
}
