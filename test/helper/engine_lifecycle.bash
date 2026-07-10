#!/usr/bin/env bash
# test/helper/engine_lifecycle.bash — helpers for the real engine-lifecycle
# integration harness (issue #175 / #176).
#
# The keystone gap (#174): NO test drove the REAL non-dry-run path
#   setup_ubuntu.sh → dispatcher → runner → source module → archetype macro
#   → lifecycle fn
# All install tests were either --dry-run (dispatcher plan-only, never reaches
# the runner) or used the unit `_load_engine` helper that pre-sources
# module_helper.sh (masking entrypoint omissions). This helper provisions the
# one ingredient those couldn't: a NON-ROOT user driving the real entrypoint,
# with ONLY the github-release network boundary stubbed (offline/deterministic
# via the INIT_UBUNTU_TEST_GH_* seams in lib/module_helper.sh).
#
# Hard constraint (ADR / PRD §10): the dispatcher install/upgrade/remove path
# REFUSES EUID 0. The CI/test container runs as root, so a real install MUST
# run as a freshly-created non-root user. Provided here so each spec doesn't
# re-roll user creation + chown.

# Name of the throwaway non-root user created in-container.
ENGINE_LT_USER="lifecycle"

# engine_lt_require_root — the harness can only create a user + drive the
# root-refusing install path when bats itself runs as root (the test-tools
# container default). Skip cleanly elsewhere (e.g. a dev running rootless).
engine_lt_require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] \
        || skip "engine-lifecycle harness needs root (to create a non-root user); EUID=${EUID:-?}"
}

# engine_lt_setup_user — create the non-root user (idempotent across files in
# one container) and a per-test scratch tree owned by it. Exports:
#   ENGINE_LT_SCRATCH   per-test scratch root (under $BATS_TEST_TMPDIR)
#   ENGINE_LT_HOME      scratch HOME for the non-root user
#   ENGINE_LT_STATE     INIT_UBUNTU_STATE_DIR
#   ENGINE_LT_CONFIG    INIT_UBUNTU_CONFIG_DIR
#   ENGINE_LT_FIXTURE   github-release fixture dir
#   ENGINE_LT_BACKUP    BACKUP_DIR (upgrade paths back up the old payload)
engine_lt_setup_user() {
    # alpine/busybox: adduser -D = no password; -h sets home. Idempotent.
    id "${ENGINE_LT_USER}" >/dev/null 2>&1 \
        || adduser -D -s /bin/bash "${ENGINE_LT_USER}" >/dev/null 2>&1 \
        || useradd -m -s /bin/bash "${ENGINE_LT_USER}" >/dev/null 2>&1 || true

    ENGINE_LT_SCRATCH="${BATS_TEST_TMPDIR}/engine_lt"
    ENGINE_LT_HOME="${ENGINE_LT_SCRATCH}/home"
    ENGINE_LT_STATE="${ENGINE_LT_SCRATCH}/state"
    ENGINE_LT_CONFIG="${ENGINE_LT_SCRATCH}/config"
    ENGINE_LT_FIXTURE="${ENGINE_LT_SCRATCH}/fixture"
    ENGINE_LT_BACKUP="${ENGINE_LT_SCRATCH}/backup"
    mkdir -p "${ENGINE_LT_HOME}" "${ENGINE_LT_STATE}" "${ENGINE_LT_CONFIG}" \
             "${ENGINE_LT_FIXTURE}" "${ENGINE_LT_BACKUP}"

    # bats lays the scratch under /tmp/bats-run-XXXX/test/<n>/, every level
    # mode 0700 owned by the bats (root) user. The non-root user must be able
    # to TRAVERSE the whole chain to reach its scratch (state.json writes go
    # deep inside it). Open execute/traverse (o+x) on each ancestor from the
    # scratch up to — but not including — /tmp, then own the scratch subtree.
    local _p="${ENGINE_LT_SCRATCH}"
    while [[ "${_p}" != "/tmp" && "${_p}" != "/" && -n "${_p}" ]]; do
        chmod o+rx "${_p}" 2>/dev/null || true
        _p="$(dirname "${_p}")"
    done
    chown -R "${ENGINE_LT_USER}:${ENGINE_LT_USER}" "${ENGINE_LT_SCRATCH}"

    export ENGINE_LT_SCRATCH ENGINE_LT_HOME ENGINE_LT_STATE ENGINE_LT_CONFIG \
           ENGINE_LT_FIXTURE ENGINE_LT_BACKUP
}

