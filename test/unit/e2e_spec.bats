#!/usr/bin/env bats
# test/unit/e2e_spec.bats — end-to-end review path
#
# These specs exercise the real setup_ubuntu.sh entry point (not a wrapper)
# in --dry-run mode against the real module/ directory. This is the spec
# set the human reviewer runs to verify "the engine actually works"
# without touching any real apt / sudo / curl.
#
# Per PRD §11 AC-11 (--dry-run does not write fs) — this file holds the
# bats assertions backing that.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
}

teardown() {
    teardown_test_env
}

# ── setup_ubuntu --help ──────────────────────────────────────────────────────

@test "setup_ubuntu --help prints usage" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" --help
    assert_success
    assert_output --partial "Usage: setup_ubuntu"
    assert_output --partial "install"
    assert_output --partial "remove"
    assert_output --partial "purge"
}

@test "setup_ubuntu --version prints tool version" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" --version
    assert_success
    assert_output --partial "init_ubuntu"
}

# ── list + show against the real registry ────────────────────────────────────

@test "setup_ubuntu list discovers docker and apt-essentials from module/" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" list
    assert_success
    assert_output --partial "docker"
    assert_output --partial "apt-essentials"
}

@test "setup_ubuntu list --category=base shows apt-essentials" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" list --category=base
    assert_success
    assert_output --partial "apt-essentials"
    refute_output --partial "docker"
}

@test "setup_ubuntu list --category=recommended shows docker" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" list --category=recommended
    assert_success
    assert_output --partial "docker"
    refute_output --partial "apt-essentials"
}

@test "setup_ubuntu show docker prints metadata" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" show docker
    assert_success
    assert_output --partial "name:"
    assert_output --partial "docker"
    assert_output --partial "category:"
    assert_output --partial "recommended"
    assert_output --partial "deps:"
    assert_output --partial "apt-essentials"
}

# ── Dep resolution under --dry-run ───────────────────────────────────────────

@test "install docker --dry-run pulls apt-essentials BEFORE docker in install order" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" install docker --dry-run
    assert_success
    assert_output --partial "DRY-RUN"

    local _output="${output}"
    local _apt_line _docker_line
    _apt_line="$(echo "${_output}" | grep -n 'apt-essentials' | head -1 | cut -d: -f1)"
    _docker_line="$(echo "${_output}" | grep -n -- '- docker' | head -1 | cut -d: -f1)"

    [[ -n "${_apt_line}"   ]]
    [[ -n "${_docker_line}" ]]
    [[ "${_apt_line}" -lt "${_docker_line}" ]]
}

@test "install docker --dry-run prints both modules in the action list" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" install docker --dry-run
    assert_success
    assert_output --partial "- apt-essentials"
    assert_output --partial "- docker"
}

@test "install apt-essentials --dry-run is a single-module action (no deps to pull)" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" install apt-essentials --dry-run
    assert_success
    assert_output --partial "- apt-essentials"
    refute_output --partial "- docker"
}

@test "install docker --no-deps --dry-run skips apt-essentials" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" install docker --no-deps --dry-run
    assert_success
    assert_output --partial "- docker"
    refute_output --partial "- apt-essentials"
}

# ── Negative paths ───────────────────────────────────────────────────────────

@test "install nonexistent --dry-run returns exit 2 (resolver unknown)" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" install nonexistent --dry-run
    assert_failure 2
}

@test "install with no module arg returns exit 2" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" install
    assert_failure 2
}

@test "unknown subcommand returns exit 2" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" this-does-not-exist
    assert_failure 2
}

# ── No side effects under --dry-run ──────────────────────────────────────────
# Intercept apt-get / sudo / curl / etc via PATH; if dry-run actually
# triggers any of them, we'll see the call in the log.

@test "install docker --dry-run does not invoke apt-get, sudo, or curl" {
    local _stubdir="${INIT_UBUNTU_TEST_SCRATCH}/stubs"
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/stub-calls.log"
    mkdir -p "${_stubdir}"
    : > "${_log}"

    local _bin
    for _bin in apt-get sudo curl gpg usermod tee lsb_release dpkg; do
        cat > "${_stubdir}/${_bin}" <<EOF
#!/usr/bin/env bash
echo "${_bin} called with: \$*" >> "${_log}"
exit 0
EOF
        chmod +x "${_stubdir}/${_bin}"
    done

    PATH="${_stubdir}:${PATH}" run bash "${REPO_ROOT}/setup_ubuntu.sh" install docker --dry-run
    assert_success
    assert_output --partial "DRY-RUN"

    if [[ -s "${_log}" ]]; then
        printf "Unexpected side-effect calls under --dry-run:\n%s\n" "$(cat "${_log}")" >&2
        return 1
    fi
}

