#!/usr/bin/env bats
# test/unit/module/tmuxp_spec.bats — module/tmuxp.module.sh
#
# Per Q29: smoke / metadata / lifecycle dry-run / no-side-fx / idempotency /
# standalone CLI / module-specific (custom archetype: user-level pipx install,
# apt->pipx migration, Sidecar lifecycle ADR-0001). Issue #313.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
}

teardown() {
    teardown_test_env
}

_load_module() {
    # shellcheck source=../../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../../lib/general.sh
    source "${LIB_DIR}/general.sh"
    # shellcheck source=../../../lib/module_helper.sh
    source "${LIB_DIR}/module_helper.sh"
    # shellcheck source=../../../module/tmuxp.module.sh
    source "${MODULE_DIR}/tmuxp.module.sh"
}

# _standalone_module runs the module as a self-contained CLI (the same entry
# users hit when they type `bash module/tmuxp.module.sh ...`).
_standalone_module() {
    bash "${MODULE_DIR}/tmuxp.module.sh" "$@"
}

# ── Controllable mocks ───────────────────────────────────────────────────────
# Each shadowed function is defined exactly once and parameterized via MOCK_*
# variables, so every definition stays reachable for the linter (avoids SC2317
# without disable directives).

# pipx seam mock: records argv into MOCK_PIPX_LOG (one line per call). `list`
# emits MOCK_PIPX_LIST (used by is_installed via `list --short`); every other
# subcommand returns MOCK_PIPX_RC.
_mock_pipx() {
    MOCK_PIPX_LOG="${INIT_UBUNTU_TEST_SCRATCH}/pipx.log"
    : > "${MOCK_PIPX_LOG}"
    _tmuxp_pipx() {
        printf '%s\n' "$*" >> "${MOCK_PIPX_LOG}"
        case "${1:-}" in
            list) printf '%s\n' "${MOCK_PIPX_LIST:-}" ;;
            *)    return "${MOCK_PIPX_RC:-0}" ;;
        esac
    }
}

# sudo seam mock: records the apt argv into MOCK_SUDO_LOG. MOCK_HAVE_SUDO_RC
# controls have_sudo_access; MOCK_SUDO_RC the exit code of the apt call.
_mock_sudo() {
    MOCK_SUDO_LOG="${INIT_UBUNTU_TEST_SCRATCH}/sudo.log"
    : > "${MOCK_SUDO_LOG}"
    have_sudo_access() { return "${MOCK_HAVE_SUDO_RC:-0}"; }
    _tmuxp_sudo() {
        printf '%s\n' "$*" >> "${MOCK_SUDO_LOG}"
        return "${MOCK_SUDO_RC:-0}"
    }
}

# Put a fake executable on PATH so `command -v <name>` succeeds.
_fake_bin() {
    local _name="${1:?bin name required}"
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/bin/sh\nexit 0\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/${_name}"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/${_name}"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}"
}

# Fake dpkg-query reporting tmuxp as apt-installed (drives the migration path).
_fake_dpkg_installed() {
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    cat > "${INIT_UBUNTU_TEST_SCRATCH}/bin/dpkg-query" <<'EOF'
#!/bin/sh
echo "install ok installed"
EOF
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/dpkg-query"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}"
}

# Fake tmuxp binary answering --version.
_fake_tmuxp_bin() {
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/usr/bin/env bash\nprintf "tmuxp 1.55.0, libtmux 0.46.2\\n"\n' \
        > "${INIT_UBUNTU_TEST_SCRATCH}/bin/tmuxp"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/tmuxp"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}"
}

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "tmuxp module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/tmuxp.module.sh"
    assert_success
}

@test "tmuxp module sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "tmuxp module defines all 10 lifecycle functions" {
    _load_module
    local _fn
    for _fn in detect is_recommended is_installed install upgrade \
               remove purge verify is_outdated doctor; do
        declare -F "${_fn}" >/dev/null || {
            printf 'missing lifecycle function: %s\n' "${_fn}" >&2
            return 1
        }
    done
}

# ── Metadata sanity ──────────────────────────────────────────────────────────

@test "tmuxp module declares NAME=tmuxp" {
    _load_module
    [[ "${NAME}" == "tmuxp" ]]
}

@test "tmuxp module CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "tmuxp module TAGS contains terminal" {
    _load_module
    [[ " ${TAGS[*]} " == *" terminal "* ]]
}

@test "tmuxp module DEPENDS_ON contains tmux" {
    _load_module
    [[ " ${DEPENDS_ON[*]} " == *" tmux "* ]]
}

