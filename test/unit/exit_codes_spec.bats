#!/usr/bin/env bats
# test/unit/exit_codes_spec.bats — exit-code contract (PRD §7.4)
#
# Stream S1 (non-functional audit #178): pin the documented dispatcher /
# lifecycle exit codes by driving the REAL setup_ubuntu.sh entry point
# (root-safe subcommands + --dry-run where a real mutation would otherwise
# refuse root). Everything here is reachable OFFLINE — no apt / sudo / curl.
#
# PRD §7.4 contract:
#   0  success / Query=yes
#   1  general error / Query=no
#   2  arg error (unknown subcommand / misspelled module / invalid metadata)
#   3  unsupported environment (non-Ubuntu / unsupported version)
#   4  sudo unavailable & module lacks user-home  (also: install/upgrade
#      refuse EUID 0 — see _dispatcher_lifecycle / _dispatcher_upgrade)
#   5  dep cycle / dep-resolution fail / CONFLICTS_WITH triggered
#   6  partial module failure (others succeeded)
#   7  remote / network failure (sync/SSH, GitHub download, apt repo)
#
#   Lifecycle classes:
#     Query (detect/is_installed/is_recommended/is_outdated): 0=yes 1=no
#     Action (install/upgrade/remove/purge): 0 / 1 / 3=env / 4=sudo / 5=dep / 7=net
#     Diag  (verify/doctor): 0=pass / 1=fail / 7=net
#
# Spec discipline (this round is TEST-ONLY): where the production code
# violates §7.4, the assertion encodes the CORRECT documented behavior but is
# `skip`-ped with a TODO(prod-bug) tag so the branch stays GREEN-mergeable.
# Active (non-skipped) tests pin behavior that ALREADY matches the contract.

load "${BATS_TEST_DIRNAME}/../helper/common"

SUT="${REPO_ROOT}/setup_ubuntu.sh"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
}

teardown() {
    teardown_test_env
}

# ── Helpers ──────────────────────────────────────────────────────────────────

# Write a minimal module fixture into a scratch MODULE_DIR. Mirrors the
# resolver_spec _make_mod shape so registry_load_all parses it.
_mk_mod() {
    local _dir="$1" _name="$2" _deps="$3" _conflicts="${4:-}"
    cat > "${_dir}/${_name}.module.sh" <<EOF
NAME="${_name}"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=(${_deps})
CONFLICTS_WITH=(${_conflicts})
EOF
}

# ── Code 0 — success / read-only subcommands ─────────────────────────────────

@test "exit 0: --help" {
    run bash "${SUT}" --help
    assert_success
}

@test "exit 0: --version" {
    run bash "${SUT}" --version
    assert_success
}

@test "exit 0: bare invocation (no args) prints usage" {
    run bash "${SUT}"
    assert_success
}

@test "exit 0: detect (root-safe Query-style env probe)" {
    run bash "${SUT}" detect
    assert_success
}

@test "exit 0: detect --json" {
    run bash "${SUT}" detect --json
    assert_success
}

@test "exit 0: list against the real registry" {
    run bash "${SUT}" list
    assert_success
}

@test "exit 0: show docker" {
    run bash "${SUT}" show docker
    assert_success
}

@test "exit 0: install docker --dry-run (resolves + plans, no mutation)" {
    run bash "${SUT}" install docker --dry-run
    assert_success
}

@test "exit 0: doctor with empty state is consistent (Diag pass)" {
    run bash "${SUT}" doctor
    assert_success
}

@test "exit 0: verify with empty state has nothing to verify" {
    run bash "${SUT}" verify
    assert_success
}

# ── Code 1 — general error / Query=no / Diag=fail ────────────────────────────

@test "exit 1: doctor reports drift when state names an unregistered module (Diag fail)" {
    # Seed state.json with a module that is NOT in the registry → doctor marks
    # it STALE and returns 1 (Diag class fail).
    # shellcheck source=../../lib/state.sh
    source "${LIB_DIR}/state.sh"
    state_record_install ghost-module-not-real true
    run bash "${SUT}" doctor
    assert_failure 1
    assert_output --partial "STALE"
}

# ── Code 2 — argument errors ─────────────────────────────────────────────────

