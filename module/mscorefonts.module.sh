#!/usr/bin/env bash
# module/mscorefonts.module.sh — Microsoft core fonts (Times New Roman, Arial, ...) via ttf-mscorefonts-installer  [archetype: apt + hand-written install]
#
# Ubuntu ships `ttf-mscorefonts-installer`, a downloader package: its postinst
# fetches the fonts from SourceForge, but ONLY if the Microsoft EULA debconf
# question (msttcorefonts/accepted-mscorefonts-eula) is true. When the package
# is pulled in as a dependency (e.g. by an office suite's .deb) non-interactively,
# the answer ends up `false`, the postinst removes any fonts and leaves a
# "License refused." README — the package shows as `ii` in dpkg while
# Times New Roman is absent. This module therefore:
#   * judges "installed" by the font files, not by dpkg alone;
#   * preseeds the EULA answer, then (re)installs so the postinst runs again.
#
# Standalone usage:
#   bash module/mscorefonts.module.sh install [--dry-run]
#   bash module/mscorefonts.module.sh upgrade / remove / purge / verify / doctor
#   bash module/mscorefonts.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/mscorefonts.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install mscorefonts

# ── Dual-mode header ────────────────────────────────────────────────────────
MODULE_STANDALONE="true"
[[ "${BASH_SOURCE[0]:-}" != "${0:-}" ]] && MODULE_STANDALONE="false"
if [[ "${MODULE_STANDALONE}" == "true" ]]; then
    # shellcheck source=../lib/module_bootstrap.sh
    source "${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)}/module_bootstrap.sh"
    module_bootstrap
fi
# Static-analysis hint (never executed: the guard is always false; wrapped in
# kcov-exclude so the dead line is not counted against coverage). module_bootstrap
# sources the lib helpers at runtime, but shellcheck cannot trace that 2-level
# dynamic source — this guarded line lets `shellcheck -x` follow module_helper.sh
# so it sees the metadata + archetype vars below are used externally (avoids SC2034).
# kcov-exclude-start
# shellcheck source=../lib/module_helper.sh
[[ -n "${__module_lint_hint:-}" ]] && source "${LIB_DIR}/module_helper.sh"
# kcov-exclude-end

# ── Metadata (doc/module-spec.md §3) ────────────────────────────────────────
NAME="mscorefonts"
VERSION_PROVIDED="apt-managed"
CATEGORY="optional"
TAGS=("font" "desktop")
HOMEPAGE="https://packages.ubuntu.com/ttf-mscorefonts-installer"
declare -gA DESCRIPTION=(
    [en]="Microsoft core fonts — Times New Roman, Arial, Courier New, ... (apt ttf-mscorefonts-installer)"
    [zh-TW]="Microsoft 核心字型 — Times New Roman、Arial、Courier New 等(apt ttf-mscorefonts-installer)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Restart open applications so they pick up the new fonts (fc-list | grep -i 'Times New Roman')."
    [zh-TW]="請重新啟動已開啟的應用程式以載入新字型(fc-list | grep -i 'Times New Roman')。"
)
declare -gA WARN_MESSAGE=(
    [en]="Installing this module accepts the Microsoft core fonts EULA on your behalf (debconf preseed) and downloads the fonts from SourceForge at install time."
    [zh-TW]="安裝本模組即代為接受 Microsoft 核心字型授權條款(debconf 預設答案),並於安裝時從 SourceForge 下載字型。"
)
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="fc-list | grep -qi 'Times New Roman'"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt ───────────────────────────────────────────────────────
APT_PKGS=("ttf-mscorefonts-installer")
APT_PPA=""
CONFIG_PATHS=()
module_use_apt_archetype

# Where the package's postinst drops the fonts (overridable for tests).
: "${MSCOREFONTS_DIR:=/usr/share/fonts/truetype/msttcorefonts}"
# debconf question guarding the download (a Microsoft EULA — see header).
_MSCOREFONTS_EULA_SELECTION="ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true"

