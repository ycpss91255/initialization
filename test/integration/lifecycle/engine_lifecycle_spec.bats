#!/usr/bin/env bats
# test/integration/lifecycle/engine_lifecycle_spec.bats
#
# KEYSTONE real engine-lifecycle harness (issue #175) + AC-1/2/3 base-install
# exercises a github-release module (issue #176).
#
# Drives the REAL non-dry-run path that NO prior test covered and that let the
# #174 bug ship:
#   setup_ubuntu.sh → dispatcher install → runner → source module (subshell)
#   → archetype macro (module_use_*_archetype) → lifecycle fn
#
# Why this is the gap (5-level audit, 2026-06-19):
#   - every other install test is --dry-run (dispatcher PLAN-ONLY; never
#     reaches the runner, so the module is never sourced in the engine
#     subshell), OR
#   - uses the unit `_load_engine` helper which pre-sources module_helper.sh
#     (so an entrypoint that FORGOT to source it still passes), OR
#   - CI base-install only ran apt modules, whose hand-rolled install()
#     survives broken engine wiring.
# This spec closes all three: a NON-ROOT user (install refuses EUID 0) drives
# the real entrypoint per archetype, asserting the chain works end to end and
# carries NO `command not found` / NO `module does not define <phase>` — the
# exact signatures the pre-#174 tree emits (module_use_*_archetype: command
# not found). Run against that tree, every install/upgrade test below FAILS.
#
# Determinism: ONLY the github-release network boundary is stubbed, via the
# INIT_UBUNTU_TEST_GH_* offline seams in lib/module_helper.sh (fixture tarball
# + constant version). Everything downstream — gzip sniff, tar extract,
# symlink, state.json, Sidecar — runs for real. No network, no sudo (all
# install targets are user-home scratch paths).
#
# Archetype coverage:
#   github-release : gum   — FULL: install→state→verify→idempotent→remove,
#                            + upgrade with a Sidecar version bump (AC-22).
#                            This is the archetype #174 actually broke.
#   config         : ssh-config         — FULL real install→state→verify→remove
#   custom         : claude-code-config — FULL (overrides the archetype macro
#                            with hand-rolled lifecycle bodies)
#   apt            : tmux  — REDUCED on the alpine test-tools image (no apt,
#                            no sudo): the apt step cannot complete, so we
#                            assert the archetype MACRO is wired in the real
#                            subprocess (no command-not-found / no
#                            undefined-phase) — the #174 signal — rather than
#                            a completed install. The github-release/config/
#                            custom paths above are the ones that broke and
#                            are covered at full level.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/engine_lifecycle"

# gum (charmbracelet/gum): the user-home, sudo-free github-release module.
# Asset pattern is gum_<ver>_Linux_<arch> (STRIP_COMPONENTS=1).
_GUM_V1="0.16.2"
_GUM_V2="0.17.0"

_gum_arch() {
    case "$(uname -m)" in
        x86_64)        printf 'x86_64' ;;
        aarch64|arm64) printf 'arm64' ;;
        armv7l)        printf 'armv7' ;;
        *)             printf 'x86_64' ;;
    esac
}

_gum_asset() { printf 'gum_%s_Linux_%s.tar.gz' "${1}" "$(_gum_arch)"; }

setup() {
    engine_lt_require_root
    setup_test_env
    engine_lt_setup_user
}

teardown() {
    teardown_test_env
}

# ── #176 visibility: which matrix image is this shard standing in for ────────
# CI sets INIT_UBUNTU_TEST_IMAGE=ubuntu:22.04|24.04|26.04 per shard (ci.yaml).
# There is no docker socket in the test container (compose.yaml), so the real
# install runs inside the alpine test-tools image; the matrix makes this spec
# run once PER ubuntu target so AC-1/2/3 "lands on all three images" is the
# green aggregate of the three shards. Record the target for the log.
@test "engine-lifecycle harness runs (records #176 matrix target)" {
    echo "# matrix target: ${INIT_UBUNTU_TEST_IMAGE:-<unset; local run>}" >&3
    [[ -x "${REPO_ROOT}/setup_ubuntu.sh" ]]
}

# ── github-release archetype (gum) — the path #174 broke ────────────────────

