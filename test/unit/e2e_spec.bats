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

load "${BATS_TEST_DIRNAME}/../helpers/common"

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
