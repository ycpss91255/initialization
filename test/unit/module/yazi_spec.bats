#!/usr/bin/env bats
# test/unit/module/yazi_spec.bats — module/yazi.module.sh (issue #60)
#
# Covers (Q29): smoke / metadata / lifecycle dry-run / no-side-fx /
# idempotency / Sidecar (ADR-0001) / standalone CLI (AC-25) / registry
# discovery / legacy #1 alias regression (alias must target yazi, not cat).

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    # Sandbox HOME so alias writes never touch the container user's rc files.
    TEST_HOME="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${TEST_HOME}"
    export TEST_HOME
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
    # shellcheck source=../../../module/yazi.module.sh
    source "${MODULE_DIR}/yazi.module.sh"
}

# ── Smoke: contract shape ────────────────────────────────────────────────────

@test "yazi module defines all 10 lifecycle functions" {
    _load_module
    local _fn
    for _fn in detect is_recommended is_installed install upgrade \
               remove purge verify is_outdated doctor; do
        declare -F "${_fn}" >/dev/null || {
            printf "missing lifecycle fn: %s\n" "${_fn}" >&2
            return 1
        }
    done
}

# ── Metadata sanity (PRD §9.1 / issue #60) ──────────────────────────────────

@test "yazi module declares NAME=yazi" {
    _load_module
    [[ "${NAME}" == "yazi" ]]
}

@test "yazi module CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "yazi module TAGS[0]=filemgr" {
    _load_module
    [[ "${TAGS[0]}" == "filemgr" ]]
}

@test "yazi module DEPENDS_ON is empty (Q39: module names only)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 0 ]]
}

@test "yazi documents glow as its markdown-preview dependency (issue #314)" {
    _load_module
    # glow stays an optional preview dep (not a hard DEPENDS_ON per Q39); it is
    # surfaced to the user in POST_INSTALL_MESSAGE so `yazi` markdown previews
    # can be enabled on demand via `setup_ubuntu install glow`.
    [[ "$(module_get_post_install_message en)" == *"glow"* ]]
    [[ "$(module_get_post_install_message zh-TW)" == *"glow"* ]]
    [[ -f "${MODULE_DIR}/glow.module.sh" ]]
}

@test "yazi DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "$(module_get_description en)" ]]
    [[ -n "$(module_get_description zh-TW)" ]]
}

@test "yazi POST_INSTALL_MESSAGE has en + zh-TW entries" {
    _load_module
    [[ -n "$(module_get_post_install_message en)" ]]
    [[ -n "$(module_get_post_install_message zh-TW)" ]]
}

@test "yazi module SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "yazi module SUPPORTED_PLATFORMS is non-empty" {
    _load_module
    [[ "${#SUPPORTED_PLATFORMS[@]}" -gt 0 ]]
}

@test "yazi module HOMEPAGE points at sxyazi/yazi" {
    _load_module
    [[ "${HOMEPAGE}" == *"github.com/sxyazi/yazi"* ]]
}

@test "yazi module VERSION_PROVIDED=latest" {
    _load_module
    [[ "${VERSION_PROVIDED}" == "latest" ]]
}

@test "yazi module RISK_LEVEL=low" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
}

@test "yazi module REBOOT_REQUIRED=false" {
    _load_module
    [[ "${REBOOT_REQUIRED}" == "false" ]]
}

@test "yazi module INSTALL_TARGET_DEFAULT=sudo" {
    _load_module
    [[ "${INSTALL_TARGET_DEFAULT}" == "sudo" ]]
}

@test "yazi module SUPPORTS_USER_HOME is a boolean" {
    _load_module
    [[ "${SUPPORTS_USER_HOME}" == "true" || "${SUPPORTS_USER_HOME}" == "false" ]]
}

@test "yazi archetype data points at sxyazi/yazi zip asset" {
    _load_module
    [[ "${GITHUB_REPO}" == "sxyazi/yazi" ]]
    [[ "${BIN_NAME}" == "yazi" ]]
    [[ "${GITHUB_ASSET_PATTERN}" == *".zip" ]]
}

@test "yazi module CONFLICTS_WITH is empty" {
    _load_module
    [[ "${#CONFLICTS_WITH[@]}" -eq 0 ]]
}

