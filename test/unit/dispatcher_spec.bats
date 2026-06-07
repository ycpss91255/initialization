#!/usr/bin/env bats
# test/unit/dispatcher_spec.bats — lib/dispatcher.sh

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false

    FAKE_MODULE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/module"
    mkdir -p "${FAKE_MODULE_DIR}"

    cat > "${FAKE_MODULE_DIR}/noop.module.sh" <<'EOF'
NAME="noop"
CATEGORY="optional"
TAGS=("test")
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=()
CONFLICTS_WITH=()

install() { return 0; }
remove()  { return 0; }
purge()   { return 0; }
EOF
}

teardown() {
    teardown_test_env
}

_load_engine() {
    # shellcheck source=../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../lib/color.sh
    source "${LIB_DIR}/color.sh"
    # shellcheck source=../../lib/general.sh
    source "${LIB_DIR}/general.sh"
    # shellcheck source=../../lib/state.sh
    source "${LIB_DIR}/state.sh"
    # shellcheck source=../../lib/state_io.sh
    source "${LIB_DIR}/state_io.sh"
    # shellcheck source=../../lib/config.sh
    source "${LIB_DIR}/config.sh"
    # shellcheck source=../../lib/registry.sh
    source "${LIB_DIR}/registry.sh"
    # shellcheck source=../../lib/resolver.sh
    source "${LIB_DIR}/resolver.sh"
    # shellcheck source=../../lib/runner.sh
    source "${LIB_DIR}/runner.sh"
    # shellcheck source=../../lib/dispatcher.sh
    source "${LIB_DIR}/dispatcher.sh"
    registry_load_all "${FAKE_MODULE_DIR}"
}

@test "dispatcher_dispatch with no args prints usage" {
    _load_engine
    run dispatcher_dispatch
    assert_success
    assert_output --partial "Usage: setup_ubuntu"
}

@test "dispatcher_dispatch --help prints usage" {
    _load_engine
    run dispatcher_dispatch --help
    assert_success
    assert_output --partial "Usage: setup_ubuntu"
}

@test "dispatcher_dispatch --version prints tool version" {
    _load_engine
    run dispatcher_dispatch --version
    assert_success
    assert_output --partial "init_ubuntu"
}

@test "dispatcher_dispatch list shows registered modules" {
    _load_engine
    run dispatcher_dispatch list
    assert_success
    assert_output --partial "noop"
}

@test "dispatcher_dispatch list --category=optional filters" {
    _load_engine
    run dispatcher_dispatch list --category=optional
    assert_success
    assert_output --partial "noop"
}

@test "dispatcher_dispatch list --category=base produces empty (no base modules in fixture)" {
    _load_engine
    run dispatcher_dispatch list --category=base
    assert_success
    refute_output --partial "noop"
}

@test "dispatcher_dispatch show <module> prints metadata fields" {
    _load_engine
    run dispatcher_dispatch show noop
    assert_success
    assert_output --partial "name:"
    assert_output --partial "noop"
    assert_output --partial "category:"
    assert_output --partial "optional"
}

@test "dispatcher_dispatch show unknown returns exit 2" {
    _load_engine
    run dispatcher_dispatch show nonexistent
    assert_failure 2
}

@test "dispatcher_dispatch install without modules returns exit 2" {
    _load_engine
    run dispatcher_dispatch install
    assert_failure 2
}

@test "dispatcher_dispatch install <module> --dry-run does not execute" {
    _load_engine
    run dispatcher_dispatch install noop --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
    assert_output --partial "noop"
}

@test "dispatcher_dispatch install <module> --dry-run succeeds" {
    # Use --dry-run because the test-tools container runs as root and the
    # dispatcher refuses real install/remove/purge under root (PRD §10).
    # Dry-run is the right surface for testing dispatcher -> resolver wiring
    # without depending on container user identity.
    _load_engine
    run dispatcher_dispatch install noop --dry-run
    assert_success
}

@test "dispatcher_dispatch install nonexistent returns exit 2 (resolver unknown)" {
    _load_engine
    run dispatcher_dispatch install nonexistent
    assert_failure 2
}

@test "dispatcher_dispatch unknown-subcommand returns exit 2" {
    _load_engine
    run dispatcher_dispatch this-is-not-real
    assert_failure 2
}

@test "dispatcher_dispatch stubbed subcommand (self-upgrade) returns non-zero with 'not implemented'" {
    _load_engine
    run dispatcher_dispatch self-upgrade
    assert_failure
    assert_output --partial "not implemented"
}

# ── update removed (PRD §7.2, Q40) ──────────────────────────────────────────

@test "dispatcher_dispatch update returns exit 2 (unknown subcommand, Q40)" {
    _load_engine
    run dispatcher_dispatch update
    assert_failure 2
    assert_output --partial "unknown subcommand"
}