@test "exit 2: unknown subcommand" {
    run bash "${SUT}" frobnicate
    assert_failure 2
    assert_output --partial "unknown subcommand"
}

@test "exit 2: removed 'update' subcommand surfaces as unknown" {
    run bash "${SUT}" update
    assert_failure 2
}

@test "exit 2: install with a misspelled module name (resolver unknown)" {
    run bash "${SUT}" install dokcer --dry-run
    assert_failure 2
}

@test "exit 2: install with no module argument" {
    run bash "${SUT}" install
    assert_failure 2
}

@test "exit 2: install with an unknown flag" {
    run bash "${SUT}" install docker --bogus-flag --dry-run
    assert_failure 2
}

@test "exit 2: detect rejects positional args" {
    run bash "${SUT}" detect extra-arg
    assert_failure 2
}

@test "exit 2: detect rejects unknown flag" {
    run bash "${SUT}" detect --nope
    assert_failure 2
}

@test "exit 2: config with an unknown action" {
    run bash "${SUT}" config bogus-action
    assert_failure 2
}

@test "exit 2: sync without a target" {
    run bash "${SUT}" sync
    assert_failure 2
}

@test "exit 2: invalid metadata — doctor --validate-modules flags an unresolvable DEPENDS_ON" {
    # PRD §9.1 / §7.4 / AC-24: `doctor --validate-modules` lints module
    # metadata; a DEPENDS_ON pointing at a non-module is invalid metadata and
    # must surface exit 2. Build a fixture module whose dep cannot resolve.
    local _md="${INIT_UBUNTU_TEST_SCRATCH}/badmeta_module"
    mkdir -p "${_md}"
    _mk_mod "${_md}" "alpha" '"nonexistent-dep"'

    run env INIT_UBUNTU_USER_MODULE_DIR="${_md}" bash "${SUT}" doctor --validate-modules
    assert_failure 2
}

# ── Code 4 — sudo / root-refusal on Action lifecycle ─────────────────────────

@test "exit 4: install as root refuses (real, non-dry-run)" {
    # _dispatcher_lifecycle resolves deps first (docker→apt-essentials both
    # exist), passes the plan prompt with non-tty stdin (defaults to yes),
    # THEN hits the EUID-0 guard → return 4. Only meaningful when bats runs
    # as root (the test-tools container default); skip cleanly otherwise.
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || skip "root-refusal path needs EUID 0; got ${EUID:-?}"
    run bash -c "printf '\n' | bash '${SUT}' install docker -y"
    assert_failure 4
    assert_output --partial "do not run"
}

@test "exit 4: upgrade as root refuses (real, non-dry-run)" {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || skip "root-refusal path needs EUID 0; got ${EUID:-?}"
    # Seed one installed module so upgrade has work and reaches the root guard
    # (empty installed set short-circuits before the guard).
    # shellcheck source=../../lib/state.sh
    source "${LIB_DIR}/state.sh"
    state_record_install docker true
    run bash "${SUT}" upgrade docker -y
    assert_failure 4
    assert_output --partial "do not run upgrade as root"
}

@test "exit 4: remove as root refuses (real, non-dry-run)" {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || skip "root-refusal path needs EUID 0; got ${EUID:-?}"
    run bash "${SUT}" remove docker -y --no-deps
    assert_failure 4
    assert_output --partial "do not run"
}

@test "exit 4 boundary: install --dry-run stays root-safe (no refusal)" {
    # The EUID-0 guard is gated on NOT dry-run, so dry-run must succeed even
    # as root — this is what keeps CI/bats able to drive the plan path.
    run bash "${SUT}" install docker --dry-run
    assert_success
    refute_output --partial "do not run"
}

# ── Code 5 — dependency resolution failure ───────────────────────────────────

