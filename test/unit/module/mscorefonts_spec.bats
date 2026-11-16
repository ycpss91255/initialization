#!/usr/bin/env bats
# test/unit/module/mscorefonts_spec.bats — module/mscorefonts.module.sh
#
# apt-archetype module with a hand-written install(): ttf-mscorefonts-installer
# only downloads the fonts when the Microsoft EULA debconf answer is true.
# Key regression covered here: the package can be `ii` in dpkg while Times New
# Roman is absent (EULA refused -> postinst removed the fonts, left a README),
# so "installed" must be judged by the font files, not by dpkg alone.
#
# Layout: smoke / metadata / is_installed (incl. the refused-EULA regression) /
# dry-run / install (preseed, --reinstall, failure paths) / sidecar lifecycle
# (ADR-0001) / doctor / is_outdated / is_recommended / detect / standalone CLI.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    # Fake font dir (the module honours MSCOREFONTS_DIR) — never touch the host.
    export MSCOREFONTS_DIR="${INIT_UBUNTU_TEST_SCRATCH}/msttcorefonts"
    mkdir -p "${MSCOREFONTS_DIR}"
    SUDO_LOG="${INIT_UBUNTU_TEST_SCRATCH}/sudo.log"
    PRESEED_FILE="${INIT_UBUNTU_TEST_SCRATCH}/preseed.txt"
    : > "${SUDO_LOG}"
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
    # shellcheck source=../../../module/mscorefonts.module.sh
    source "${MODULE_DIR}/mscorefonts.module.sh"
}

_standalone_module() {
    bash "${MODULE_DIR}/mscorefonts.module.sh" "$@"
}

# ── Controllable mocks ───────────────────────────────────────────────────────

_mock_is_installed() {
    is_installed() { return "${MOCK_IS_INSTALLED_RC:-0}"; }
}

# dpkg stub: MOCK_DPKG_OUTPUT is what `dpkg -l <pkg>` prints.
_mock_dpkg() {
    dpkg() {
        [[ -n "${MOCK_DPKG_OUTPUT:-}" ]] && printf '%s\n' "${MOCK_DPKG_OUTPUT}"
        return "${MOCK_DPKG_RC:-0}"
    }
}

_mock_dpkg_query() {
    dpkg-query() {
        [[ -n "${MOCK_PKG_VERSION:-}" ]] || return 1
        printf '%s' "${MOCK_PKG_VERSION}"
    }
}

_mock_apt_defaults() {
    module_default_apt_install() { return "${MOCK_APT_INSTALL_RC:-0}"; }
    module_default_apt_upgrade() { return "${MOCK_APT_UPGRADE_RC:-0}"; }
    module_default_apt_remove()  { return "${MOCK_APT_REMOVE_RC:-0}"; }
    module_default_apt_purge()   { return "${MOCK_APT_PURGE_RC:-0}"; }
}

_mock_apt_list() {
    apt() { printf '%s' "${MOCK_APT_UPGRADABLE:-}"; }
}

_mock_sudo_access() {
    have_sudo_access() { return "${MOCK_SUDO_ACCESS_RC:-0}"; }
}

# sudo stub: records the argv, captures the preseed line from stdin, and — when
# MOCK_FONTS_AFTER_INSTALL=1 — drops a font file as the postinst would.
_mock_sudo() {
    sudo() {
        printf '%s\n' "$*" >> "${SUDO_LOG}"
        case "$1" in
            debconf-set-selections)
                cat > "${PRESEED_FILE}"
                return "${MOCK_DEBCONF_RC:-0}"
                ;;
            env)
                case "$*" in
                    *"apt-get install"*)
                        if [[ "${MOCK_FONTS_AFTER_INSTALL:-0}" == "1" ]]; then
                            : > "${MSCOREFONTS_DIR}/Times_New_Roman.ttf"
                        fi
                        return "${MOCK_APT_INSTALL_RC:-0}"
                        ;;
                esac
                ;;
        esac
        return 0
    }
}

# _stub_bin <name> — put a fake binary on PATH that exits 0 for any args.
_stub_bin() {
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/usr/bin/env bash\nprintf "%s stub 0.0.0\n"\nexit 0\n' "${1}" \
        > "${INIT_UBUNTU_TEST_SCRATCH}/bin/${1}"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/${1}"
}

# fc-match stub: prints MOCK_FC_MATCH_OUTPUT (fontconfig resolving "Times New
# Roman" to either the real font or a substitute such as Liberation Serif).
_mock_fc_match() {
    fc-match() { printf '%s\n' "${MOCK_FC_MATCH_OUTPUT:-}"; }
}

