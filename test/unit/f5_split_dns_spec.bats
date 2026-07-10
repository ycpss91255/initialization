#!/usr/bin/env bats
# test/unit/f5_split_dns_spec.bats
#
# Tests for tool/f5-split-dns/f5-split-dns.sh (issue #146): the small script
# that pins the company DNS + a routing domain onto the F5 VPN interface
# (tun0) via resolvectl, driven by f5-split-dns.service.
#
# Strategy: the script shells out to `resolvectl`, `ip`, `logger` and `sleep`.
# All four are stubbed on PATH so the real system is never touched (ADR-0004:
# no host mutation). The resolvectl/logger stubs record their argv to files so
# we can assert on exactly what the script asked systemd-resolved to do.
#
#   STUB_IP_FAIL=1         -> `ip link show` fails (interface never appears)
#   STUB_RESOLVECTL_FAIL=1 -> `resolvectl` returns non-zero (not registered yet)
#   F5_TEST_RECORD=<dir>   -> stubs append their argv under this dir

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env

    SCRIPT="${REPO_ROOT}/tool/f5-split-dns/f5-split-dns.sh"

    STUB_BIN="${INIT_UBUNTU_TEST_SCRATCH}/bin"
    REC="${INIT_UBUNTU_TEST_SCRATCH}/rec"
    mkdir -p "${STUB_BIN}" "${REC}"

    # Quoted heredocs: the stub bodies are literal shell, written verbatim.
    cat > "${STUB_BIN}/ip" <<'SH'
#!/bin/sh
[ "${STUB_IP_FAIL:-0}" = 1 ] && exit 1
exit 0
SH
    cat > "${STUB_BIN}/resolvectl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$F5_TEST_RECORD/resolvectl"
[ "${STUB_RESOLVECTL_FAIL:-0}" = 1 ] && exit 1
exit 0
SH
    cat > "${STUB_BIN}/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$F5_TEST_RECORD/logger"
exit 0
SH
    cat > "${STUB_BIN}/sleep" <<'SH'
#!/bin/sh
exit 0
SH
    chmod +x "${STUB_BIN}"/ip "${STUB_BIN}"/resolvectl \
             "${STUB_BIN}"/logger "${STUB_BIN}"/sleep

    # NB: not ".../config" — setup_test_env already creates a config *dir* there.
    CONF="${INIT_UBUNTU_TEST_SCRATCH}/f5.conf"
}

teardown() {
    teardown_test_env
}

# Run the script (no interface arg -> defaults to tun0) with the stub bin on
# PATH and the recorder wired up.
_run_script() {
    run env PATH="${STUB_BIN}:${PATH}" \
        F5_SPLIT_DNS_CONF="${CONF}" \
        F5_TEST_RECORD="${REC}" \
        bash "${SCRIPT}"
}

# ── Config plumbing / guardrails ─────────────────────────────────────────────

@test "exits non-zero when F5_SPLIT_DNS_CONF is unset" {
    run env -u F5_SPLIT_DNS_CONF PATH="${STUB_BIN}:${PATH}" \
        bash "${SCRIPT}" tun0
    assert_failure
}

@test "no-op (exit 0) and logs when the config file is not readable" {
    # CONF points at a path that does not exist.
    _run_script
    assert_success
    run grep -F "config not readable" "${REC}/logger"
    assert_success
    # It must NOT have touched resolvectl.
    assert [ ! -f "${REC}/resolvectl" ]
}

@test "errors when INTERNAL_DNS_IP is missing from the config" {
    printf 'COMPANY_DOMAIN="corp.example"\n' > "${CONF}"
    _run_script
    assert_failure
}

@test "errors when COMPANY_DOMAIN is missing from the config" {
    printf 'INTERNAL_DNS_IP="10.0.0.53"\n' > "${CONF}"
    _run_script
    assert_failure
}

# ── Happy path ───────────────────────────────────────────────────────────────

@test "applies the company DNS and the ~routing domain on tun0" {
    printf 'INTERNAL_DNS_IP="10.0.0.53"\nCOMPANY_DOMAIN="corp.example"\n' \
        > "${CONF}"
    _run_script
    assert_success

    run grep -Fx "dns tun0 10.0.0.53" "${REC}/resolvectl"
    assert_success
    # The routing domain MUST carry the leading '~' so systemd-resolved treats
    # it as a routing-only domain for the link.
    run grep -Fx "domain tun0 ~corp.example" "${REC}/resolvectl"
    assert_success
}

@test "logs an applied message on success" {
    printf 'INTERNAL_DNS_IP="10.0.0.53"\nCOMPANY_DOMAIN="corp.example"\n' \
        > "${CONF}"
    _run_script
    assert_success
    run grep -F "applied split-DNS on tun0" "${REC}/logger"
    assert_success
}

@test "defaults the interface to tun0 when no argument is given" {
    printf 'INTERNAL_DNS_IP="10.0.0.53"\nCOMPANY_DOMAIN="corp.example"\n' \
        > "${CONF}"
    _run_script
    assert_success
    run grep -F "dns tun0 " "${REC}/resolvectl"
    assert_success
}

@test "honors an explicit interface argument" {
    printf 'INTERNAL_DNS_IP="10.0.0.53"\nCOMPANY_DOMAIN="corp.example"\n' \
        > "${CONF}"
    run env PATH="${STUB_BIN}:${PATH}" \
        F5_SPLIT_DNS_CONF="${CONF}" \
        F5_TEST_RECORD="${REC}" \
        bash "${SCRIPT}" tun9
    assert_success
    run grep -F "dns tun9 " "${REC}/resolvectl"
    assert_success
}

# ── Lifecycle / resilience ───────────────────────────────────────────────────

@test "exits 0 gracefully and logs a timeout when the interface never appears" {
    printf 'INTERNAL_DNS_IP="10.0.0.53"\nCOMPANY_DOMAIN="corp.example"\n' \
        > "${CONF}"
    run env PATH="${STUB_BIN}:${PATH}" \
        F5_SPLIT_DNS_CONF="${CONF}" \
        F5_TEST_RECORD="${REC}" \
        STUB_IP_FAIL=1 \
        bash "${SCRIPT}" tun0
    assert_success
    run grep -F "not ready within timeout" "${REC}/logger"
    assert_success
    # Never reached resolvectl because the link was never up.
    assert [ ! -f "${REC}/resolvectl" ]
}