@test "github-release: real install wires the archetype macro + records state + Sidecar (#176)" {
    engine_lt_make_gh_fixture "$(_gum_asset "${_GUM_V1}")" gum "${_GUM_V1}"

    engine_lt_run "INIT_UBUNTU_TEST_GH_VERSION=${_GUM_V1} INIT_UBUNTU_TEST_GH_FIXTURE_DIR=${ENGINE_LT_FIXTURE}" \
        install gum --no-deps -y
    assert_success
    engine_lt_assert_no_wiring_errors
    assert_output --partial "gum installed"

    # state.json recorded by the real engine (runner → state_record_install).
    engine_lt_state_has gum
    # Sidecar (ADR-0001) written by the module on success.
    [[ "$(engine_lt_sidecar gum)" == "${_GUM_V1}" ]]
    # Real extract + symlink produced a runnable binary at the scratch BIN_LINK.
    [[ -x "${ENGINE_LT_HOME}/.local/bin/gum" ]]
}

@test "github-release: verify passes through the real runner (AC after install)" {
    engine_lt_make_gh_fixture "$(_gum_asset "${_GUM_V1}")" gum "${_GUM_V1}"
    engine_lt_run "INIT_UBUNTU_TEST_GH_VERSION=${_GUM_V1} INIT_UBUNTU_TEST_GH_FIXTURE_DIR=${ENGINE_LT_FIXTURE}" \
        install gum --no-deps -y
    assert_success

    engine_lt_run "INIT_UBUNTU_TEST_GH_FIXTURE_DIR=${ENGINE_LT_FIXTURE}" verify gum
    assert_success
    engine_lt_assert_no_wiring_errors
    assert_output --partial "gum verified"
}

@test "github-release: second install is idempotent (AC-5/6)" {
    engine_lt_make_gh_fixture "$(_gum_asset "${_GUM_V1}")" gum "${_GUM_V1}"
    local _env="INIT_UBUNTU_TEST_GH_VERSION=${_GUM_V1} INIT_UBUNTU_TEST_GH_FIXTURE_DIR=${ENGINE_LT_FIXTURE}"

    engine_lt_run "${_env}" install gum --no-deps -y
    assert_success

    # Re-run: module_skip_if_installed short-circuits; still exits clean and
    # leaves a single state entry. No re-fetch side effects, no wiring errors.
    engine_lt_run "${_env}" install gum --no-deps -y
    assert_success
    engine_lt_assert_no_wiring_errors
    assert_output --partial "already installed"
    [[ "$(engine_lt_sidecar gum)" == "${_GUM_V1}" ]]
}

@test "github-release: upgrade bumps the Sidecar version (AC-22)" {
    engine_lt_make_gh_fixture "$(_gum_asset "${_GUM_V1}")" gum "${_GUM_V1}"
    engine_lt_make_gh_fixture "$(_gum_asset "${_GUM_V2}")" gum "${_GUM_V2}"

    engine_lt_run "INIT_UBUNTU_TEST_GH_VERSION=${_GUM_V1} INIT_UBUNTU_TEST_GH_FIXTURE_DIR=${ENGINE_LT_FIXTURE}" \
        install gum --no-deps -y
    assert_success
    [[ "$(engine_lt_sidecar gum)" == "${_GUM_V1}" ]]

    # Upgrade resolves the (stubbed) newer version, re-fetches the v2 fixture,
    # backs up the old payload, re-extracts, and rewrites the Sidecar.
    engine_lt_run "INIT_UBUNTU_TEST_GH_VERSION=${_GUM_V2} INIT_UBUNTU_TEST_GH_FIXTURE_DIR=${ENGINE_LT_FIXTURE}" \
        upgrade gum -y
    assert_success
    engine_lt_assert_no_wiring_errors
    assert_output --partial "gum upgraded"
    [[ "$(engine_lt_sidecar gum)" == "${_GUM_V2}" ]]
}

@test "github-release: remove tears down binary + Sidecar + state" {
    engine_lt_make_gh_fixture "$(_gum_asset "${_GUM_V1}")" gum "${_GUM_V1}"
    engine_lt_run "INIT_UBUNTU_TEST_GH_VERSION=${_GUM_V1} INIT_UBUNTU_TEST_GH_FIXTURE_DIR=${ENGINE_LT_FIXTURE}" \
        install gum --no-deps -y
    assert_success

    # --no-deps: scope the removal to gum so the dependency closure
    # (curl) isn't dragged in — it can't be removed on the
    # apt-less alpine harness and isn't what this test asserts.
    engine_lt_run "INIT_UBUNTU_TEST_GH_FIXTURE_DIR=${ENGINE_LT_FIXTURE}" remove gum --no-deps -y
    assert_success
    engine_lt_assert_no_wiring_errors
    assert_output --partial "gum removed"

    [[ ! -e "${ENGINE_LT_HOME}/.local/bin/gum" ]]
    [[ -z "$(engine_lt_sidecar gum)" ]]
    run engine_lt_state_has gum
    assert_failure
}