# Point every mutable path at the per-test scratch dir, neutralize sudo,
# and stub the zip fetch so install()/upgrade() run for real (alias +
# Sidecar) without downloading anything.
_sandbox_module() {
    HOME="${TEST_HOME}"
    INSTALL_DIR="${INIT_UBUNTU_TEST_SCRATCH}/opt/yazi"
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/bin/yazi"
    USE_SUDO=false
    _yazi_fetch_and_install() {
        mkdir -p "${INSTALL_DIR}" "${BIN_LINK%/*}"
        printf '#!/bin/sh\necho "Yazi 25.5.31 (test stub)"\n' > "${INSTALL_DIR}/yazi"
        chmod +x "${INSTALL_DIR}/yazi"
        ln -sfn "${INSTALL_DIR}/yazi" "${BIN_LINK}"
    }
}

_sidecar_path() {
    printf '%s/versions/yazi' "${INIT_UBUNTU_STATE_DIR}"
}

# Sandbox paths only (real _yazi_fetch_and_install stays in place) for the
# fetch-validation tests.
_sandbox_fetch_paths() {
    HOME="${TEST_HOME}"
    INSTALL_DIR="${INIT_UBUNTU_TEST_SCRATCH}/opt/yazi"
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/bin/yazi"
    USE_SUDO=false
}

# ── is_installed ─────────────────────────────────────────────────────────────

@test "is_installed returns nonzero on a fresh test container" {
    _load_module
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/no/such/yazi"
    run is_installed
    assert_failure
}

@test "is_installed returns 0 when BIN_LINK is an executable" {
    _load_module
    BIN_LINK="${INIT_UBUNTU_TEST_SCRATCH}/bin/yazi"
    mkdir -p "${BIN_LINK%/*}"
    printf '#!/bin/sh\n' > "${BIN_LINK}"
    chmod +x "${BIN_LINK}"
    run is_installed
    assert_success
}

# ── detect ───────────────────────────────────────────────────────────────────

@test "detect returns 0 on x86_64" {
    _load_module
    eval 'uname() { printf "x86_64\n"; }'
    run detect
    assert_success
}

@test "detect returns nonzero on aarch64 (no prebuilt gnu zip wired)" {
    _load_module
    eval 'uname() { printf "aarch64\n"; }'
    run detect
    assert_failure
}

# ── Dry-run is a no-op for every Action Phase ────────────────────────────────

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

@test "dry-run install performs zero filesystem writes (AC-12 pattern)" {
    _load_module
    _sandbox_module
    printf '# pristine\n' > "${TEST_HOME}/.bashrc"
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ "$(cat "${TEST_HOME}/.bashrc")" == "# pristine" ]]
    [[ ! -e "$(_sidecar_path)" ]]
    [[ ! -e "${INSTALL_DIR}" ]]
}

@test "dry-run purge leaves rc files and Sidecar in place" {
    _load_module
    _sandbox_module
    printf '# rc\n' > "${TEST_HOME}/.bashrc"
    module_standalone_main install
    INIT_UBUNTU_DRY_RUN=true run purge
    assert_success
    [[ -f "$(_sidecar_path)" ]]
    grep -qF "alias yz='yazi'" "${TEST_HOME}/.bashrc"
}

# ── Idempotency (AC-5 pattern) ───────────────────────────────────────────────

@test "install short-circuits when is_installed returns 0 (idempotency)" {
    _load_module
    _sandbox_module
    eval 'is_installed() { return 0; }'
    run install
    assert_success
    assert_output --partial "already installed"
}

@test "install twice in a row both exit 0 and do not duplicate the alias" {
    _load_module
    _sandbox_module
    printf '# rc\n' > "${TEST_HOME}/.bashrc"
    install
    install
    [[ "$(grep -cF "alias yz='yazi'" "${TEST_HOME}/.bashrc")" -eq 1 ]]
}

@test "upgrade after install does not duplicate the alias" {
    _load_module
    _sandbox_module
    printf '# rc\n' > "${TEST_HOME}/.bashrc"
    install
    upgrade
    [[ "$(grep -cF "alias yz='yazi'" "${TEST_HOME}/.bashrc")" -eq 1 ]]
}

@test "remove is idempotent: second run still exits 0" {
    _load_module
    _sandbox_module
    install
    remove
    run remove
    assert_success
}

@test "purge is idempotent: second run still exits 0" {
    _load_module
    _sandbox_module
    install
    purge
    run purge
    assert_success
}

# ── Alias drop (legacy module/submodule/yazi.sh; #1 copy-paste regression) ───

@test "install appends yz alias to an existing ~/.bashrc" {
    _load_module
    _sandbox_module
    printf '# rc\n' > "${TEST_HOME}/.bashrc"
    run install
    assert_success
    grep -qF "alias yz='yazi'" "${TEST_HOME}/.bashrc"
}