@test "tmuxp DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "tmuxp module_get_description returns language-specific text" {
    _load_module
    [[ "$(module_get_description en)" == *"tmux"* ]]
    [[ -n "$(module_get_description zh-TW)" ]]
    # Unknown language falls back to en.
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "tmuxp module VERSION_PROVIDED=pipx-managed" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "pipx-managed" ]]
}

@test "tmuxp module INSTALL_TARGET_DEFAULT=user-home (pipx is user-level)" {
    _load_module
    [[ "${INSTALL_TARGET_DEFAULT}" == "user-home" ]]
}

@test "tmuxp module SUPPORTS_USER_HOME=true" {
    _load_module
    [[ "${SUPPORTS_USER_HOME}" == "true" ]]
}

@test "tmuxp module RISK_LEVEL=low" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
}

@test "tmuxp HOMEPAGE points at the tmux-python/tmuxp project" {
    _load_module
    [[ "${HOMEPAGE}" == *"tmux-python/tmuxp"* ]]
}

@test "tmuxp POST_INSTALL_MESSAGE mentions pipx / PATH" {
    _load_module
    [[ "$(module_get_post_install_message en)" == *"pipx"* ]]
    [[ -n "$(module_get_post_install_message zh-TW)" ]]
}

@test "TEST_VERIFY_CMD exercises the tmuxp binary" {
    _load_module
    [[ "${TEST_VERIFY_CMD}" == *"tmuxp"* ]]
}

# ── is_installed: pipx ownership ─────────────────────────────────────────────

@test "is_installed returns zero when pipx list shows tmuxp" {
    _load_module
    MOCK_PIPX_LIST="tmuxp 1.55.0"
    _mock_pipx
    run is_installed
    assert_success
}

@test "is_installed returns nonzero when pipx list is empty (apt-only or none)" {
    _load_module
    MOCK_PIPX_LIST=""
    _mock_pipx
    run is_installed
    assert_failure
}

@test "is_installed ignores an unrelated pipx package" {
    _load_module
    MOCK_PIPX_LIST="some-other-pkg 2.0.0"
    _mock_pipx
    run is_installed
    assert_failure
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

@test "verify in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run verify
    assert_success
    assert_output --partial "DRY-RUN"
}

# ── No side effects under dry-run ────────────────────────────────────────────

@test "dry-run install writes nothing under the state dir" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/tmuxp" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
}

@test "dry-run install never shells out to pipx or sudo" {
    _load_module
    _mock_pipx
    _mock_sudo
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ ! -s "${MOCK_PIPX_LOG}" ]]
    [[ ! -s "${MOCK_SUDO_LOG}" ]]
}

@test "standalone dry-run install creates no files in a scratch HOME" {
    local _home="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${_home}"
    HOME="${_home}" XDG_STATE_HOME="${_home}/.local/state" \
        run _standalone_module install --dry-run
    assert_success
    local _leftover
    _leftover="$(find "${_home}" -mindepth 1 2>/dev/null)"
    [[ -z "${_leftover}" ]]
}

# ── install: pipx path + apt migration (custom archetype core) ──────────────

@test "install runs pipx install tmuxp when nothing is apt-owned" {
    _load_module
    _fake_bin pipx
    MOCK_PIPX_LIST=""
    _mock_pipx
    _mock_sudo
    install
    grep -q 'install tmuxp' "${MOCK_PIPX_LOG}"
    # No apt package was owned, so no apt removal happened.
    [[ ! -s "${MOCK_SUDO_LOG}" ]]
}

@test "install migrates away from an apt-managed tmuxp before pipx install" {
    _load_module
    _fake_dpkg_installed
    _fake_bin pipx
    MOCK_PIPX_LIST=""
    _mock_pipx
    _mock_sudo
    install
    grep -q 'apt-get remove -y tmuxp python3-libtmux' "${MOCK_SUDO_LOG}"
    grep -q 'install tmuxp' "${MOCK_PIPX_LOG}"
}

@test "install skips migration when apt-owned but no sudo (pipx shadows it)" {
    _load_module
    _fake_dpkg_installed
    _fake_bin pipx
    MOCK_PIPX_LIST=""
    MOCK_HAVE_SUDO_RC=1
    _mock_pipx
    _mock_sudo
    run install
    assert_success
    [[ ! -s "${MOCK_SUDO_LOG}" ]]
    grep -q 'install tmuxp' "${MOCK_PIPX_LOG}"
    assert_output --partial "no sudo"
}

