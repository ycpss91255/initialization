#!/usr/bin/env bats
# test/unit/modules/<NAME>_spec.bats — bats spec for module/<NAME>.module.sh
#
# Quick start:
#   1. cp template/test.template.bats test/unit/modules/<your-name>_spec.bats
#   2. Replace every <MODULE-NAME> below with your module name (no quotes).
#   3. Search for <TODO> markers and fill them in.
#   4. Run: make test-unit
#
# What this template covers (the docs/module-spec.md §7 minimum):
#   - Metadata sanity (NAME / CATEGORY match)
#   - is_installed reports the right state under stub conditions
#   - install / remove / purge are no-ops in --dry-run mode
#   - install short-circuits when is_installed is already true (idempotency)
#   - is_recommended logic is sensible
#
# Use bats-mock when you need to intercept apt-get / curl / sudo. Real
# system-changing calls should never happen inside a unit test.

load "${BATS_TEST_DIRNAME}/../../helpers/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
}

teardown() {
    teardown_test_env
}

_load_module() {
    # shellcheck disable=SC1091
    source "${LIB_DIR}/logger.sh"
    # shellcheck disable=SC1091
    source "${LIB_DIR}/general.sh"
    # shellcheck disable=SC1091
    source "${MODULE_DIR}/<MODULE-NAME>.module.sh"
}

# ── Metadata sanity ──────────────────────────────────────────────────────────

@test "<MODULE-NAME> module declares NAME=<MODULE-NAME>" {
    _load_module
    [[ "${NAME}" == "<MODULE-NAME>" ]]
}

@test "<MODULE-NAME> module CATEGORY is one of base|recommended|optional|experimental" {
    _load_module
    case "${CATEGORY}" in
        base|recommended|optional|experimental) :;;
        *) printf "unexpected CATEGORY=%s\n" "${CATEGORY}" >&2; return 1 ;;
    esac
}

# ── is_installed: starts false on a clean container ─────────────────────────

@test "is_installed returns nonzero on a fresh test container" {
    _load_module
    run is_installed
    assert_failure
}

# ── Dry-run no-ops ───────────────────────────────────────────────────────────

@test "install in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "remove in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run remove
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "purge in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run purge
    assert_success
    assert_output --partial "DRY-RUN"
}

# ── Idempotency: install short-circuits when already installed ──────────────

@test "install short-circuits when is_installed returns 0 (idempotency)" {
    _load_module
    is_installed() { return 0; }
    run install
    assert_success
    # docs/module-spec.md §4.2 lets install() either skip or re-install;
    # most modules log a "already installed" hint we can grep for.
    assert_output --partial "already installed"
}

# ── is_recommended sanity ────────────────────────────────────────────────────

@test "is_recommended is nonzero when already installed" {
    _load_module
    is_installed() { return 0; }
    run is_recommended
    assert_failure
}

# ── TODO: module-specific behavior ───────────────────────────────────────────
# Add tests for:
#   - Each branch of detect / is_recommended that depends on environment
#     (use bats-mock to stub systemd-detect-virt / lspci / dmidecode etc.)
#   - Each platform variant if your install() branches on SUPPORTED_PLATFORMS
#   - Specific config files dropped under ~/.config/<name>/ on install
#   - purge() actually wiping the config dir