@test "install appends yz alias to an existing ~/.zshrc too" {
    _load_module
    _sandbox_module
    printf '# rc\n' > "${TEST_HOME}/.zshrc"
    run install
    assert_success
    grep -qF "alias yz='yazi'" "${TEST_HOME}/.zshrc"
}

@test "alias is guarded by command -v yazi (no broken alias without binary)" {
    _load_module
    _sandbox_module
    printf '# rc\n' > "${TEST_HOME}/.bashrc"
    install
    grep -qE "command -v yazi.*alias yz='yazi'" "${TEST_HOME}/.bashrc"
}

@test "regression #1: alias targets yazi itself, never cat" {
    _load_module
    _sandbox_module
    printf '# rc\n' > "${TEST_HOME}/.bashrc"
    install
    run grep -F "alias cat=" "${TEST_HOME}/.bashrc"
    assert_failure
}

@test "install succeeds when no rc file exists (alias step skipped)" {
    _load_module
    _sandbox_module
    run install
    assert_success
}

@test "remove keeps the alias (config preserved); purge strips it" {
    _load_module
    _sandbox_module
    printf '# rc\n' > "${TEST_HOME}/.bashrc"
    install
    remove
    grep -qF "alias yz='yazi'" "${TEST_HOME}/.bashrc"
    purge
    run ! grep -qF "alias yz='yazi'" "${TEST_HOME}/.bashrc"
}

@test "purge strips the alias from ~/.zshrc as well" {
    _load_module
    _sandbox_module
    printf '# rc\n' > "${TEST_HOME}/.zshrc"
    install
    purge
    run ! grep -qF "alias yz='yazi'" "${TEST_HOME}/.zshrc"
}

@test "purge keeps unrelated rc lines intact" {
    _load_module
    _sandbox_module
    printf '# keep me\nexport FOO=bar\n' > "${TEST_HOME}/.bashrc"
    install
    purge
    grep -qF "# keep me" "${TEST_HOME}/.bashrc"
    grep -qF "export FOO=bar" "${TEST_HOME}/.bashrc"
}

# ── Sidecar (ADR-0001) ───────────────────────────────────────────────────────

@test "install writes the Sidecar under \${INIT_UBUNTU_STATE_DIR}/versions/" {
    _load_module
    _sandbox_module
    run module_standalone_main install
    assert_success
    [[ -f "$(_sidecar_path)" ]]
}

@test "install records the binary-reported version in the Sidecar" {
    _load_module
    _sandbox_module
    module_standalone_main install
    [[ "$(cat "$(_sidecar_path)")" == "25.5.31" ]]
}

@test "upgrade (re)writes the Sidecar" {
    _load_module
    _sandbox_module
    run module_standalone_main upgrade
    assert_success
    [[ -f "$(_sidecar_path)" ]]
}

@test "remove deletes the Sidecar" {
    _load_module
    _sandbox_module
    module_standalone_main install
    [[ -f "$(_sidecar_path)" ]]
    module_standalone_main remove
    [[ ! -e "$(_sidecar_path)" ]]
}

@test "purge deletes the Sidecar" {
    _load_module
    _sandbox_module
    module_standalone_main install
    module_standalone_main purge
    [[ ! -e "$(_sidecar_path)" ]]
}

@test "install never touches state.json (AC-23 pattern, ADR-0001)" {
    _load_module
    _sandbox_module
    printf '{"version":"0.1.0","installed":{}}\n' > "${INIT_UBUNTU_STATE_DIR}/state.json"
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == '{"version":"0.1.0","installed":{}}' ]]
}

# ── Zip fetch (upstream ships a ZIP, not a tarball) ──────────────────────────

@test "fetch rejects a download that is not a zip archive" {
    _load_module
    # real _yazi_fetch_and_install, but sandboxed paths + stubbed network
    _sandbox_fetch_paths
    # Stub unzip as PRESENT so the spec exercises the magic-byte branch
    # deterministically — the coverage image (kcov/kcov, debian) has no
    # unzip while test-tools:local (alpine) gets one from busybox; the
    # test must not depend on which container it runs in.
    eval 'command() {
        if [[ "${1:-}" == "-v" && "${2:-}" == "unzip" ]]; then return 0; fi
        builtin command "$@"
    }'
    eval 'curl() {
        # write garbage to the -o target
        local _out=""
        while [[ $# -gt 0 ]]; do
            [[ "${1}" == "-o" ]] && { _out="${2}"; shift; }
            shift
        done
        printf "this is not a zip\n" > "${_out}"
    }'
    eval 'get_github_pkg_latest_version() { local -n _o="${1}"; _o="25.5.31"; }'
    run _yazi_fetch_and_install
    assert_failure
    assert_output --partial "not a zip"
    [[ ! -e "${INSTALL_DIR}" ]]
}