@test "install skips when already pipx-managed (idempotent fast path)" {
    _load_module
    MOCK_PIPX_LIST="tmuxp 1.55.0"
    _mock_pipx
    _mock_sudo
    run install
    assert_success
    assert_output --partial "already installed"
    # is_installed logs a `list --short` probe, but no install call happened.
    run grep -q 'install tmuxp' "${MOCK_PIPX_LOG}"
    assert_failure
}

@test "install apt-installs pipx when pipx is missing" {
    _load_module
    MOCK_PIPX_LIST=""
    _mock_pipx
    _mock_sudo
    # No pipx binary on PATH: ensure_pipx must apt-install it.
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin:${PATH}" install
    grep -q 'apt-get install -y pipx' "${MOCK_SUDO_LOG}"
}

@test "failed pipx install propagates the failure" {
    _load_module
    _fake_bin pipx
    MOCK_PIPX_LIST=""
    MOCK_PIPX_RC=1
    _mock_pipx
    _mock_sudo
    run install
    assert_failure
}

# ── Sidecar lifecycle (ADR-0001) ─────────────────────────────────────────────

@test "install writes the sidecar with the tmuxp-reported version" {
    _load_module
    _fake_bin pipx
    _fake_tmuxp_bin
    MOCK_PIPX_LIST=""
    _mock_pipx
    _mock_sudo
    module_standalone_main install
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/tmuxp" ]]
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/tmuxp")" == "1.55.0" ]]
}

@test "install sidecar falls back to pipx-managed when tmuxp --version is absent" {
    _load_module
    _fake_bin pipx
    MOCK_PIPX_LIST=""
    _mock_pipx
    _mock_sudo
    # No tmuxp binary on PATH -> _tmuxp_version falls back.
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin:${PATH}" module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/tmuxp")" == "pipx-managed" ]]
}

@test "install never touches state.json (ADR-0001 / AC-23 pattern)" {
    _load_module
    printf '{"schema_version":"0.1.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    _fake_bin pipx
    _fake_tmuxp_bin
    MOCK_PIPX_LIST=""
    _mock_pipx
    _mock_sudo
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "failed install leaves no sidecar (ADR-0015)" {
    _load_module
    _fake_bin pipx
    MOCK_PIPX_LIST=""
    MOCK_PIPX_RC=1
    _mock_pipx
    _mock_sudo
    run module_standalone_main install
    assert_failure
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/tmuxp" ]]
}

@test "remove deletes the sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.55.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/tmuxp"
    MOCK_PIPX_LIST="tmuxp 1.55.0"
    _mock_pipx
    module_standalone_main remove
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/tmuxp" ]]
    grep -q 'uninstall tmuxp' "${MOCK_PIPX_LOG}"
}

@test "purge uninstalls via pipx and deletes the sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.55.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/tmuxp"
    MOCK_PIPX_LIST="tmuxp 1.55.0"
    _mock_pipx
    module_standalone_main purge
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/tmuxp" ]]
    grep -q 'uninstall tmuxp' "${MOCK_PIPX_LOG}"
}

# ── upgrade / remove semantics ──────────────────────────────────────────────

@test "upgrade on a missing install falls through to install" {
    _load_module
    _fake_bin pipx
    MOCK_PIPX_LIST=""
    _mock_pipx
    _mock_sudo
    run upgrade
    assert_success
    grep -q 'install tmuxp' "${MOCK_PIPX_LOG}"
}

@test "upgrade uses pipx upgrade when already pipx-managed" {
    _load_module
    MOCK_PIPX_LIST="tmuxp 1.55.0"
    _mock_pipx
    run upgrade
    assert_success
    grep -q 'upgrade tmuxp' "${MOCK_PIPX_LOG}"
}

@test "remove uses pipx uninstall" {
    _load_module
    MOCK_PIPX_LIST="tmuxp 1.55.0"
    _mock_pipx
    run remove
    assert_success
    grep -q 'uninstall tmuxp' "${MOCK_PIPX_LOG}"
}

@test "remove on a not-installed tmuxp is a no-op" {
    _load_module
    MOCK_PIPX_LIST=""
    _mock_pipx
    run remove
    assert_success
    assert_output --partial "nothing to do"
}

# ── Idempotency (AC-5 pattern) ───────────────────────────────────────────────

@test "install twice exits 0 both times" {
    _load_module
    _fake_bin pipx
    MOCK_PIPX_LIST=""
    _mock_pipx
    _mock_sudo
    run install
    assert_success
    MOCK_PIPX_LIST="tmuxp 1.55.0"
    _mock_pipx
    run install
    assert_success
}

