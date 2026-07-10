#!/usr/bin/env bats
# test/unit/module/trash-maintenance_spec.bats — module/trash-maintenance.module.sh
#
# Promotes the legacy tool/trash-maintenance.sh to a v2 custom (archetype D)
# module. Coverage per Q29 + doc/module-spec.md §7:
#   smoke / metadata / lifecycle dry-run / no-side-fx / idempotency /
#   standalone CLI / module-specific.
#
# Module-specific behaviour splits into two layers:
#   1. The MODULE (schedule + GNOME toggle) — the gsettings / cron effects
#      are desktop/host-only and NOT Docker-testable, so we assert the module
#      CONTAINS the right commands (config-content precedent) + exercises the
#      cron seam against a stubbed `crontab`.
#   2. The shipped SCRIPT (module/config/trash-maintenance/trash-maintenance.sh)
#      is pure cleanup logic and IS Docker-testable: we run it with PATH stubs
#      for `du` / `trash-empty` and assert issue #277's three fixes
#      (drop `-f`, harden `current_kb` against partial `du` failure, default
#      MAX_GB=30).

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false

    # Scratch HOME so every HOME-derived path (deployed script, log, Trash
    # dir) lands inside the per-test sandbox.
    TEST_HOME="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${TEST_HOME}/.local/bin" "${TEST_HOME}/.local/state"
    export TEST_HOME

    # PATH stub dir for shipped-script behavioural tests.
    STUB_BIN="${INIT_UBUNTU_TEST_SCRATCH}/stubbin"
    mkdir -p "${STUB_BIN}"
    export STUB_BIN

    SCRIPT_SRC="${MODULE_DIR}/config/trash-maintenance/trash-maintenance.sh"
    export SCRIPT_SRC
}

teardown() {
    teardown_test_env
}

# Engine-mode load: source the module with HOME pointed at the scratch dir so
# the HOME-derived path vars (computed at source time) stay in the sandbox.
_load_module() {
    export HOME="${TEST_HOME}"
    # shellcheck source=../../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../../lib/general.sh
    source "${LIB_DIR}/general.sh"
    # shellcheck source=../../../lib/module_helper.sh
    source "${LIB_DIR}/module_helper.sh"
    # shellcheck source=../../../module/trash-maintenance.module.sh
    source "${MODULE_DIR}/trash-maintenance.module.sh"
}

_standalone_module() {
    HOME="${TEST_HOME}" XDG_STATE_HOME="${TEST_HOME}/.local/state" \
        bash "${MODULE_DIR}/trash-maintenance.module.sh" "$@"
}

# Fake `crontab` bound to a per-test spool file so the cron seam is
# exercised without touching the container's real crontab.
_mock_crontab() {
    CRON_SPOOL="${INIT_UBUNTU_TEST_SCRATCH}/cron.spool"
    export CRON_SPOOL
    crontab() {
        case "${1:-}" in
            -l) [[ -f "${CRON_SPOOL}" ]] && cat "${CRON_SPOOL}"; [[ -f "${CRON_SPOOL}" ]] ;;
            -r) rm -f "${CRON_SPOOL}" ;;
            -)  cat > "${CRON_SPOOL}" ;;
            *)  return 2 ;;
        esac
    }
    export -f crontab
}

# ── Shipped-script harness ───────────────────────────────────────────────────

# Seed a scratch HOME Trash dir with N info/files pairs.
_seed_trash() {
    local _n="${1:-0}"
    mkdir -p "${TEST_HOME}/.local/share/Trash/files" \
             "${TEST_HOME}/.local/share/Trash/info"
    local _i
    for (( _i = 0; _i < _n; _i++ )); do
        printf 'data\n' > "${TEST_HOME}/.local/share/Trash/files/item${_i}"
        printf '[Trash Info]\n' > "${TEST_HOME}/.local/share/Trash/info/item${_i}.trashinfo"
    done
}