@test "dispatcher_dispatch update hints at self-upgrade and gh-latest cache" {
    _load_engine
    run dispatcher_dispatch update
    assert_failure 2
    assert_output --partial "self-upgrade"
    assert_output --partial "gh-latest"
}

@test "usage text does not advertise update" {
    _load_engine
    run dispatcher_dispatch help
    assert_success
    refute_output --regexp '^[[:space:]]+update[[:space:]]'
}

# ── config load removed (PRD Q38); get/set/unset/show remain ────────────────

@test "dispatcher_dispatch config load returns exit 2 (removed, Q38)" {
    _load_engine
    run dispatcher_dispatch config load
    assert_failure 2
    assert_output --partial "unknown config action"
}

@test "usage text does not advertise config load" {
    _load_engine
    run dispatcher_dispatch help
    assert_success
    refute_output --partial "config load"
    refute_output --partial "load|"
    refute_output --partial "|load"
}

@test "dispatcher_dispatch config set + get round-trips a value" {
    _load_engine
    run dispatcher_dispatch config set ui.lang zh-TW
    assert_success
    run dispatcher_dispatch config get ui.lang
    assert_success
    assert_output "zh-TW"
}

@test "dispatcher_dispatch config unset removes the key" {
    _load_engine
    dispatcher_dispatch config set ui.lang en
    run dispatcher_dispatch config unset ui.lang
    assert_success
    run dispatcher_dispatch config get ui.lang
    assert_success
    assert_output ""
}

@test "dispatcher_dispatch config show --json prints structured config" {
    _load_engine
    dispatcher_dispatch config set ui.lang zh-TW
    run dispatcher_dispatch config show --json
    assert_success
    echo "${output}" | jq -e '.ui.lang == "zh-TW"' > /dev/null
}

# ── status deprecation → forwards to list --installed (PRD §7.2) ────────────

@test "dispatcher_dispatch status prints a deprecation warning on stderr" {
    _load_engine
    run dispatcher_dispatch status
    assert_success
    assert_output --partial "deprecated"
    assert_output --partial "list --installed"
}

@test "dispatcher_dispatch status forwards to list --installed (empty state)" {
    _load_engine
    run dispatcher_dispatch status
    assert_success
    assert_output --partial "no modules recorded as installed"
}

@test "dispatcher_dispatch status --json forwards and emits state.json shape" {
    _load_engine
    run dispatcher_dispatch status --json
    assert_success
    assert_output --partial '"installed"'
}

@test "dispatcher_dispatch status keeps stdout JSON clean (warning only on stderr)" {
    _load_engine
    dispatcher_dispatch status --json 2>/dev/null | jq -e '.installed | length == 0' > /dev/null
}

# ── list --installed (replaces status) ───────────────────────────────────────

@test "dispatcher_dispatch list --installed with empty state says no modules" {
    _load_engine
    run dispatcher_dispatch list --installed
    assert_success
    assert_output --partial "no modules recorded as installed"
}

@test "dispatcher_dispatch list --installed shows modules recorded in state" {
    _load_engine
    state_record_install noop true
    run dispatcher_dispatch list --installed
    assert_success
    assert_output --partial "noop"
    assert_output --partial "MODULE"
}

@test "dispatcher_dispatch list --installed --json dumps state.json" {
    _load_engine
    state_record_install noop true
    dispatcher_dispatch list --installed --json | jq -e '.installed.noop.synced.manual == true' > /dev/null
}

# ── import / export conflict pipeline (issue #43, ADR-0013) ─────────────────

# Writes a payload referencing the fixture module `noop` to $1.
_write_noop_payload() {
    cat > "$1" <<'EOF'
{
  "version": "0.2.0",
  "source_host": "machine-a",
  "source_user": "tester",
  "exported_at": "2026-06-07T10:00:00+00:00",
  "modules": [
    {"name": "noop", "synced": {"manual": true, "depends_on": [],
     "version_provided": "v9", "installed_at": "2026-06-07T09:00:00+00:00",
     "installed_by": "init_ubuntu@v0.1.0"}}
  ],
  "include_config": false
}
EOF
}

@test "import default run is a dry-run: prints plan, writes nothing (AC-40 pattern)" {
    _load_engine
    state_init
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    _write_noop_payload "${_payload}"

    run dispatcher_dispatch import "${_payload}"
    assert_success
    assert_output --partial "noop"
    assert_output --partial "install"
    assert_output --partial "--apply"

    local _p; _p="$(state_get_path)"
    run jq -r '.installed | length' "${_p}"
    assert_success
    assert_output "0"
}