@test "remove is idempotent — second run still exits 0" {
    _load_module
    MOCK_PIPX_LIST="tmuxp 1.55.0"
    _mock_pipx
    run remove
    assert_success
    MOCK_PIPX_LIST=""
    _mock_pipx
    run remove
    assert_success
}

# ── verify / doctor / is_outdated ────────────────────────────────────────────

@test "verify fails when not installed" {
    _load_module
    MOCK_PIPX_LIST=""
    _mock_pipx
    run verify
    assert_failure
}

@test "verify passes when installed and TEST_VERIFY_CMD succeeds" {
    _load_module
    MOCK_PIPX_LIST="tmuxp 1.55.0"
    _mock_pipx
    TEST_VERIFY_CMD="true"
    run verify
    assert_success
}

@test "doctor fails when not installed" {
    _load_module
    MOCK_PIPX_LIST=""
    _mock_pipx
    run doctor
    assert_failure
}

@test "doctor passes when tmuxp answers --version" {
    _load_module
    MOCK_PIPX_LIST="tmuxp 1.55.0"
    _mock_pipx
    _fake_tmuxp_bin
    run doctor
    assert_success
}

@test "doctor fails when the tmuxp binary is not on PATH" {
    _load_module
    MOCK_PIPX_LIST="tmuxp 1.55.0"
    _mock_pipx
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin" run doctor
    assert_failure
}

@test "is_outdated returns nonzero (pipx upgrade is idempotent; no cheap probe)" {
    _load_module
    run is_outdated
    assert_failure
}

# ── is_recommended ───────────────────────────────────────────────────────────

@test "is_recommended is zero when not installed" {
    _load_module
    MOCK_PIPX_LIST=""
    _mock_pipx
    run is_recommended
    assert_success
}

@test "is_recommended is nonzero when already installed" {
    _load_module
    MOCK_PIPX_LIST="tmuxp 1.55.0"
    _mock_pipx
    run is_recommended
    assert_failure
}

# ── detect ───────────────────────────────────────────────────────────────────

@test "detect succeeds when apt-get is available" {
    _load_module
    _fake_bin apt-get
    run detect
    assert_success
}

@test "detect fails without apt-get on PATH" {
    _load_module
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin" run detect
    assert_failure
}

# ── Dual-mode standalone CLI ─────────────────────────────────────────────────

@test "standalone: with no args prints usage + exits 2" {
    run _standalone_module
    assert_failure 2
    assert_output --partial "Usage:"
}

@test "standalone: --help shows phases" {
    run _standalone_module --help
    assert_success
    assert_output --partial "install"
    assert_output --partial "remove"
    assert_output --partial "purge"
}

@test "standalone: --version prints NAME + VERSION_PROVIDED" {
    run _standalone_module --version
    assert_success
    assert_output --partial "tmuxp"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module nope
    assert_failure 2
}

@test "standalone: info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        tmuxp"
    assert_output --partial "category:    optional"
    assert_output --partial "terminal"
}

@test "standalone: info --lang=zh-TW prints localized description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "管理器"
}

@test "standalone: status reports installed + outdated fields" {
    run _standalone_module status
    assert_success
    assert_output --partial "installed:"
    assert_output --partial "outdated:"
}

# ── AC-25: all 10 phases runnable, never "not implemented" exit 2 ────────────

@test "standalone: install --dry-run exits 0 with DRY-RUN output" {
    run _standalone_module install --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "standalone: upgrade --dry-run exits 0" {
    run _standalone_module upgrade --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "standalone: remove --dry-run exits 0" {
    run _standalone_module remove --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "standalone: purge --dry-run exits 0" {
    run _standalone_module purge --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "standalone: verify --dry-run exits 0" {
    run _standalone_module verify --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "standalone: detect is implemented (exit != 2)" {
    run _standalone_module detect
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: is-installed is implemented (exit != 2)" {
    # Fake pipx on PATH: the test container has no pipx, and a bare
    # command-not-found (127) would trip bats' BW01 warning.
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/bin/sh\nexit 0\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/pipx"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/pipx"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run _standalone_module is-installed
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: is-recommended is implemented (exit != 2)" {
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/bin/sh\nexit 0\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/pipx"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/pipx"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run _standalone_module is-recommended
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: is-outdated is implemented (exit != 2)" {
    run _standalone_module is-outdated
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}

@test "standalone: doctor is implemented (exit != 2)" {
    run _standalone_module doctor
    [[ "${status}" -ne 2 ]]
    refute_output --partial "not implemented"
}