# ── JSONL log file under --dry-run ───────────────────────────────────────────
# --dry-run short-circuits at the dispatcher BEFORE runner_install, so no
# log_event calls happen. The log file should not be written at all.

@test "install docker --dry-run does not write to INIT_UBUNTU_LOG_FILE" {
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/run.jsonl"
    INIT_UBUNTU_LOG_FILE="${_log}" run bash "${REPO_ROOT}/setup_ubuntu.sh" install docker --dry-run

    if [[ -s "${_log}" ]]; then
        printf "Unexpected JSONL emitted under --dry-run:\n%s\n" "$(cat "${_log}")" >&2
        return 1
    fi
}

# ── detect ──────────────────────────────────────────────────────────────────

@test "setup_ubuntu detect prints human-readable env summary" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" detect
    assert_success
    assert_output --partial "form_factor:"
    assert_output --partial "os.id:"
    assert_output --partial "arch:"
}

@test "setup_ubuntu detect --json includes form_factor inside JSON" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" detect --json
    assert_success
    assert_output --partial '"form_factor":'
    # Result should be parseable JSON.
    echo "${output}" | jq . > /dev/null
}

# ── status / export / import (M4) ────────────────────────────────────────────

@test "setup_ubuntu status is deprecated and forwards to list --installed" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" status
    assert_success
    assert_output --partial "deprecated"
    assert_output --partial "no modules"
}

@test "setup_ubuntu status --json forwards; stdout stays valid JSON" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" status --json
    assert_success
    assert_output --partial "deprecated"
    # Warning goes to stderr only — stdout must parse as state.json.
    bash "${REPO_ROOT}/setup_ubuntu.sh" status --json 2>/dev/null \
        | jq -e '(.version == "0.1.0") and (.installed | length == 0)' > /dev/null
}

@test "setup_ubuntu list --installed with empty state says 'no modules'" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" list --installed
    assert_success
    refute_output --partial "deprecated"
    assert_output --partial "no modules"
}

@test "setup_ubuntu export <file> writes a valid payload" {
    local _out="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    run bash "${REPO_ROOT}/setup_ubuntu.sh" export "${_out}"
    assert_success
    [[ -f "${_out}" ]]
    jq -r '.version' "${_out}" | grep -qE '^0\.'
    jq -e '.modules | type == "array"' "${_out}" > /dev/null
}

@test "setup_ubuntu export with empty state emits empty modules list" {
    local _out="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    bash "${REPO_ROOT}/setup_ubuntu.sh" export "${_out}"
    run jq -r '.modules | length' "${_out}"
    assert_success
    assert_output "0"
}

@test "setup_ubuntu export --modules filters to requested list" {
    # Seed state.json directly via the lib (faster than running real installs).
    # shellcheck source=../../lib/state.sh
    source "${LIB_DIR}/state.sh"
    state_record_install docker true
    state_record_install neovim true
    state_record_install fzf false

    local _out="${INIT_UBUNTU_TEST_SCRATCH}/payload.json"
    run bash "${REPO_ROOT}/setup_ubuntu.sh" export "${_out}" --modules=docker,fzf
    assert_success
    run jq -r '.modules | length' "${_out}"
    assert_output "2"
    run jq -r '.modules[].name' "${_out}"
    [[ "${lines[0]}" == "docker" ]]
    [[ "${lines[1]}" == "fzf" ]]
}

@test "setup_ubuntu import <file> defaults to dry-run: prints plan without writing" {
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    cat > "${_payload}" <<'EOF'
{
  "version": "0.2.0",
  "modules": [{"name":"docker","synced":{"manual":true,"version_provided":"v28.0.0"}}]
}
EOF
    # No --apply: conflict pipeline prints the plan and writes nothing
    # (ADR-0013 dry-run default).
    run bash "${REPO_ROOT}/setup_ubuntu.sh" import "${_payload}"
    assert_success
    assert_output --partial "docker"
    assert_output --partial "install"
    assert_output --partial "--apply"
    # state.json should still report 0 installed.
    local _state="${INIT_UBUNTU_STATE_DIR}/state.json"
    run jq -r '.installed | length' "${_state}"
    assert_success
    assert_output "0"
}