# Install a `trash-empty` stub that records its args.
_stub_trash_empty() {
    cat > "${STUB_BIN}/trash-empty" <<EOF
#!/usr/bin/env bash
printf '%s' "\$*" > "${STUB_BIN}/trash-empty.args"
exit 0
EOF
    chmod +x "${STUB_BIN}/trash-empty"
}

# Install a `du` stub that prints <kb>\t<path> then exits with <rc>.
_stub_du() {
    local _kb="$1" _rc="${2:-0}"
    cat > "${STUB_BIN}/du" <<EOF
#!/usr/bin/env bash
printf '%s\t/fake\n' "${_kb}"
exit ${_rc}
EOF
    chmod +x "${STUB_BIN}/du"
}

# Run the shipped script with the stub bin dir prepended + scratch HOME.
_run_script() {
    run env PATH="${STUB_BIN}:${PATH}" HOME="${TEST_HOME}" "$@" \
        bash "${SCRIPT_SRC}"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "trash-maintenance module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/trash-maintenance.module.sh"
    assert_success
}

@test "trash-maintenance sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "trash-maintenance defines all 8 required lifecycle functions" {
    _load_module
    local _fn
    for _fn in detect is_recommended is_installed install upgrade \
               remove purge verify; do
        declare -F "${_fn}" >/dev/null || {
            printf 'missing lifecycle function: %s\n' "${_fn}" >&2
            return 1
        }
    done
}

# ── Metadata sanity ──────────────────────────────────────────────────────────

@test "trash-maintenance declares NAME matching the file prefix" {
    _load_module
    [[ "${NAME}" == "trash-maintenance" ]]
}

@test "trash-maintenance CATEGORY is a valid enum value" {
    _load_module
    [[ "${CATEGORY}" =~ ^(base|recommended|optional|experimental)$ ]]
}

@test "trash-maintenance DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "trash-maintenance module_get_description falls back to en for unknown lang" {
    _load_module
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "trash-maintenance SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "trash-maintenance is a no-sudo user-home tool" {
    _load_module
    [[ "${SUPPORTS_USER_HOME}" == "true" ]]
    [[ "${INSTALL_TARGET_DEFAULT}" == "user-home" ]]
}

# ── detect / is_recommended ──────────────────────────────────────────────────

@test "detect returns 0 on Ubuntu" {
    _load_module
    # eval so shellcheck does not run reachability analysis on the indirectly
    # dispatched mock (detect calls lsb_release) — avoids SC2317.
    eval 'lsb_release() { [[ "${1:-}" == "-is" ]] && printf "Ubuntu\n"; }'
    run detect
    assert_success
}

@test "detect returns nonzero on a non-Ubuntu distro" {
    _load_module
    eval 'lsb_release() { [[ "${1:-}" == "-is" ]] && printf "Debian\n"; }'
    run detect
    assert_failure
}

# ── is_installed ─────────────────────────────────────────────────────────────

@test "is_installed is nonzero before deployment (no script, no cron)" {
    _load_module
    _mock_crontab
    run is_installed
    assert_failure
}

@test "is_installed is zero once the script is deployed and cron is present" {
    _load_module
    _mock_crontab
    install --dry-run >/dev/null 2>&1 || true   # ensure vars resolved
    # Simulate a completed install: deploy the artifact + a cron marker line.
    cp "${SCRIPT_SRC}" "${TEST_HOME}/.local/bin/trash-maintenance.sh"
    chmod +x "${TEST_HOME}/.local/bin/trash-maintenance.sh"
    printf '0 3 * * * %s/.local/bin/trash-maintenance.sh # init_ubuntu:trash-maintenance\n' \
        "${TEST_HOME}" > "${CRON_SPOOL}"
    run is_installed
    assert_success
}

# ── Lifecycle dry-run (AC-12 pattern) ────────────────────────────────────────

@test "install in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "upgrade in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run upgrade
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