@test "fetch fails fast with a clear message when unzip is unavailable" {
    _load_module
    _sandbox_fetch_paths
    eval 'command() {
        if [[ "${1:-}" == "-v" && "${2:-}" == "unzip" ]]; then return 1; fi
        builtin command "$@"
    }'
    run _yazi_fetch_and_install
    assert_failure
    assert_output --partial "unzip"
}

# ── is_recommended ───────────────────────────────────────────────────────────

@test "is_recommended returns nonzero when already installed" {
    _load_module
    eval 'is_installed() { return 0; }'
    run is_recommended
    assert_failure
}

@test "is_recommended returns 0 when not installed" {
    _load_module
    eval 'is_installed() { return 1; }'
    run is_recommended
    assert_success
}

# ── is_outdated ──────────────────────────────────────────────────────────────

@test "is_outdated returns nonzero when no Sidecar exists (no network hit)" {
    _load_module
    eval 'get_github_pkg_latest_version() {
        printf "network must not be queried without a Sidecar\n" >&2
        return 1
    }'
    run is_outdated
    assert_failure
    refute_output --partial "network must not be queried"
}

@test "is_outdated returns 0 when Sidecar version differs from latest" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '0.1.0\n' > "$(_sidecar_path)"
    eval 'get_github_pkg_latest_version() { local -n _out="${1}"; _out="99.0.0"; }'
    run is_outdated
    assert_success
}

@test "is_outdated returns nonzero when Sidecar matches latest" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '99.0.0\n' > "$(_sidecar_path)"
    eval 'get_github_pkg_latest_version() { local -n _out="${1}"; _out="99.0.0"; }'
    run is_outdated
    assert_failure
}

# ── doctor ───────────────────────────────────────────────────────────────────

@test "doctor returns nonzero when yazi is not installed" {
    _load_module
    eval 'is_installed() { return 1; }'
    run doctor
    assert_failure
}

@test "doctor passes and warns (read-only) when the Sidecar is missing" {
    # Sidecar is written at the phase-invocation layer (refines ADR-0001), so
    # doctor is read-only: warns about a missing Sidecar, does NOT heal it.
    _load_module
    eval 'is_installed() { return 0; }'
    eval 'yazi() { printf "Yazi 25.5.31 (f5a1cf0 2025-05-31)\n"; }'
    [[ ! -e "$(_sidecar_path)" ]]
    run doctor
    assert_success
    assert_output --partial "Sidecar missing"
    [[ ! -e "$(_sidecar_path)" ]]
}

# ── Engine discovery (registry scan) ─────────────────────────────────────────

@test "registry discovers yazi under --tag=filemgr" {
    # shellcheck source=../../../lib/logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=../../../lib/registry.sh
    source "${LIB_DIR}/registry.sh"
    export INIT_UBUNTU_USER_MODULE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/user-module"
    registry_load_all "${MODULE_DIR}"
    run registry_list_names --tag=filemgr
    assert_success
    assert_output --partial "yazi"
}

# ── Standalone CLI (dual-mode footer, AC-25) ─────────────────────────────────

_standalone_module() {
    bash "${MODULE_DIR}/yazi.module.sh" "$@"
}

@test "standalone: with no args prints usage + exits 2" {
    run _standalone_module
    assert_failure 2
    assert_output --partial "Usage:"
}

@test "standalone: install --dry-run prints DRY-RUN + exits 0" {
    run _standalone_module install --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "standalone: --version prints NAME + VERSION_PROVIDED" {
    run _standalone_module --version
    assert_success
    assert_output --partial "yazi"
}

@test "standalone: --help shows phases" {
    run _standalone_module --help
    assert_success
    assert_output --partial "install"
    assert_output --partial "remove"
    assert_output --partial "purge"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module nope
    assert_failure 2
}

@test "standalone: info prints metadata (name / category / tags)" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        yazi"
    assert_output --partial "category:    optional"
    assert_output --partial "filemgr"
}

@test "standalone: info honors --lang=zh-TW" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "檔案管理"
}

@test "standalone: status reports installed=no on a fresh container" {
    HOME="${TEST_HOME}" run _standalone_module status
    assert_success
    assert_output --partial "installed:   no"
}

