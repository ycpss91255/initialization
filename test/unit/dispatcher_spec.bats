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
declare -A DESCRIPTION=( [en]="A no-op test module" [zh-TW]="空操作測試模組" )

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
    # shellcheck source=../../lib/i18n.sh
    source "${LIB_DIR}/i18n.sh"
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

@test "dispatcher_dispatch show <module> prints the localized description (#183)" {
    _load_engine
    run dispatcher_dispatch show noop
    assert_success
    assert_output --partial "description: A no-op test module"
}

@test "dispatcher_dispatch show honors INIT_UBUNTU_LANG for the description (#183)" {
    _load_engine
    INIT_UBUNTU_LANG=zh-TW run dispatcher_dispatch show noop
    assert_success
    assert_output --partial "description: 空操作測試模組"
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

@test "dispatcher_dispatch install --profile=<x> is stubbed, not fatal (PRD §7.5, TUI #70 wiring)" {
    # The TUI forks `install --profile=<override> ... -y` when the session
    # platform override is set (§8.2.1). Until --profile lands in the
    # engine it must degrade to a WARN like the other stubbed flags.
    _load_engine
    run dispatcher_dispatch install noop --profile=server --dry-run
    assert_success
    assert_output --partial "stubbed"
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

# ── export subcommand (PRD §7.2) ─────────────────────────────────────────────

@test "dispatcher_dispatch export writes payload and confirms on stdout" {
    _load_engine
    state_record_install noop true v1
    local _out="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    run dispatcher_dispatch export "${_out}"
    assert_success
    assert_output --partial "state exported to"
    run jq -r '.modules[0].name' "${_out}"
    assert_success
    assert_output "noop"
}

@test "dispatcher_dispatch export --modules=<csv> filters the payload" {
    _load_engine
    state_record_install noop true v1
    state_record_install other true v2
    local _out="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    run dispatcher_dispatch export "${_out}" --modules=noop
    assert_success
    run jq -r '.modules | length' "${_out}"
    assert_output "1"
}

@test "dispatcher_dispatch export without <out-file> returns 2" {
    _load_engine
    run dispatcher_dispatch export
    assert_failure 2
}

@test "dispatcher_dispatch export with unknown flag returns 2" {
    _load_engine
    run dispatcher_dispatch export "${INIT_UBUNTU_TEST_SCRATCH}/p.json" --bogus
    assert_failure 2
}

@test "dispatcher_dispatch export with two out-files returns 2" {
    _load_engine
    run dispatcher_dispatch export a.json b.json
    assert_failure 2
}

# ── import argv validation ───────────────────────────────────────────────────

@test "dispatcher_dispatch import without <in-file> returns 2" {
    _load_engine
    run dispatcher_dispatch import
    assert_failure 2
}

@test "dispatcher_dispatch import with unknown flag returns 2" {
    _load_engine
    run dispatcher_dispatch import payload.json --bogus
    assert_failure 2
}

@test "dispatcher_dispatch import with two in-files returns 2" {
    _load_engine
    run dispatcher_dispatch import a.json b.json
    assert_failure 2
}

# ── search ───────────────────────────────────────────────────────────────────

@test "dispatcher_dispatch search without keyword returns 2" {
    _load_engine
    run dispatcher_dispatch search
    assert_failure 2
}

@test "dispatcher_dispatch search matches by name (case-insensitive)" {
    _load_engine
    run dispatcher_dispatch search NOOP
    assert_success
    assert_output --partial "noop"
    assert_output --partial "NAME"
}

@test "dispatcher_dispatch search matches by tag" {
    _load_engine
    run dispatcher_dispatch search test
    assert_success
    assert_output --partial "noop"
}

@test "dispatcher_dispatch search with no match says so" {
    _load_engine
    run dispatcher_dispatch search zzz-not-a-module
    assert_success
    assert_output --partial "no module matches"
}

# ── show argv validation ────────────────────────────────────────────────────

@test "dispatcher_dispatch show without <module> returns 2" {
    _load_engine
    run dispatcher_dispatch show
    assert_failure 2
}

# ── upgrade ──────────────────────────────────────────────────────────────────

@test "dispatcher_dispatch upgrade with empty state has nothing to do (exit 0)" {
    _load_engine
    state_init
    run dispatcher_dispatch upgrade
    assert_success
    assert_output --partial "nothing to upgrade"
}

@test "dispatcher_dispatch upgrade <module> --dry-run lists the order" {
    _load_engine
    run dispatcher_dispatch upgrade noop --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
    assert_output --partial "noop"
}

@test "dispatcher_dispatch upgrade without -y on non-tty aborts (conservative [y/N])" {
    _load_engine
    run dispatcher_dispatch upgrade noop
    assert_failure 1
    assert_output --partial "Proceed? [y/N]"
    assert_output --partial "Aborted."
}

@test "dispatcher_dispatch upgrade with unknown flag returns 2" {
    _load_engine
    run dispatcher_dispatch upgrade --bogus
    assert_failure 2
}

# ── verify ───────────────────────────────────────────────────────────────────

@test "dispatcher_dispatch verify with empty state has nothing to do (exit 0)" {
    _load_engine
    state_init
    run dispatcher_dispatch verify
    assert_success
    assert_output --partial "nothing to verify"
}

@test "dispatcher_dispatch verify <module> --dry-run lists the order" {
    _load_engine
    run dispatcher_dispatch verify noop --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
    assert_output --partial "noop"
}

@test "dispatcher_dispatch verify with unknown flag returns 2" {
    _load_engine
    run dispatcher_dispatch verify --bogus
    assert_failure 2
}

# ── detect ───────────────────────────────────────────────────────────────────

@test "dispatcher_dispatch detect rejects positional args (exit 2)" {
    _load_engine
    run dispatcher_dispatch detect extra-arg
    assert_failure 2
}

@test "dispatcher_dispatch detect rejects unknown flag (exit 2)" {
    _load_engine
    run dispatcher_dispatch detect --bogus
    assert_failure 2
}

@test "dispatcher_dispatch detect errors when detect lib not loaded (exit 1)" {
    _load_engine
    run dispatcher_dispatch detect
    assert_failure 1
    assert_output --partial "not loaded"
}

@test "dispatcher_dispatch detect --json emits JSON with form_factor" {
    _load_engine
    # shellcheck source=../../lib/detect.sh
    source "${LIB_DIR}/detect.sh"
    # shellcheck source=../../lib/platform.sh
    source "${LIB_DIR}/platform.sh"
    dispatcher_dispatch detect --json | jq -e '.form_factor | length > 0' > /dev/null
}

@test "dispatcher_dispatch detect prints human-readable key: value lines" {
    _load_engine
    # shellcheck source=../../lib/detect.sh
    source "${LIB_DIR}/detect.sh"
    # shellcheck source=../../lib/platform.sh
    source "${LIB_DIR}/platform.sh"
    run dispatcher_dispatch detect
    assert_success
    assert_output --partial "os.id:"
    assert_output --partial "form_factor:"
}

# ── sync argv validation ────────────────────────────────────────────────────

@test "dispatcher_dispatch sync without <user@host> returns 2" {
    _load_engine
    run dispatcher_dispatch sync
    assert_failure 2
}

@test "dispatcher_dispatch sync with unknown flag returns 2" {
    _load_engine
    run dispatcher_dispatch sync user@host --bogus
    assert_failure 2
}

@test "dispatcher_dispatch sync with two targets returns 2" {
    _load_engine
    run dispatcher_dispatch sync user@host1 user@host2
    assert_failure 2
}

# ── install plan + confirm (PRD §7.2) ───────────────────────────────────────

@test "install without -y prints the resolved plan before the prompt" {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || skip "relies on root-refusal stopping before runner"
    _load_engine
    run dispatcher_dispatch install noop
    assert_failure 4
    assert_output --partial "Will install: noop"
    assert_output --partial "Proceed? [Y/n]"
}

@test "lifecycle remove --dry-run prints plan without executing" {
    _load_engine
    run dispatcher_dispatch remove noop --dry-run
    assert_success
    assert_output --partial "would remove"
    assert_output --partial "noop"
}

@test "lifecycle purge --dry-run prints plan without executing" {
    _load_engine
    run dispatcher_dispatch purge noop --dry-run
    assert_success
    assert_output --partial "would purge"
    assert_output --partial "noop"
}

# ── list stubbed flags degrade to WARN ──────────────────────────────────────

@test "list --available is stubbed, not fatal" {
    _load_engine
    run dispatcher_dispatch list --available
    assert_success
    assert_output --partial "stubbed"
}

# ── list --json catalog view (issue #165) ───────────────────────────────────

@test "list --json emits valid catalog JSON with .items array" {
    _load_engine
    run dispatcher_dispatch list --json
    assert_success
    echo "${output}" | jq -e '.items | type == "array"' > /dev/null
    echo "${output}" | jq -e '.items[0] | has("name") and has("category") and has("tags")' > /dev/null
    echo "${output}" | jq -e '.items[] | select(.name == "noop") | .category == "optional"' > /dev/null
    echo "${output}" | jq -e '.items[] | select(.name == "noop") | .tags | type == "array"' > /dev/null
}

@test "list --json stdout carries no [dispatcher] warning text" {
    _load_engine
    run dispatcher_dispatch list --json
    assert_success
    refute_output --partial "[dispatcher]"
    refute_output --partial "stubbed"
}

@test "list --json filters by --category" {
    _load_engine
    cat > "${FAKE_MODULE_DIR}/rec.module.sh" <<'EOF'
NAME="rec"
CATEGORY="recommended"
TAGS=("test")
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=()
CONFLICTS_WITH=()
install() { return 0; }
remove()  { return 0; }
purge()   { return 0; }
EOF
    registry_load_all "${FAKE_MODULE_DIR}"
    run dispatcher_dispatch list --category=recommended --json
    assert_success
    echo "${output}" | jq -e '.items | length == 1' > /dev/null
    echo "${output}" | jq -e '.items[0].name == "rec"' > /dev/null
    echo "${output}" | jq -e 'all(.items[]; .category == "recommended")' > /dev/null
}

@test "list --json honors module DESCRIPTION and is_recommended" {
    _load_engine
    cat > "${FAKE_MODULE_DIR}/desc.module.sh" <<'EOF'
NAME="desc"
CATEGORY="optional"
TAGS=("editor" "cli")
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=("x86_64" "rpi5")
DEPENDS_ON=()
CONFLICTS_WITH=()
declare -gA DESCRIPTION=( [en]="a described module" )
install() { return 0; }
remove()  { return 0; }
purge()   { return 0; }
is_recommended() { return 0; }
EOF
    registry_load_all "${FAKE_MODULE_DIR}"
    run dispatcher_dispatch list --json
    assert_success
    echo "${output}" | jq -e '.items[] | select(.name == "desc") | .description == "a described module"' > /dev/null
    echo "${output}" | jq -e '.items[] | select(.name == "desc") | .recommended == true' > /dev/null
    echo "${output}" | jq -e '.items[] | select(.name == "desc") | .tags == ["editor","cli"]' > /dev/null
    echo "${output}" | jq -e '.items[] | select(.name == "desc") | .supported_platforms == ["x86_64","rpi5"]' > /dev/null
}

@test "list --json emits null description/recommended when module lacks them" {
    _load_engine
    # A bare module defining neither DESCRIPTION nor is_recommended: both null.
    cat > "${FAKE_MODULE_DIR}/bare.module.sh" <<'EOF'
NAME="bare"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=()
CONFLICTS_WITH=()
install() { return 0; }
remove()  { return 0; }
purge()   { return 0; }
EOF
    registry_load_all "${FAKE_MODULE_DIR}"
    run dispatcher_dispatch list --json
    assert_success
    echo "${output}" | jq -e '.items[] | select(.name == "bare") | .description == null' > /dev/null
    echo "${output}" | jq -e '.items[] | select(.name == "bare") | .recommended == null' > /dev/null
}

@test "list --json marks a defined-but-false is_recommended as false (not null)" {
    _load_engine
    cat > "${FAKE_MODULE_DIR}/notrec.module.sh" <<'EOF'
NAME="notrec"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=()
CONFLICTS_WITH=()
install() { return 0; }
remove()  { return 0; }
purge()   { return 0; }
is_recommended() { return 1; }
EOF
    registry_load_all "${FAKE_MODULE_DIR}"
    run dispatcher_dispatch list --json
    assert_success
    echo "${output}" | jq -e '.items[] | select(.name == "notrec") | .recommended == false' > /dev/null
}

@test "status forwards flag validation to list --installed (exit 2 on bogus)" {
    _load_engine
    run dispatcher_dispatch status --bogus
    assert_failure 2
}

# ── show --json machine-readable detail (issue #211) ────────────────────────

@test "show --json emits valid JSON for a known module" {
    _load_engine
    run dispatcher_dispatch show noop --json
    assert_success
    echo "${output}" | jq -e 'type == "object"' > /dev/null
    echo "${output}" | jq -e '.name == "noop"' > /dev/null
}

@test "show --json exposes the documented structured fields" {
    _load_engine
    cat > "${FAKE_MODULE_DIR}/full.module.sh" <<'EOF'
NAME="full"
CATEGORY="optional"
TAGS=("editor" "cli")
SUPPORTED_UBUNTU=("22.04" "24.04")
SUPPORTED_PLATFORMS=("x86_64" "rpi5")
DEPENDS_ON=("noop")
CONFLICTS_WITH=("other")
declare -gA DESCRIPTION=( [en]="a full module" )
install() { return 0; }
remove()  { return 0; }
purge()   { return 0; }
EOF
    registry_load_all "${FAKE_MODULE_DIR}"
    run dispatcher_dispatch show full --json
    assert_success
    echo "${output}" | jq -e '.name == "full"' > /dev/null
    echo "${output}" | jq -e '.category == "optional"' > /dev/null
    echo "${output}" | jq -e '.description == "a full module"' > /dev/null
    echo "${output}" | jq -e '.tags == ["editor","cli"]' > /dev/null
    echo "${output}" | jq -e '.supported_ubuntu == ["22.04","24.04"]' > /dev/null
    echo "${output}" | jq -e '.supported_platforms == ["x86_64","rpi5"]' > /dev/null
    echo "${output}" | jq -e '.depends_on == ["noop"]' > /dev/null
    echo "${output}" | jq -e '.conflicts == ["other"]' > /dev/null
}

@test "show --json emits null description and empty arrays when module lacks them" {
    _load_engine
    cat > "${FAKE_MODULE_DIR}/bare2.module.sh" <<'EOF'
NAME="bare2"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=()
CONFLICTS_WITH=()
install() { return 0; }
remove()  { return 0; }
purge()   { return 0; }
EOF
    registry_load_all "${FAKE_MODULE_DIR}"
    run dispatcher_dispatch show bare2 --json
    assert_success
    echo "${output}" | jq -e '.description == null' > /dev/null
    echo "${output}" | jq -e '.tags == []' > /dev/null
    echo "${output}" | jq -e '.depends_on == []' > /dev/null
    echo "${output}" | jq -e '.conflicts == []' > /dev/null
}

@test "show --json accepts the flag before the module name" {
    _load_engine
    run dispatcher_dispatch show --json noop
    assert_success
    echo "${output}" | jq -e '.name == "noop"' > /dev/null
}

@test "show --json honors INIT_UBUNTU_LANG for the description (#211)" {
    _load_engine
    INIT_UBUNTU_LANG=zh-TW run dispatcher_dispatch show noop --json
    assert_success
    echo "${output}" | jq -e '.description == "空操作測試模組"' > /dev/null
}

@test "show --json stdout carries no [dispatcher] or human-readable decoration" {
    _load_engine
    run dispatcher_dispatch show noop --json
    assert_success
    refute_output --partial "[dispatcher]"
    refute_output --partial "name:        "
    refute_output --partial "description: "
}

@test "show --json unknown module returns exit 2 (error on stderr, not stdout)" {
    _load_engine
    # Exit code is 2 (run merges stderr so we check status here only).
    run dispatcher_dispatch show nonexistent --json
    assert_failure 2
    # stdout must carry no JSON for the TUI; the diagnostic goes to stderr.
    local _out _rc=0
    _out="$(dispatcher_dispatch show nonexistent --json 2>/dev/null)" || _rc=$?
    [[ "${_rc}" -eq 2 ]]
    [[ -z "${_out}" ]]
}

@test "show without --json is unchanged (human-readable view)" {
    _load_engine
    run dispatcher_dispatch show noop
    assert_success
    assert_output --partial "name:"
    assert_output --partial "description: A no-op test module"
    refute_output --partial "{"
}

# ── lifecycle flag handling (--verbose / --quiet / unknown) ─────────────────

@test "lifecycle --verbose flag is accepted and dry-run still lists order" {
    _load_engine
    run dispatcher_dispatch install noop --verbose --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
    assert_output --partial "noop"
}

@test "lifecycle --quiet flag sets LOG_LEVEL=WARN and dry-run succeeds" {
    _load_engine
    dispatcher_dispatch install noop --quiet --dry-run >/dev/null
    [ "${LOG_LEVEL}" = "WARN" ]
}

@test "lifecycle with unknown -flag returns exit 2" {
    _load_engine
    run dispatcher_dispatch install noop --no-such-flag
    assert_failure 2
    assert_output --partial "unknown flag"
}

@test "lifecycle --no-deps installs only the named module (skips resolver)" {
    _load_engine
    run dispatcher_dispatch install noop --no-deps --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
    assert_output --partial "noop"
}

# ── upgrade flag handling + state-driven defaults ───────────────────────────

@test "upgrade --verbose flag is accepted and dry-run lists order" {
    _load_engine
    run dispatcher_dispatch upgrade noop --verbose --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
    assert_output --partial "noop"
}

@test "upgrade --quiet flag sets LOG_LEVEL=WARN" {
    _load_engine
    dispatcher_dispatch upgrade noop --quiet --dry-run >/dev/null
    [ "${LOG_LEVEL}" = "WARN" ]
}

@test "upgrade with no args defaults to modules recorded in state (dry-run)" {
    _load_engine
    state_record_install noop true v1
    run dispatcher_dispatch upgrade --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
    assert_output --partial "noop"
}

@test "upgrade -y as root is refused with exit 4 (PRD §10)" {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || skip "root-refusal path needs the container root user"
    _load_engine
    state_record_install noop true v1
    run dispatcher_dispatch upgrade noop -y
    assert_failure 4
    assert_output --partial "do not run upgrade as root"
}

# ── verify state-driven defaults + real runner_verify call ──────────────────

@test "verify with no args defaults to modules recorded in state (dry-run)" {
    _load_engine
    state_record_install noop true v1
    run dispatcher_dispatch verify --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
    assert_output --partial "noop"
}

@test "verify <module> (non-dry-run) invokes runner_verify and reports a result" {
    _load_engine
    state_record_install noop true v1
    run dispatcher_dispatch verify noop
    # runner_verify runs verify() in a subshell; the noop fixture defines no
    # verify(), so the runner reports a failure — what matters for coverage is
    # that the real runner path (not the dry-run branch) executes. verify is a
    # Diag-class subcommand (PRD §7.4: 0 pass / 1 fail / 7 net), so a failure
    # surfaces as 1, NOT the Action-class partial-failure code 6.
    assert_failure 1
}

# ── import plan formatting branches (jq actions) ────────────────────────────

# Writes a payload with noop at a caller-chosen version + manual flag.
_write_noop_payload_ver() {
    local _file="$1" _ver="$2" _manual="${3:-true}"
    cat > "${_file}" <<EOF
{
  "version": "0.2.0",
  "modules": [
    {"name": "noop", "synced": {"manual": ${_manual}, "depends_on": [],
     "version_provided": "${_ver}"}}
  ]
}
EOF
}

@test "import dry-run formats an upgrade action when versions differ" {
    _load_engine
    state_record_install noop true v1
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    _write_noop_payload_ver "${_payload}" v9
    run dispatcher_dispatch import "${_payload}"
    assert_success
    assert_output --partial "noop"
    assert_output --partial "upgrade"
    assert_output --partial "v1 -> v9"
}

@test "import dry-run formats a noop action when versions match and manual unchanged" {
    _load_engine
    state_record_install noop true v9
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    _write_noop_payload_ver "${_payload}" v9 true
    run dispatcher_dispatch import "${_payload}"
    assert_success
    assert_output --partial "noop"
    assert_output --partial "up-to-date"
}

@test "import dry-run formats a flag-manual action when manual flips sticky" {
    _load_engine
    state_record_install noop false v9
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    _write_noop_payload_ver "${_payload}" v9 true
    run dispatcher_dispatch import "${_payload}"
    assert_success
    assert_output --partial "noop"
    assert_output --partial "manual"
}

@test "import dry-run formats a keep action for a local-only module" {
    _load_engine
    state_record_install noop true v9
    state_record_install other true v2
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    _write_noop_payload_ver "${_payload}" v9 true
    run dispatcher_dispatch import "${_payload}"
    assert_success
    assert_output --partial "other"
    assert_output --partial "local only"
}

@test "import --apply with an upgrade action as root is refused (exit 4)" {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || skip "root-refusal path needs the container root user"
    _load_engine
    state_record_install noop true v1
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    _write_noop_payload_ver "${_payload}" v9
    run dispatcher_dispatch import "${_payload}" --apply
    assert_failure 4
    assert_output --partial "do not run import --apply as root"
}

@test "import -y flag is accepted and dry-run still prints the diff" {
    _load_engine
    state_init
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    _write_noop_payload_ver "${_payload}" v9
    run dispatcher_dispatch import "${_payload}" -y
    assert_success
    assert_output --partial "IMPORT DIFF"
}

@test "import --dry-run explicitly wins over --apply" {
    _load_engine
    state_record_install noop true v1
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    _write_noop_payload_ver "${_payload}" v9
    run dispatcher_dispatch import "${_payload}" --apply --dry-run
    assert_success
    assert_output --partial "nothing was changed"
}

# ── doctor: registered module file present (is_installed subshell) ──────────

@test "doctor reports OK when a registered module's is_installed succeeds" {
    cat > "${FAKE_MODULE_DIR}/present.module.sh" <<'EOF'
NAME="present"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=()
CONFLICTS_WITH=()
install() { return 0; }
is_installed() { return 0; }
EOF
    _load_engine
    state_record_install present true v1
    run dispatcher_dispatch doctor
    assert_success
    assert_output --partial "present"
    assert_output --partial "OK"
    assert_output --partial "consistent"
}

@test "doctor reports DRIFTED when a registered module's is_installed fails" {
    cat > "${FAKE_MODULE_DIR}/absent.module.sh" <<'EOF'
NAME="absent"
CATEGORY="optional"
TAGS=()
SUPPORTED_UBUNTU=()
SUPPORTED_PLATFORMS=()
DEPENDS_ON=()
CONFLICTS_WITH=()
install() { return 0; }
is_installed() { return 1; }
EOF
    _load_engine
    state_record_install absent true v1
    run dispatcher_dispatch doctor
    assert_failure 1
    assert_output --partial "absent"
    assert_output --partial "DRIFTED"
}

# ── i18n: human-readable strings localize under INIT_UBUNTU_LANG (#185) ──────

@test "usage renders in zh-TW under INIT_UBUNTU_LANG=zh-TW (#185)" {
    _load_engine
    INIT_UBUNTU_LANG=zh-TW run dispatcher_dispatch help
    assert_success
    assert_output --partial "用法:setup_ubuntu"
    assert_output --partial "子命令:"
}

@test "usage default (en) output is unchanged (#185)" {
    _load_engine
    run dispatcher_dispatch help
    assert_success
    assert_output --partial "Usage: setup_ubuntu <subcommand> [args] [flags]"
    assert_output --partial "See PRD §7 for the full CLI specification."
}

@test "search no-match renders in zh-TW (#185)" {
    _load_engine
    INIT_UBUNTU_LANG=zh-TW run dispatcher_dispatch search zzz-not-a-module
    assert_success
    assert_output --partial "沒有符合"
}

@test "list --installed empty-state renders in zh-TW (#185)" {
    _load_engine
    INIT_UBUNTU_LANG=zh-TW run dispatcher_dispatch list --installed
    assert_success
    assert_output --partial "沒有任何模組被記錄為已安裝"
}

@test "upgrade confirm prompt renders in zh-TW (#185)" {
    _load_engine
    INIT_UBUNTU_LANG=zh-TW run dispatcher_dispatch upgrade noop
    assert_failure 1
    assert_output --partial "即將升級 1 個模組"
    assert_output --partial "是否繼續?[y/N]"
    assert_output --partial "已中止。"
}