_add_fonts() { : > "${MSCOREFONTS_DIR}/Times_New_Roman.ttf"; }

# ── Smoke ────────────────────────────────────────────────────────────────────

@test "mscorefonts module file parses (bash -n)" {
    run bash -n "${MODULE_DIR}/mscorefonts.module.sh"
    assert_success
}

@test "mscorefonts module sources cleanly in engine mode (MODULE_STANDALONE=false)" {
    _load_module
    [[ "${MODULE_STANDALONE}" == "false" ]]
}

@test "mscorefonts module defines all 10 lifecycle functions (ADR-0002 / #305)" {
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

@test "mscorefonts module declares NAME=mscorefonts" {
    _load_module
    [[ "${NAME}" == "mscorefonts" ]]
}

@test "mscorefonts module CATEGORY=optional" {
    _load_module
    [[ "${CATEGORY}" == "optional" ]]
}

@test "mscorefonts module TAGS contains font and desktop" {
    _load_module
    [[ " ${TAGS[*]} " == *" font "* ]]
    [[ " ${TAGS[*]} " == *" desktop "* ]]
}

@test "mscorefonts module DEPENDS_ON is empty (standalone tool)" {
    _load_module
    [[ "${#DEPENDS_ON[@]}" -eq 0 ]]
}

@test "mscorefonts DESCRIPTION is associative with en + zh-TW entries" {
    _load_module
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)"
    [[ "${_decl}" == 'declare -'*A* ]]
    [[ -n "${DESCRIPTION[en]}" ]]
    [[ -n "${DESCRIPTION[zh-TW]}" ]]
}

@test "mscorefonts module_get_description returns language-specific text + en fallback" {
    _load_module
    [[ -n "$(module_get_description en)" ]]
    [[ "$(module_get_description zh-TW)" == *"字型"* ]]
    [[ "$(module_get_description xx)" == "$(module_get_description en)" ]]
}

@test "mscorefonts SUPPORTED_UBUNTU includes 22.04 24.04 26.04" {
    _load_module
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 22.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 24.04 "* ]]
    [[ " ${SUPPORTED_UBUNTU[*]} " == *" 26.04 "* ]]
}

@test "mscorefonts SUPPORTED_PLATFORMS is desktop-only" {
    _load_module
    [[ "${#SUPPORTED_PLATFORMS[@]}" -eq 1 ]]
    [[ "${SUPPORTED_PLATFORMS[0]}" == "desktop" ]]
}

@test "mscorefonts module RISK_LEVEL=low and VERSION_PROVIDED=apt-managed" {
    _load_module
    [[ "${RISK_LEVEL}" == "low" ]]
    [[ "${VERSION_PROVIDED}" == "apt-managed" ]]
}

@test "mscorefonts archetype data installs the ttf-mscorefonts-installer package" {
    _load_module
    [[ "${#APT_PKGS[@]}" -eq 1 ]]
    [[ "${APT_PKGS[0]}" == "ttf-mscorefonts-installer" ]]
    [[ -z "${APT_PPA}" ]]
}

@test "mscorefonts WARN_MESSAGE discloses the EULA acceptance (en + zh-TW)" {
    _load_module
    [[ "${WARN_MESSAGE[en]}" == *"EULA"* ]]
    [[ "${WARN_MESSAGE[zh-TW]}" == *"授權"* ]]
}

@test "mscorefonts TEST_VERIFY_CMD probes Times New Roman" {
    _load_module
    [[ "${TEST_VERIFY_CMD}" == *"Times New Roman"* ]]
}

# ── is_installed: judged by the font files, not by dpkg alone ────────────────

@test "is_installed succeeds when dpkg reports ii and Times_New_Roman.ttf exists" {
    _load_module
    MOCK_DPKG_OUTPUT='ii  ttf-mscorefonts-installer  3.8.1  all  pkg'
    _mock_dpkg
    _add_fonts
    run is_installed
    assert_success
}

@test "is_installed succeeds with the lowercase times.ttf spelling" {
    _load_module
    MOCK_DPKG_OUTPUT='ii  ttf-mscorefonts-installer  3.8.1  all  pkg'
    _mock_dpkg
    : > "${MSCOREFONTS_DIR}/times.ttf"
    run is_installed
    assert_success
}