@test "dry-run install deploys no script and writes no cron" {
    _load_module
    _mock_crontab
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ ! -e "${TEST_HOME}/.local/bin/trash-maintenance.sh" ]]
    [[ ! -e "${CRON_SPOOL}" ]]
}

# ── install / remove / purge (mocked cron) ───────────────────────────────────

@test "install deploys the script, writes the cron entry, exits 0" {
    _load_module
    _mock_crontab
    run install
    assert_success
    [[ -x "${TEST_HOME}/.local/bin/trash-maintenance.sh" ]]
    run cat "${CRON_SPOOL}"
    assert_output --partial "init_ubuntu:trash-maintenance"
    assert_output --partial "trash-maintenance.sh"
}

@test "install is idempotent — second run still exits 0, single cron entry" {
    _load_module
    _mock_crontab
    run install
    assert_success
    run install
    assert_success
    run grep -c "init_ubuntu:trash-maintenance" "${CRON_SPOOL}"
    assert_output "1"
}

@test "remove strips the cron entry and deletes the deployed script" {
    _load_module
    _mock_crontab
    install
    [[ -x "${TEST_HOME}/.local/bin/trash-maintenance.sh" ]]
    run remove
    assert_success
    [[ ! -e "${TEST_HOME}/.local/bin/trash-maintenance.sh" ]]
    run cat "${CRON_SPOOL}"
    refute_output --partial "init_ubuntu:trash-maintenance"
}

@test "remove is idempotent — second run still exits 0" {
    _load_module
    _mock_crontab
    install
    run remove
    assert_success
    run remove
    assert_success
}

@test "install preserves unrelated crontab lines" {
    _load_module
    _mock_crontab
    printf '30 2 * * * /usr/bin/backup.sh\n' > "${CRON_SPOOL}"
    install
    run cat "${CRON_SPOOL}"
    assert_output --partial "/usr/bin/backup.sh"
    assert_output --partial "init_ubuntu:trash-maintenance"
}

@test "remove preserves unrelated crontab lines" {
    _load_module
    _mock_crontab
    printf '30 2 * * * /usr/bin/backup.sh\n' > "${CRON_SPOOL}"
    install
    remove
    run cat "${CRON_SPOOL}"
    assert_output --partial "/usr/bin/backup.sh"
    refute_output --partial "init_ubuntu:trash-maintenance"
}

@test "purge deletes the script, cron entry, and log" {
    _load_module
    _mock_crontab
    install
    printf 'log line\n' > "${TEST_HOME}/.local/state/trash-maintenance.log"
    run purge
    assert_success
    [[ ! -e "${TEST_HOME}/.local/bin/trash-maintenance.sh" ]]
    [[ ! -e "${TEST_HOME}/.local/state/trash-maintenance.log" ]]
}

@test "purge is idempotent on a clean host (nothing installed)" {
    _load_module
    _mock_crontab
    run purge
    assert_success
    run purge
    assert_success
}

# ── #275: GNOME own trash auto-delete is disabled, single source of truth ─────

@test "module targets the GNOME remove-old-trash-files privacy key (issue #275)" {
    _load_module
    [[ "${TRASH_MAINT_GNOME_SCHEMA}" == "org.gnome.desktop.privacy" ]]
    [[ "${TRASH_MAINT_GNOME_KEY}" == "remove-old-trash-files" ]]
}

@test "module install path sets the GNOME key to false (issue #275)" {
    _load_module
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/gsettings.log"
    # eval so shellcheck skips reachability analysis of the indirect mocks.
    eval '_trash_maint_gnome_available() { return 0; }'
    eval "gsettings() { printf '%s\n' \"\$*\" >> '${_log}'; }"
    _trash_maint_disable_gnome_autodelete
    run cat "${_log}"
    assert_output --partial "set org.gnome.desktop.privacy remove-old-trash-files false"
}