@test "import --apply with same-version manual flip applies sticky manual (AC-42 pattern)" {
    _load_engine
    state_record_install noop false v9
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    _write_noop_payload "${_payload}"

    run dispatcher_dispatch import "${_payload}" --apply
    assert_success

    local _p; _p="$(state_get_path)"
    run jq -r '.installed.noop.synced.manual' "${_p}"
    assert_success
    assert_output "true"
}

@test "import dry-run marks payload-only module unknown to catalog as skip" {
    _load_engine
    state_init
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    cat > "${_payload}" <<'EOF'
{"version":"0.2.0","modules":[{"name":"not-in-catalog","synced":{"manual":true,"version_provided":"v1"}}]}
EOF
    run dispatcher_dispatch import "${_payload}"
    assert_success
    assert_output --partial "skip"
    assert_output --partial "no local module definition"
}

@test "import --apply as root refuses when install lifecycle is needed (exit 4)" {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || skip "root-refusal path needs the container root user"
    _load_engine
    state_init
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    _write_noop_payload "${_payload}"

    run dispatcher_dispatch import "${_payload}" --apply
    assert_failure 4
}

@test "import rejects payload with bad version (exit 2)" {
    _load_engine
    state_init
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    echo '{"modules":[]}' > "${_payload}"
    run dispatcher_dispatch import "${_payload}"
    assert_failure 2
}

# ── Exit-code contract (PRD §7.4) ────────────────────────────────────────────

@test "exit 2: list with unknown flag" {
    _load_engine
    run dispatcher_dispatch list --bogus
    assert_failure 2
}

@test "exit 2: config with missing args" {
    _load_engine
    run dispatcher_dispatch config set ui.lang
    assert_failure 2
    run dispatcher_dispatch config get
    assert_failure 2
    run dispatcher_dispatch config unset
    assert_failure 2
}

@test "exit 4: real install as root is refused" {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || skip "root-refusal path needs the container root user"
    _load_engine
    run dispatcher_dispatch install noop
    assert_failure 4
}

@test "exit 5: dependency cycle returns 5" {
    cat > "${FAKE_MODULE_DIR}/cyc-a.module.sh" <<'EOF'
NAME="cyc-a"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=("cyc-b")
CONFLICTS_WITH=()
install() { return 0; }
EOF
    cat > "${FAKE_MODULE_DIR}/cyc-b.module.sh" <<'EOF'
NAME="cyc-b"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=("cyc-a")
CONFLICTS_WITH=()
install() { return 0; }
EOF
    _load_engine
    run dispatcher_dispatch install cyc-a --dry-run
    assert_failure 5
}

@test "exit 1: doctor reports drift with exit 1 (Diag class, PRD §7.4)" {
    _load_engine
    state_record_install ghost-module true
    run dispatcher_dispatch doctor
    assert_failure 1
    assert_output --partial "drift"
}

@test "exit 0: doctor with empty state is consistent" {
    _load_engine
    run dispatcher_dispatch doctor
    assert_success
    assert_output --partial "consistent"
}

# ── Global flags: --color / --verbose / --quiet (PRD §7.5, issue #45) ───────

@test "global flag --verbose sets LOG_LEVEL=DEBUG" {
    _load_engine
    dispatcher_dispatch version --verbose >/dev/null
    [ "${LOG_LEVEL}" = "DEBUG" ]
}

@test "global flag -v sets LOG_LEVEL=DEBUG" {
    _load_engine
    dispatcher_dispatch version -v >/dev/null
    [ "${LOG_LEVEL}" = "DEBUG" ]
}

@test "global flag --quiet sets LOG_LEVEL=WARN" {
    _load_engine
    dispatcher_dispatch version --quiet >/dev/null
    [ "${LOG_LEVEL}" = "WARN" ]
}

@test "global flags are accepted before the subcommand" {
    _load_engine
    dispatcher_dispatch --verbose list >/dev/null
    [ "${LOG_LEVEL}" = "DEBUG" ]
}

@test "global flag --color=never is consumed and disables color" {
    _load_engine
    dispatcher_dispatch --color=never list >/dev/null
    [ "${COLOR_ENABLED}" = "false" ]
    [ "${INIT_UBUNTU_COLOR_MODE}" = "never" ]
}

@test "global flag --color=always is consumed and enables color" {
    _load_engine
    dispatcher_dispatch list --color=always >/dev/null
    [ "${COLOR_ENABLED}" = "true" ]
    [ "${INIT_UBUNTU_COLOR_MODE}" = "always" ]
}

@test "global flag --color=bogus is rejected with exit 2" {
    _load_engine
    run dispatcher_dispatch list --color=bogus
    assert_failure 2
    assert_output --partial "invalid --color mode"
}

@test "global flag alone still prints usage" {
    _load_engine
    run dispatcher_dispatch --verbose
    assert_success
    assert_output --partial "Usage: setup_ubuntu"
}