@test "is_installed FAILS when dpkg says ii but only the License-refused README exists" {
    _load_module
    MOCK_DPKG_OUTPUT='ii  ttf-mscorefonts-installer  3.8.1  all  pkg'
    _mock_dpkg
    printf 'License refused.\n' > "${MSCOREFONTS_DIR}/README"
    run is_installed
    assert_failure
}

@test "is_installed fails when the fonts exist but dpkg does not report the package" {
    _load_module
    MOCK_DPKG_RC=1
    _mock_dpkg
    _add_fonts
    run is_installed
    assert_failure
}

@test "is_installed fails on a clean system (no package, no fonts)" {
    _load_module
    MOCK_DPKG_RC=1
    _mock_dpkg
    run is_installed
    assert_failure
}

# ── Lifecycle dry-run ────────────────────────────────────────────────────────

@test "install in dry-run mode is a no-op" {
    _load_module
    _mock_sudo
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    assert_output --partial "DRY-RUN"
    [[ ! -s "${SUDO_LOG}" ]]
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

@test "doctor in dry-run mode is a no-op" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run doctor
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "dry-run install writes nothing under the state dir" {
    _load_module
    INIT_UBUNTU_DRY_RUN=true run install
    assert_success
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/mscorefonts" ]]
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/state.json" ]]
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

# ── install: EULA preseed, --reinstall, failure paths ────────────────────────

@test "install preseeds the EULA answer as true via debconf-set-selections" {
    _load_module
    _mock_sudo_access
    _mock_sudo
    MOCK_DPKG_RC=1
    _mock_dpkg
    MOCK_FONTS_AFTER_INSTALL=1
    run install
    assert_success
    [[ "$(cat "${PRESEED_FILE}")" == \
       "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" ]]
}

@test "install preseeds BEFORE it runs apt-get install" {
    _load_module
    _mock_sudo_access
    _mock_sudo
    MOCK_DPKG_RC=1
    _mock_dpkg
    MOCK_FONTS_AFTER_INSTALL=1
    run install
    assert_success
    local _preseed_line _install_line
    _preseed_line="$(grep -n 'debconf-set-selections' "${SUDO_LOG}" | head -1 | cut -d: -f1)"
    _install_line="$(grep -n 'apt-get install' "${SUDO_LOG}" | head -1 | cut -d: -f1)"
    [[ -n "${_preseed_line}" && -n "${_install_line}" ]]
    [[ "${_preseed_line}" -lt "${_install_line}" ]]
}

@test "install passes DEBIAN_FRONTEND=noninteractive through sudo env" {
    _load_module
    _mock_sudo_access
    _mock_sudo
    MOCK_DPKG_RC=1
    _mock_dpkg
    MOCK_FONTS_AFTER_INSTALL=1
    run install
    assert_success
    grep -q 'env DEBIAN_FRONTEND=noninteractive apt-get install' "${SUDO_LOG}"
}

@test "fresh install does NOT pass --reinstall" {
    _load_module
    _mock_sudo_access
    _mock_sudo
    MOCK_DPKG_RC=1
    _mock_dpkg
    MOCK_FONTS_AFTER_INSTALL=1
    run install
    assert_success
    run grep -q -- '--reinstall' "${SUDO_LOG}"
    assert_failure
}

@test "install passes --reinstall when the package is present but fonts are missing" {
    _load_module
    _mock_sudo_access
    _mock_sudo
    MOCK_DPKG_OUTPUT='ii  ttf-mscorefonts-installer  3.8.1  all  pkg'
    _mock_dpkg
    printf 'License refused.\n' > "${MSCOREFONTS_DIR}/README"
    MOCK_FONTS_AFTER_INSTALL=1
    run install
    assert_success
    grep -q -- '--reinstall' "${SUDO_LOG}"
    grep -q 'ttf-mscorefonts-installer' "${SUDO_LOG}"
}

@test "install fails when apt-get install fails" {
    _load_module
    _mock_sudo_access
    _mock_sudo
    MOCK_DPKG_RC=1
    _mock_dpkg
    MOCK_APT_INSTALL_RC=1
    run install
    assert_failure
}

@test "install fails when the fonts are still missing after apt succeeds" {
    _load_module
    _mock_sudo_access
    _mock_sudo
    MOCK_DPKG_RC=1
    _mock_dpkg
    MOCK_FONTS_AFTER_INSTALL=0
    run install
    assert_failure
    assert_output --partial "fonts are still missing"
}

@test "install fails and runs no sudo command when sudo access is unavailable" {
    _load_module
    MOCK_SUDO_ACCESS_RC=1
    _mock_sudo_access
    _mock_sudo
    MOCK_DPKG_RC=1
    _mock_dpkg
    run install
    assert_failure
    [[ ! -s "${SUDO_LOG}" ]]
}

@test "install fails when debconf-set-selections fails (no apt-get attempted)" {
    _load_module
    _mock_sudo_access
    _mock_sudo
    MOCK_DPKG_RC=1
    _mock_dpkg
    MOCK_DEBCONF_RC=1
    run install
    assert_failure
    run grep -q 'apt-get install' "${SUDO_LOG}"
    assert_failure
}

@test "install short-circuits when fonts are already installed (idempotency)" {
    _load_module
    _mock_sudo_access
    _mock_sudo
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    MOCK_PKG_VERSION="3.8.1"
    _mock_dpkg_query
    run install
    assert_success
    assert_output --partial "already installed"
    [[ ! -s "${SUDO_LOG}" ]]
}

# ── Sidecar lifecycle (ADR-0001) ─────────────────────────────────────────────

@test "install writes the sidecar with the dpkg-reported version" {
    _load_module
    _mock_sudo_access
    _mock_sudo
    MOCK_DPKG_RC=1
    _mock_dpkg
    MOCK_FONTS_AFTER_INSTALL=1
    MOCK_PKG_VERSION="3.8.1ubuntu1"
    _mock_dpkg_query
    module_standalone_main install
    [[ -f "${INIT_UBUNTU_STATE_DIR}/versions/mscorefonts" ]]
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/mscorefonts")" == "3.8.1ubuntu1" ]]
}