@test "exit 5: dependency cycle via the real entry point" {
    # Two fixture modules that depend on each other → Kahn cannot order them
    # → resolver returns 5, which _dispatcher_lifecycle must propagate to
    # setup_ubuntu's exit status (PRD §7.4 dep-resolution failure = 5).
    local _md="${INIT_UBUNTU_TEST_SCRATCH}/cycle_module"
    mkdir -p "${_md}"
    _mk_mod "${_md}" "loopa" '"loopb"'
    _mk_mod "${_md}" "loopb" '"loopa"'

    # TODO(prod-bug §7.4): resolver_resolve correctly returns 5 on a cycle (see
    # resolver_spec "direct cycle returns exit 5"), but through the REAL
    # entrypoint the code is masked to 1. setup_ubuntu.sh runs `set -euo
    # pipefail; shopt -s inherit_errexit`, so the command substitution
    # `_resolved="$(resolver_resolve ...)"` in _dispatcher_lifecycle inherits
    # errexit and aborts the script with status 1 BEFORE `local _rc=$?` can
    # capture 5. (Unknown-module → 2 survives because that branch returns
    # before the errexit-sensitive closure/topo work.) Fix: capture the
    # resolver rc without letting errexit swallow it, e.g.
    #   _resolved="$(resolver_resolve "${_modules[@]}")" || _rc=$?
    # or temporarily `set +e` around the substitution. Assert the documented
    # exit 5.
    run env INIT_UBUNTU_USER_MODULE_DIR="${_md}" bash "${SUT}" install loopa --dry-run
    assert_failure 5
}

@test "exit 5: CONFLICTS_WITH triggers a dep-resolution failure" {
    # PRD §7.4: installing a module that declares CONFLICTS_WITH another
    # already-requested module must fail dep resolution with exit 5.
    local _md="${INIT_UBUNTU_TEST_SCRATCH}/conflict_module"
    mkdir -p "${_md}"
    # 'one' conflicts with 'two'; requesting both together must be rejected.
    _mk_mod "${_md}" "one" "" '"two"'
    _mk_mod "${_md}" "two" "" ""

    # TODO(prod-bug §7.4): lib/resolver.sh parses CONFLICTS into
    # MODULES_CONFLICTS but never enforces it — resolver_resolve only does
    # topo-sort + cycle/unknown detection, so a conflicting pair resolves
    # cleanly (exit 0) instead of exit 5. Assert the documented contract.
    run env INIT_UBUNTU_USER_MODULE_DIR="${_md}" bash "${SUT}" install one two --dry-run
    assert_failure 5
}

# ── Code 7 — remote / network failure (sync/SSH) ─────────────────────────────

@test "exit 7: sync --pull to an unreachable host (SSH transport failure)" {
    # _sync_require_ssh probes the target with a fast BatchMode ssh; an
    # unresolvable host fails the probe → return 7 (PRD §7.4 network class).
    # Guard: needs the ssh client on PATH (baked into the test-tools image);
    # skip cleanly if absent so the contract test never goes red on tooling.
    command -v ssh >/dev/null 2>&1 || skip "ssh client not available"
    run bash "${SUT}" sync --pull nosuchuser@host.invalid.localdomain.test
    assert_failure 7
    assert_output --partial "cannot ssh"
}

@test "exit 7: sync push to an unreachable host (SSH transport failure)" {
    command -v ssh >/dev/null 2>&1 || skip "ssh client not available"
    run bash "${SUT}" sync nosuchuser@host.invalid.localdomain.test
    assert_failure 7
}

# ── Lifecycle class boundary: Diag verify/doctor never leak code 2..6 ────────

@test "Diag boundary: verify of an installed-but-missing module returns 1 not 6" {
    # verify uses the Diag class (PRD §7.4: 0 pass / 1 fail / 7 net); a single
    # drifted module must surface 1, never the Action-class partial-failure
    # code 6.
    # shellcheck source=../../lib/state.sh
    source "${LIB_DIR}/state.sh"
    # docker is registered; record it installed but it is NOT actually present
    # on the host (alpine test image), so verify()'s is_installed probe fails.
    state_record_install docker true

    # TODO(prod-bug §7.4): verify routes through lib/runner.sh
    # _runner_run_batch, which returns 6 (Action-class partial-failure) on ANY
    # module failure — including the Diag-class verify/doctor phases. Per §7.4
    # verify must use the Diag class (1 on fail), not 6. Assert the documented
    # contract.
    run bash "${SUT}" verify docker
    assert_failure 1
    refute [ "${status}" -eq 6 ]
}