@test "setup_ubuntu import rejects payload missing version" {
    local _payload="${INIT_UBUNTU_TEST_SCRATCH}/in.json"
    echo '{"modules":[]}' > "${_payload}"
    run bash "${REPO_ROOT}/setup_ubuntu.sh" import "${_payload}"
    assert_failure 2
    assert_output --partial "version"
}

# ── M5: search / upgrade / doctor / config / sync ───────────────────────────

@test "setup_ubuntu update is removed: exit 2 with self-upgrade hint (Q40)" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" update
    assert_failure 2
    assert_output --partial "unknown subcommand"
    assert_output --partial "self-upgrade"
}

@test "setup_ubuntu search docker finds the docker module" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" search docker
    assert_success
    assert_output --partial "docker"
}

@test "setup_ubuntu search nonexistent reports no match" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" search zzznonsense
    assert_success
    assert_output --partial "no module matches"
}

@test "setup_ubuntu upgrade with no installed modules is a no-op" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" upgrade
    assert_success
    assert_output --partial "nothing recorded"
}

@test "setup_ubuntu upgrade <module> --dry-run prints the action list" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" upgrade docker --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
    assert_output --partial "- docker"
}

@test "setup_ubuntu doctor with empty state reports consistency" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" doctor
    assert_success
    assert_output --partial "consistent"
}

@test "setup_ubuntu config set ui.lang writes the value" {
    bash "${REPO_ROOT}/setup_ubuntu.sh" config set ui.lang zh-TW
    run bash "${REPO_ROOT}/setup_ubuntu.sh" config get ui.lang
    assert_success
    assert_output "zh-TW"
}

@test "setup_ubuntu config show --json prints structured config" {
    bash "${REPO_ROOT}/setup_ubuntu.sh" config set ui.lang zh-TW
    run bash "${REPO_ROOT}/setup_ubuntu.sh" config show --json
    assert_success
    echo "${output}" | jq -e '.ui.lang == "zh-TW"' > /dev/null
}

@test "setup_ubuntu config load is removed: exit 2 (Q38)" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" config load
    assert_failure 2
    assert_output --partial "unknown config action"
}

@test "setup_ubuntu config unset removes the key" {
    bash "${REPO_ROOT}/setup_ubuntu.sh" config set ui.lang en
    bash "${REPO_ROOT}/setup_ubuntu.sh" config unset ui.lang
    run bash "${REPO_ROOT}/setup_ubuntu.sh" config get ui.lang
    assert_success
    assert_output ""
}

@test "setup_ubuntu sync without target returns exit 2" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" sync
    assert_failure 2
}

@test "setup_ubuntu sync user@host --dry-run does not call ssh" {
    # Provide PATH-stubs but they should not be invoked.
    local _stubdir="${INIT_UBUNTU_TEST_SCRATCH}/stubs"
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/stub.log"
    mkdir -p "${_stubdir}"; : > "${_log}"
    for b in ssh scp; do
        cat > "${_stubdir}/${b}" <<EOF
#!/usr/bin/env bash
echo "${b} CALLED" >> "${_log}"
exit 0
EOF
        chmod +x "${_stubdir}/${b}"
    done
    PATH="${_stubdir}:${PATH}" run bash "${REPO_ROOT}/setup_ubuntu.sh" sync user@host --dry-run
    assert_success
    [[ ! -s "${_log}" ]]
}

# ── AC-16: ANSI color auto-off when piped (PRD §7.5, issue #45) ──────────────

@test "AC-16: setup_ubuntu list | cat emits no ANSI escapes" {
    run bash -c "bash '${REPO_ROOT}/setup_ubuntu.sh' list | cat"
    assert_success
    [[ "${output}" != *$'\033'* ]]
}

@test "setup_ubuntu --color=always forces ANSI escapes even when piped" {
    export LOG_LEVEL=INFO
    unset LOG_COLOR
    run bash -c "bash '${REPO_ROOT}/setup_ubuntu.sh' --color=always verify docker --dry-run | cat"
    assert_success
    [[ "${output}" == *$'\033'* ]]
}

@test "setup_ubuntu --color=never keeps output free of ANSI escapes" {
    export LOG_LEVEL=INFO
    unset LOG_COLOR
    run bash -c "bash '${REPO_ROOT}/setup_ubuntu.sh' --color=never verify docker --dry-run | cat"
    assert_success
    [[ "${output}" != *$'\033'* ]]
}

@test "setup_ubuntu --quiet list suppresses info-level log lines" {
    run bash "${REPO_ROOT}/setup_ubuntu.sh" --quiet verify docker --dry-run
    assert_success
    [[ "${output}" != *"[INFO]"* ]]
}