@test "install sidecar falls back to apt-managed when dpkg-query is empty" {
    _load_module
    _mock_sudo_access
    _mock_sudo
    MOCK_DPKG_RC=1
    _mock_dpkg
    MOCK_FONTS_AFTER_INSTALL=1
    MOCK_PKG_VERSION=""
    _mock_dpkg_query
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/mscorefonts")" == "apt-managed" ]]
}

@test "install never touches state.json (ADR-0001)" {
    _load_module
    printf '{"version":"0.2.0","installed":{}}\n' \
        > "${INIT_UBUNTU_STATE_DIR}/state.json"
    local _before; _before="$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")"
    _mock_sudo_access
    _mock_sudo
    MOCK_DPKG_RC=1
    _mock_dpkg
    MOCK_FONTS_AFTER_INSTALL=1
    MOCK_PKG_VERSION="3.8.1ubuntu1"
    _mock_dpkg_query
    module_standalone_main install
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/state.json")" == "${_before}" ]]
}

@test "failed install leaves no sidecar behind (ADR-0015)" {
    _load_module
    _mock_sudo_access
    _mock_sudo
    MOCK_DPKG_RC=1
    _mock_dpkg
    MOCK_APT_INSTALL_RC=1
    run module_standalone_main install
    assert_failure
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/mscorefonts" ]]
}

@test "install with fonts still missing leaves no sidecar behind" {
    _load_module
    _mock_sudo_access
    _mock_sudo
    MOCK_DPKG_RC=1
    _mock_dpkg
    MOCK_FONTS_AFTER_INSTALL=0
    run module_standalone_main install
    assert_failure
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/mscorefonts" ]]
}

@test "upgrade refreshes the sidecar version" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/mscorefonts"
    _mock_apt_defaults
    MOCK_PKG_VERSION="3.8.1ubuntu1"
    _mock_dpkg_query
    module_standalone_main upgrade
    [[ "$(cat "${INIT_UBUNTU_STATE_DIR}/versions/mscorefonts")" == "3.8.1ubuntu1" ]]
}

@test "remove deletes the sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/mscorefonts"
    _mock_apt_defaults
    module_standalone_main remove
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/mscorefonts" ]]
}

@test "purge deletes the sidecar" {
    _load_module
    mkdir -p "${INIT_UBUNTU_STATE_DIR}/versions"
    printf '1.0.0\n' > "${INIT_UBUNTU_STATE_DIR}/versions/mscorefonts"
    _mock_apt_defaults
    module_standalone_main purge
    [[ ! -e "${INIT_UBUNTU_STATE_DIR}/versions/mscorefonts" ]]
}

@test "remove is idempotent — second run still exits 0" {
    _load_module
    _mock_apt_defaults
    run remove
    assert_success
    run remove
    assert_success
}

# ── upgrade heals the refused-EULA state ─────────────────────────────────────

