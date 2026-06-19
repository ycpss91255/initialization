#!/usr/bin/env bats
# test/integration/state/export_import_spec.bats
#
# AC-14 (stream S3): export → wipe → import --apply REAL reinstall, with MIXED
# archetypes, through the REAL engine — not a dry-run plan and not the unit
# _load_engine harness.
#
# The keystone gap (#178 / #174): every prior export/import test stopped at the
# dry-run DIFF (state_io_import_plan) or at a unit-level state.json merge. None
# drove `import --apply` all the way back through the dispatcher →
# _dispatcher_lifecycle install → runner → source module → archetype macro →
# lifecycle fn, so a broken engine wiring (the #174 class) would pass the
# import-plan tests untouched. This spec closes that for the export/import
# round-trip by covering two DIFFERENT archetypes at once:
#
#   github-release : gum        (network boundary stubbed via the #175 seam)
#   config         : ssh-config (no network; drops a managed file)
#
# Flow (AC-14):
#   1. real install gum + ssh-config as a NON-ROOT user (install refuses EUID 0)
#   2. setup_ubuntu export A.json            — synced sections round-trip out
#   3. wipe local state + payloads           — simulate a fresh machine
#   4. setup_ubuntu import A.json --apply     — REAL reinstall via the engine
#   5. assert BOTH modules are REALLY back:
#        - state.json round-trips (installed[gum], installed[ssh-config])
#        - the github-release binary is on disk + the Sidecar is rewritten
#        - the config archetype's managed file is dropped again
#
# Determinism: ONLY the github-release fetch is stubbed (INIT_UBUNTU_TEST_GH_*
# offline seams in lib/module_helper.sh). Everything else — gzip sniff, tar
# extract, symlink, state.json read/write, the config file drop, the import
# conflict pipeline (ADR-0013) — runs for real. No network, no sudo (every
# install target is user-home scratch).
#
# This file owns its scratch wiring via the SHARED, READ-ONLY #175 harness
# (test/helper/engine_lifecycle.bash); it does not modify the helper or lib/.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/engine_lifecycle"

# gum (charmbracelet/gum): the user-home, sudo-free github-release module.
# Asset pattern is gum_<ver>_Linux_<arch> (STRIP_COMPONENTS=1), matching the
# real upstream tarball layout the harness fixture mirrors.
_GUM_V="0.16.2"

_gum_arch() {
    case "$(uname -m)" in
        x86_64)        printf 'x86_64' ;;
        aarch64|arm64) printf 'arm64' ;;
        armv7l)        printf 'armv7' ;;
        *)             printf 'x86_64' ;;
    esac
}

_gum_asset() { printf 'gum_%s_Linux_%s.tar.gz' "${1}" "$(_gum_arch)"; }

# The github-release fetch seam for every engine call that touches gum
# (install during step 1 AND the reinstall during import --apply).
_gh_env() {
    printf 'INIT_UBUNTU_TEST_GH_VERSION=%s INIT_UBUNTU_TEST_GH_FIXTURE_DIR=%s' \
        "${_GUM_V}" "${ENGINE_LT_FIXTURE}"
}

# The exported payload lives in the non-root user's scratch HOME so the same
# user can read it back during import.
_payload() { printf '%s/export_A.json' "${ENGINE_LT_HOME}"; }

setup() {
    engine_lt_require_root
    setup_test_env
    engine_lt_setup_user
}

teardown() {
    teardown_test_env
}

# ── helpers local to this spec ───────────────────────────────────────────────

# _install_mixed — real install of the two mixed-archetype modules as the
# non-root user. Asserts both landed (no #174 wiring errors, state recorded).
_install_mixed() {
    engine_lt_make_gh_fixture "$(_gum_asset "${_GUM_V}")" gum "${_GUM_V}"

    engine_lt_run "$(_gh_env)" install gum --no-deps -y
    assert_success
    engine_lt_assert_no_wiring_errors
    assert_output --partial "gum installed"

    engine_lt_run "" install ssh-config --no-deps -y
    assert_success
    engine_lt_assert_no_wiring_errors
    assert_output --partial "ssh-config installed"
}

# _wipe_state — simulate a fresh machine: drop the whole state dir (state.json
# + Sidecars) and the on-disk install artifacts, so import sees BOTH modules as
# absent-locally → action=install (real reinstall), not noop.
_wipe_state() {
    rm -rf "${ENGINE_LT_STATE:?}"
    mkdir -p "${ENGINE_LT_STATE}"
    rm -f "${ENGINE_LT_HOME}/.local/bin/gum"
    rm -f "${ENGINE_LT_HOME}/.ssh/config"
    chown -R "${ENGINE_LT_USER}:${ENGINE_LT_USER}" "${ENGINE_LT_STATE}" "${ENGINE_LT_HOME}"
}