@test "module remove/purge resets the GNOME key back to default (issue #275)" {
    _load_module
    local _log="${INIT_UBUNTU_TEST_SCRATCH}/gsettings.log"
    eval '_trash_maint_gnome_available() { return 0; }'
    eval "gsettings() { printf '%s\n' \"\$*\" >> '${_log}'; }"
    _trash_maint_reset_gnome_autodelete
    run cat "${_log}"
    assert_output --partial "reset org.gnome.desktop.privacy remove-old-trash-files"
}

@test "module never sets old-files-age (issue #275 drops it)" {
    run grep -F "old-files-age" "${MODULE_DIR}/trash-maintenance.module.sh"
    assert_failure
}

@test "gsettings_config no longer runs a trash-privacy gsettings set (issue #275)" {
    # Only the executable `gsettings set ...privacy...` lines matter; the
    # explanatory comment is allowed to name the keys.
    run grep -E '^[[:space:]]*gsettings set org\.gnome\.desktop\.privacy (remove-old-trash-files|old-files-age)' \
        "${MODULE_DIR}/config/gsettings_config"
    assert_failure
}

# ── #277: shipped-script fixes (Docker-testable pure logic) ───────────────────

@test "shipped script exists and parses (bash -n)" {
    [[ -f "${SCRIPT_SRC}" ]]
    run bash -n "${SCRIPT_SRC}"
    assert_success
}

@test "#277 bug 1: shipped script never passes -f to trash-empty (source)" {
    run grep -F "trash-empty -f" "${SCRIPT_SRC}"
    assert_failure
}

@test "#277 bug 1: shipped script invokes trash-empty with just the day count" {
    _seed_trash 0
    _stub_trash_empty
    _stub_du 4 0
    _run_script MAX_DAYS=90
    assert_success
    run cat "${STUB_BIN}/trash-empty.args"
    assert_output "90"
    refute_output --partial "-f"
}

@test "#277 bug 2: a partial (non-zero) du does NOT abort before the size check" {
    _seed_trash 0
    _stub_trash_empty
    # du prints 1 GB worth of KB but exits 1 (permission-denied simulation).
    _stub_du 1048576 1
    _run_script
    assert_success
    assert_output --partial "Current trash size"
    assert_output --partial "Under cap"
}

@test "#277 cap default is 30G: 31 GB trips 'Over cap' against a 30 GB cap" {
    _seed_trash 2
    _stub_trash_empty
    _stub_du 32505856 0    # 31 GiB in KB
    _run_script
    assert_success
    assert_output --partial "cap: 30 GB"
    assert_output --partial "Over cap"
}

@test "#277 cap default is 30G: 29 GB stays 'Under cap'" {
    _seed_trash 0
    _stub_trash_empty
    _stub_du 30408704 0    # 29 GiB in KB
    _run_script
    assert_success
    assert_output --partial "cap: 30 GB"
    assert_output --partial "Under cap"
}

@test "#277 MAX_GB override still honoured (env beats the 30 default)" {
    _seed_trash 0
    _stub_trash_empty
    _stub_du 4 0
    _run_script MAX_GB=10
    assert_success
    assert_output --partial "cap: 10 GB"
}

# ── Standalone CLI ───────────────────────────────────────────────────────────

@test "standalone --help exits 0" {
    run _standalone_module --help
    assert_success
}

@test "standalone --version exits 0 and prints NAME + version" {
    run _standalone_module --version
    assert_success
    assert_output --partial "trash-maintenance"
}

@test "standalone unknown phase exits 2" {
    run _standalone_module bogus-phase
    assert_equal "$status" 2
}

@test "standalone info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "trash-maintenance"
}

@test "standalone info --lang=zh-TW renders the zh-TW description" {
    _load_module
    local _zh="${DESCRIPTION[zh-TW]}"
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "${_zh}"
}

@test "sourcing the module does not trigger the standalone footer" {
    # If the footer fired on source, module_standalone_main would consume our
    # bogus args and exit 2; sourcing must stay silent.
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}