@test "upgrade runs install (not a no-op) when the package is present but fonts are missing" {
    _load_module
    _mock_sudo_access
    _mock_sudo
    MOCK_DPKG_OUTPUT='ii  ttf-mscorefonts-installer  3.8.1  all  pkg'
    _mock_dpkg
    printf 'License refused.\n' > "${MSCOREFONTS_DIR}/README"
    MOCK_FONTS_AFTER_INSTALL=1
    run upgrade
    assert_success
    grep -q 'debconf-set-selections' "${SUDO_LOG}"
    grep -q -- '--reinstall' "${SUDO_LOG}"
}

# ── verify / is_outdated ─────────────────────────────────────────────────────

@test "verify fails when not installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run verify
    assert_failure
}

@test "verify passes when installed and TEST_VERIFY_CMD succeeds" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    TEST_VERIFY_CMD="true"
    run verify
    assert_success
}

@test "is_outdated returns zero when apt reports ttf-mscorefonts-installer upgradable" {
    _load_module
    MOCK_APT_UPGRADABLE='ttf-mscorefonts-installer/noble 3.8.2 all [upgradable from: 3.8.1]'
    _mock_apt_list
    run is_outdated
    assert_success
}

@test "is_outdated returns nonzero when it is not in the upgradable list" {
    _load_module
    MOCK_APT_UPGRADABLE='some-other-pkg/noble 1.0 amd64 [upgradable from: 0.9]'
    _mock_apt_list
    run is_outdated
    assert_failure
}

# ── doctor ───────────────────────────────────────────────────────────────────

@test "doctor fails when not installed" {
    _load_module
    MOCK_IS_INSTALLED_RC=1
    _mock_is_installed
    run doctor
    assert_failure
    assert_output --partial "not installed"
}

@test "doctor fails when fontconfig has no fc-match" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/empty-bin"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/empty-bin" run doctor
    assert_failure
    assert_output --partial "fc-match"
}

@test "doctor fails when 'Times New Roman' resolves to a substitute (Liberation Serif)" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    MOCK_FC_MATCH_OUTPUT='LiberationSerif-Regular.ttf: "Liberation Serif" "Regular"'
    _mock_fc_match
    run doctor
    assert_failure
    assert_output --partial "does not resolve"
}

@test "doctor passes when fc-match resolves 'Times New Roman' to the real font" {
    _load_module
    MOCK_IS_INSTALLED_RC=0
    _mock_is_installed
    MOCK_FC_MATCH_OUTPUT='Times_New_Roman.ttf: "Times New Roman" "Regular"'
    _mock_fc_match
    run doctor
    assert_success
}

# ── is_recommended / detect ──────────────────────────────────────────────────

@test "is_recommended is always nonzero (proprietary fonts: explicit install only)" {
    _load_module
    local _ff
    for _ff in desktop server wsl ''; do
        MOCK_IS_INSTALLED_RC=1
        _mock_is_installed
        INIT_UBUNTU_FORM_FACTOR="${_ff}" run is_recommended
        assert_failure
    done
}

@test "detect succeeds when apt-get is available" {
    _load_module
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}/bin"
    printf '#!/bin/sh\nexit 0\n' > "${INIT_UBUNTU_TEST_SCRATCH}/bin/apt-get"
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/bin/apt-get"
    PATH="${INIT_UBUNTU_TEST_SCRATCH}/bin:${PATH}" run detect
    assert_success
}

@test "detect fails when apt-get is not on PATH" {
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

@test "standalone: --version prints NAME + VERSION_PROVIDED" {
    run _standalone_module --version
    assert_success
    assert_output --partial "mscorefonts"
}

@test "standalone: unknown phase returns exit 2" {
    run _standalone_module nope
    assert_failure 2
}

@test "standalone: info prints metadata" {
    run _standalone_module info
    assert_success
    assert_output --partial "name:        mscorefonts"
    assert_output --partial "category:    optional"
}

@test "standalone: info --lang=zh-TW prints localized description" {
    run _standalone_module info --lang=zh-TW
    assert_success
    assert_output --partial "字型"
}

@test "standalone: status reports installed + outdated fields" {
    run _standalone_module status
    assert_success
    assert_output --partial "installed:"
    assert_output --partial "outdated:"
}

@test "standalone: install --dry-run exits 0 with DRY-RUN output" {
    run _standalone_module install --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}

@test "standalone: doctor --dry-run exits 0 with DRY-RUN output" {
    run _standalone_module doctor --dry-run
    assert_success
    assert_output --partial "DRY-RUN"
}