# engine_lt_make_gh_fixture <asset-pattern> <bin-name> [version]
#   Stage a deterministic .tar.gz fixture for the github-release archetype,
#   matching the module's resolved GITHUB_ASSET_PATTERN exactly. The tarball
#   nests <bin> under a single top-level dir (STRIP_COMPONENTS=1 strips it,
#   mirroring real charmbracelet/gum tarballs). The fake binary prints a
#   version string so `<bin> --version` post-install assertions are meaningful.
engine_lt_make_gh_fixture() {
    local _asset="${1:?asset pattern}"
    local _bin="${2:?bin name}"
    local _ver="${3:-0.0.1}"
    # asset is <stem>.tar.gz; the tarball's single top dir reuses the stem.
    local _stem="${_asset%.tar.gz}"
    local _root="${ENGINE_LT_FIXTURE}/${_stem}"
    mkdir -p "${_root}"
    printf '#!/bin/sh\necho "%s version v%s"\n' "${_bin}" "${_ver}" > "${_root}/${_bin}"
    chmod +x "${_root}/${_bin}"
    ( cd "${ENGINE_LT_FIXTURE}" && tar -czf "${_asset}" "${_stem}" && rm -rf "${_stem}" )
    chown -R "${ENGINE_LT_USER}:${ENGINE_LT_USER}" "${ENGINE_LT_FIXTURE}"
}

# engine_lt_run <extra-env> <setup_ubuntu args...>
#   Drive the REAL setup_ubuntu.sh as the non-root user with the scratch
#   env wired. <extra-env> is a single string of KEY=VAL pairs (may be ""):
#   it is interpolated into the `su -c` command so per-call vars like
#   INIT_UBUNTU_TEST_GH_VERSION can vary. Populates bats $status/$output via
#   `run`, so callers use assert_success / assert_output as usual.
engine_lt_run() {
    local _extra="${1:-}"; shift
    local _base="HOME=${ENGINE_LT_HOME}"
    _base+=" INIT_UBUNTU_STATE_DIR=${ENGINE_LT_STATE}"
    _base+=" INIT_UBUNTU_CONFIG_DIR=${ENGINE_LT_CONFIG}"
    _base+=" BACKUP_DIR=${ENGINE_LT_BACKUP}"
    # SR-01: the offline github-release seam only activates under this flag.
    _base+=" INIT_UBUNTU_TEST_MODE=1"
    _base+=" LOG_COLOR=false LOG_LEVEL=INFO"
    run su "${ENGINE_LT_USER}" -c \
        "cd '${REPO_ROOT}' && ${_base} ${_extra} bash setup_ubuntu.sh ${*}"
}

# engine_lt_state_version <module> — print installed[<module>].synced
#   .version_provided from the scratch state.json (empty if absent).
engine_lt_state_version() {
    local _mod="${1:?module}"
    jq -r --arg m "${_mod}" \
        '.installed[$m].synced.version_provided // empty' \
        "${ENGINE_LT_STATE}/state.json" 2>/dev/null
}

# engine_lt_state_has <module> — 0 if installed[<module>] exists in state.json.
engine_lt_state_has() {
    local _mod="${1:?module}"
    jq -e --arg m "${_mod}" '.installed | has($m)' \
        "${ENGINE_LT_STATE}/state.json" >/dev/null 2>&1
}

# engine_lt_sidecar <module> — print the Sidecar version (empty if absent).
engine_lt_sidecar() {
    local _mod="${1:?module}"
    cat "${ENGINE_LT_STATE}/versions/${_mod}" 2>/dev/null
}

# engine_lt_assert_no_wiring_errors — fail if $output carries the #174 bug
# class signatures. Used by every archetype, including the reduced-level apt
# path where the install itself can't complete on the alpine harness but the
# archetype macro MUST still be wired in the real subprocess.
engine_lt_assert_no_wiring_errors() {
    refute_output --partial "command not found"
    refute_output --partial "module does not define"
    refute_output --partial "module_use_"
}