@test "standalone: all 10 lifecycle phases run without 'not implemented' exit 2 (AC-25)" {
    local _phase _rc
    for _phase in install upgrade remove purge verify doctor detect \
                  is-installed is-recommended is-outdated; do
        _rc=0
        HOME="${TEST_HOME}" run _standalone_module "${_phase}" --dry-run
        _rc="${status}"
        if [[ "${_rc}" -eq 2 ]] || [[ "${output}" == *"not implemented"* ]]; then
            printf "phase %s hit not-implemented (rc=%s)\noutput: %s\n" \
                "${_phase}" "${_rc}" "${output}" >&2
            return 1
        fi
    done
}

@test "standalone: dry-run install leaves state.json untouched (AC-23)" {
    printf '{"version":"0.1.0","installed":{}}\n' > "${INIT_UBUNTU_STATE_DIR}/state.json"
    run _standalone_module install --dry-run
    assert_success
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == '{"version":"0.1.0","installed":{}}' ]]
}

@test "standalone: dry-run install writes no Sidecar" {
    run _standalone_module install --dry-run
    assert_success
    [[ ! -e "$(_sidecar_path)" ]]
}

# ── Tracked config content (keymap.toml / yazi.toml) ─────────────────────────
# Precedent: qmk-firmware_spec / codex_spec assert on tracked config-file
# content. These lock the fixes for #272 (Right-arrow parity), #273 (drop
# dead v26.5.6 keys) and #162 (route application/xml to code + $EDITOR).

_yazi_keymap() { printf '%s' "${MODULE_DIR}/config/yazi/keymap.toml"; }
_yazi_conf()   { printf '%s' "${MODULE_DIR}/config/yazi/yazi.toml"; }

# Print the lines of a bracketed list block ("<key> = [ ... ]") from yazi.toml,
# from the opening "<key> = [" line through the first line that is a lone "]".
_yazi_block() {
    awk -v key="$1" '
        index($0, key " = [") { inb = 1 }
        inb                   { print }
        inb && /^\]/          { inb = 0 }
    ' "$(_yazi_conf)"
}

# ── #272: <Right> smart-enter parity with l / <Enter> ────────────────────────

@test "#272 keymap.toml binds <Right> to the smart-enter run (parity with l/<Enter>)" {
    # The <Right> on-line must be immediately followed by the same
    # 'plugin smart-enter' run as the existing l / <Enter> entries.
    run grep -A1 -F 'on   = "<Right>"' "$(_yazi_keymap)"
    assert_success
    assert_output --partial 'run  = "plugin smart-enter"'
}

# ── #273: drop dead v26.5.6 keys (title_format / micro/macro_workers) ────────

@test "#273 yazi.toml no longer declares title_format" {
    run grep -Eq '^[[:space:]]*title_format[[:space:]]*=' "$(_yazi_conf)"
    assert_failure
}

@test "#273 yazi.toml no longer declares micro_workers or macro_workers" {
    run grep -Eq '^[[:space:]]*(micro|macro)_workers[[:space:]]*=' "$(_yazi_conf)"
    assert_failure
}

@test "#273 the surviving [tasks] keys are untouched" {
    run grep -Eq '^[[:space:]]*bizarre_retry[[:space:]]*=' "$(_yazi_conf)"
    assert_success
    run grep -Eq '^[[:space:]]*suppress_preload[[:space:]]*=' "$(_yazi_conf)"
    assert_success
}

# ── #162: route application/xml (+*+xml) to code preview/spot + $EDITOR ───────

@test "#162 opener routes application/xml and *+xml to the edit (\$EDITOR) opener" {
    run grep -Eq 'application/\{xml,xml-dtd\}".*use = \[ "edit"' "$(_yazi_conf)"
    assert_success
    run grep -Eq 'application/\*\+xml".*use = \[ "edit"' "$(_yazi_conf)"
    assert_success
}

@test "#162 a prepend_spotters block routes xml and *+xml to the code spotter" {
    local _b; _b="$(_yazi_block prepend_spotters)"
    [[ -n "${_b}" ]]
    [[ "${_b}" == *'application/{xml,xml-dtd}", run = "code"'* ]]
    [[ "${_b}" == *'application/*+xml"'*'run = "code"'* ]]
}

@test "#162 prepend_previewers routes xml and *+xml to the code previewer" {
    local _b; _b="$(_yazi_block prepend_previewers)"
    [[ -n "${_b}" ]]
    [[ "${_b}" == *'application/{xml,xml-dtd}", run = "code"'* ]]
    [[ "${_b}" == *'application/*+xml"'*'run = "code"'* ]]
}