# The fonts are really on disk. dpkg's `ii` alone is NOT enough: with the EULA
# answer `false` the package is installed but the postinst removed every font.
_mscorefonts_present() {
    [[ -f "${MSCOREFONTS_DIR}/Times_New_Roman.ttf" ]] \
        || [[ -f "${MSCOREFONTS_DIR}/times.ttf" ]]
}

# ── Required hooks (detect + is_recommended stay module-specific) ────────────
detect() {
    command -v apt-get >/dev/null 2>&1
}

# Proprietary fonts with a licence prompt: never part of Quick Setup, install
# explicitly.
is_recommended() {
    return 1
}

# Overrides the archetype check: package present AND fonts present, so the
# "License refused" state is reported as not installed (and install heals it).
is_installed() {
    module_default_apt_is_installed && _mscorefonts_present
}

# ── Lifecycle override: install ─────────────────────────────────────────────
# Preseed the EULA answer, then install. When the package is already `ii` but
# the fonts are missing, a plain `apt-get install` is a no-op (postinst is not
# re-run), so use --reinstall. DEBIAN_FRONTEND is passed through `sudo env`
# because sudo strips the caller's environment.
install() {
    module_dryrun_guard install "preseed msttcorefonts EULA + apt-install ${APT_PKGS[*]} (downloads fonts from SourceForge)" \
        && return 0
    module_skip_if_installed && return 0

    if ! have_sudo_access 2>/dev/null; then
        log_warn "[${NAME}] no sudo: please install manually: ${APT_PKGS[*]}"
        return 1
    fi

    log_info "[${NAME}] preseed msttcorefonts EULA answer (accepts the Microsoft core fonts EULA)"
    printf '%s\n' "${_MSCOREFONTS_EULA_SELECTION}" | sudo debconf-set-selections \
        || { log_warn "[${NAME}] debconf-set-selections failed"; return 1; }

    sudo apt-get update -qq || log_warn "[${NAME}] apt-get update failed (continuing)"

    local -a _flags=(-y --no-install-recommends)
    if module_default_apt_is_installed; then
        log_info "[${NAME}] package present but fonts missing; reinstalling to re-run the downloader"
        _flags+=(--reinstall)
    fi
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install "${_flags[@]}" "${APT_PKGS[@]}" \
        || return 1

    if ! _mscorefonts_present; then
        log_warn "[${NAME}] fonts are still missing after install (download from SourceForge failed?)"
        return 1
    fi
    if command -v fc-cache >/dev/null 2>&1; then
        fc-cache -f >/dev/null 2>&1 || true
    fi
    return 0
}

# ── Real doctor (overrides the archetype default) ───────────────────────────
# The package must be installed with fonts on disk AND fontconfig must resolve
# "Times New Roman" to the real font (not a metric-compatible substitute such
# as Liberation Serif). Warns (read-only) on Sidecar drift (ADR-0001).
doctor() {
    module_dryrun_guard doctor "is_installed + fc-match 'Times New Roman' + Sidecar consistency" \
        && return 0
    if ! is_installed; then
        log_warn "[${NAME}] doctor: fonts are not installed (package present without fonts = EULA refused)"
        return 1
    fi
    if ! command -v fc-match >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: fc-match not found; cannot confirm fontconfig resolution"
        return 1
    fi
    if ! fc-match 'Times New Roman' 2>/dev/null | grep -qi 'Times New Roman'; then
        log_warn "[${NAME}] doctor: fontconfig does not resolve 'Times New Roman' to the real font (run: fc-cache -f)"
        return 1
    fi
    if ! module_sidecar_get_version "${NAME}" >/dev/null 2>&1; then
        log_warn "[${NAME}] doctor: Sidecar missing (ADR-0001 drift; re-run install/upgrade to heal)"
    fi
    return 0
}

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