# ── visibility / sanity ──────────────────────────────────────────────────────

@test "export-import harness runs (records #178 / AC-14 matrix target)" {
    echo "# matrix target: ${INIT_UBUNTU_TEST_IMAGE:-<unset; local run>}" >&3
    [[ -x "${REPO_ROOT}/setup_ubuntu.sh" ]]
}

# ── AC-14: export → wipe → import --apply, MIXED archetypes, real reinstall ──

@test "AC-14: export captures both mixed archetypes' synced sections" {
    _install_mixed

    engine_lt_run "" export "$(_payload)"
    assert_success
    assert_output --partial "state exported"

    # The payload is real JSON the receiver can read, and carries BOTH modules
    # (github-release + config) — the mixed-archetype round-trip surface.
    run su "${ENGINE_LT_USER}" -c \
        "jq -r '.modules[].name' '$(_payload)' | sort | tr '\n' ' '"
    assert_success
    assert_output --partial "gum"
    assert_output --partial "ssh-config"
}

@test "AC-14: import --apply REALLY reinstalls both archetypes after a wipe" {
    _install_mixed

    engine_lt_run "" export "$(_payload)"
    assert_success

    _wipe_state
    # Post-wipe: state is empty and both artifacts are gone (precondition for a
    # REAL reinstall rather than an idempotent noop).
    run engine_lt_state_has gum
    assert_failure
    [[ ! -e "${ENGINE_LT_HOME}/.local/bin/gum" ]]
    [[ ! -f "${ENGINE_LT_HOME}/.ssh/config" ]]

    # The import reinstall re-runs gum's github-release lifecycle, so the fetch
    # seam MUST be present on this call too.
    #
    # Exit-code note (documented, same alpine limit as the #176 apt archetype):
    # the exported payload carries gum's depends_on closure, which the import
    # pipeline re-resolves — pulling in apt-essentials (apt archetype). On the
    # alpine test-tools image apt cannot run, so that ONE dependency install
    # fails and the dispatcher reports partial-failure (exit 6, PRD §7.4). That
    # is by design (hard rule #2 / ADR-0004: no host package installs in tests)
    # and orthogonal to AC-14, which is about the MIXED archetypes under test
    # (github-release + config) being REALLY reinstalled. We therefore assert on
    # the real reinstall ARTIFACTS below, not on an overall exit 0, and still
    # require NO #174 wiring errors and that the import reached the apply phase.
    engine_lt_run "$(_gh_env)" import "$(_payload)" --apply -y
    engine_lt_assert_no_wiring_errors
    assert_output --partial "import applied"
    # The github-release + config modules under test both installed cleanly in
    # the same engine run (only the apt dependency failed).
    assert_output --partial "gum installed"
    assert_output --partial "ssh-config installed"

    # 1) state.json round-trips: BOTH modules recorded again by the real engine.
    engine_lt_state_has gum
    engine_lt_state_has ssh-config

    # 2) github-release archetype: real extract+symlink put the binary back and
    #    the module rewrote its Sidecar (ADR-0001).
    [[ -x "${ENGINE_LT_HOME}/.local/bin/gum" ]]
    [[ "$(engine_lt_sidecar gum)" == "${_GUM_V}" ]]

    # 3) config archetype: the managed file was dropped again by the real
    #    install (not a state-only merge).
    [[ -f "${ENGINE_LT_HOME}/.ssh/config" ]]
    run grep -q "init_ubuntu managed" "${ENGINE_LT_HOME}/.ssh/config"
    assert_success
}

@test "AC-14: import dry-run (default) plans both archetypes but reinstalls nothing" {
    _install_mixed

    engine_lt_run "" export "$(_payload)"
    assert_success

    _wipe_state

    # Default import is dry-run (ADR-0013): it must PLAN install for both
    # absent modules yet leave the wiped machine untouched — proving --apply
    # (the test above) is what actually drives the reinstall.
    engine_lt_run "$(_gh_env)" import "$(_payload)"
    assert_success
    engine_lt_assert_no_wiring_errors
    assert_output --partial "IMPORT DIFF"
    assert_output --partial "gum"
    assert_output --partial "ssh-config"
    assert_output --partial "dry-run"

    # Nothing was reinstalled: state stays empty, artifacts stay gone.
    run engine_lt_state_has gum
    assert_failure
    run engine_lt_state_has ssh-config
    assert_failure
    [[ ! -e "${ENGINE_LT_HOME}/.local/bin/gum" ]]
    [[ ! -f "${ENGINE_LT_HOME}/.ssh/config" ]]
}