# ── config archetype (ssh-config) ───────────────────────────────────────────

@test "config: real install drops the managed file + records state, then verify + remove" {
    engine_lt_run "" install ssh-config --no-deps -y
    assert_success
    engine_lt_assert_no_wiring_errors
    assert_output --partial "ssh-config installed"

    engine_lt_state_has ssh-config
    [[ -f "${ENGINE_LT_HOME}/.ssh/config" ]]
    grep -q "init_ubuntu managed" "${ENGINE_LT_HOME}/.ssh/config"

    # Second install is idempotent (AC-5/6).
    engine_lt_run "" install ssh-config --no-deps -y
    assert_success
    assert_output --partial "already installed"

    engine_lt_run "" verify ssh-config
    assert_success
    assert_output --partial "ssh-config verified"

    engine_lt_run "" remove ssh-config --no-deps -y
    assert_success
    engine_lt_assert_no_wiring_errors
    [[ ! -f "${ENGINE_LT_HOME}/.ssh/config" ]]
}

# Regression (linux-review F1): the v2 path never exports BACKUP_DIR. A config
# module that backs up an existing config on upgrade used to hit
# `log_fatal "BACKUP_DIR is not set."` — exit 1, uncatchable by the archetype's
# `|| true`, aborting the whole run on every target. Drive the REAL engine
# upgrade with BACKUP_DIR forced empty (the last env assignment wins over the
# helper's default) and prove the run completes and still snapshots the config.
@test "config: real upgrade does NOT abort when BACKUP_DIR is unset (F1)" {
    engine_lt_run "" install ssh-config --no-deps -y
    assert_success
    [[ -f "${ENGINE_LT_HOME}/.ssh/config" ]]

    # BACKUP_DIR= empties the helper-injected value → backup_file must default
    # it into the state dir instead of fatally aborting.
    engine_lt_run "BACKUP_DIR=" upgrade ssh-config -y
    assert_success
    engine_lt_assert_no_wiring_errors
    refute_output --partial "BACKUP_DIR is not set"
    # Managed config survived the upgrade and the pre-upgrade copy was snapshotted
    # under the defaulted state-dir backup.
    [[ -f "${ENGINE_LT_HOME}/.ssh/config" ]]
    grep -q "init_ubuntu managed" "${ENGINE_LT_HOME}/.ssh/config"
    run bash -c "cat '${ENGINE_LT_STATE}'/backup/*/config"
    assert_success
}

# ── custom archetype (claude-code-config: macro + hand-rolled overrides) ─────

@test "custom: real install runs the overridden lifecycle + records state, then verify + remove" {
    engine_lt_run "" install claude-code-config --no-deps -y
    assert_success
    engine_lt_assert_no_wiring_errors
    assert_output --partial "claude-code-config installed"

    engine_lt_state_has claude-code-config
    # The custom _claude_config_drop_files override dropped all companion files.
    [[ -f "${ENGINE_LT_HOME}/.claude/settings.json" ]]
    [[ -x "${ENGINE_LT_HOME}/.claude/run-statusline.sh" ]]
    [[ -n "$(engine_lt_sidecar claude-code-config)" ]]

    # Idempotent re-install.
    engine_lt_run "" install claude-code-config --no-deps -y
    assert_success

    engine_lt_run "" verify claude-code-config
    assert_success
    assert_output --partial "claude-code-config verified"

    engine_lt_run "" remove claude-code-config --no-deps -y
    assert_success
    engine_lt_assert_no_wiring_errors
    [[ ! -f "${ENGINE_LT_HOME}/.claude/settings.json" ]]
    [[ -z "$(engine_lt_sidecar claude-code-config)" ]]
}

# ── apt archetype (tmux) — REDUCED level, documented ────────────────────────

@test "apt: real install wires the archetype macro in the engine subshell (reduced: no apt/sudo on alpine)" {
    # On the alpine test-tools image there is no apt and the non-root user has
    # no sudo, so module_default_apt_install cannot complete — by design (we
    # never run host package installs in tests, ADR-0004 / hard rule #2). What
    # MUST hold, and is exactly the #174 signal, is that the real engine
    # subshell reached the macro-wired install(): no `command not found`
    # (module_use_apt_archetype et al. resolved) and no `module does not
    # define install`. The github-release/config/custom paths above cover the
    # full install→verify→remove cycle at full fidelity.
    engine_lt_run "" install tmux --no-deps -y
    engine_lt_assert_no_wiring_errors
    # The runner reached the module and started its install phase.
    assert_output --partial "tmux: installing"
}
