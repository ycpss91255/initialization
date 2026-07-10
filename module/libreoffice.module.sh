#!/usr/bin/env bash
# module/libreoffice.module.sh — LibreOffice office suite  [archetype: apt (PPA)]
#
# Adds LibreOffice via the upstream `ppa:libreoffice/ppa` (issue #312, from
# TODO.md "ADD items"). Explicit repository choice (issue #312, checkbox 2):
# the PPA is preferred over the distro archive package so the desktop tracks
# the fresh point releases the LibreOffice team publishes, rather than the
# older version frozen into a given Ubuntu release. The apt archetype adds the
# PPA before install and drops it again on purge, so the choice lives entirely
# in the APT_PPA field below.
#
# Desktop-only (SUPPORTED_PLATFORMS / is_recommended, Q49-style GUI gate): an
# office suite is pointless on headless server / WSL / SBC form factors.
#
# Standalone usage:
#   bash module/libreoffice.module.sh install [--dry-run]
#   bash module/libreoffice.module.sh upgrade / remove / purge / verify / doctor
#   bash module/libreoffice.module.sh detect / is-installed / is-recommended / is-outdated
#   bash module/libreoffice.module.sh info / status        (read-only metadata views)
#
# Engine usage (resolves DEPENDS_ON, batches with state.json):
#   setup_ubuntu install libreoffice

# ── BEGIN: shared-bootstrap ─────────────────────────────────────────────────
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
# ── END: shared-bootstrap ───────────────────────────────────────────────────

# ── Metadata (doc/module-spec.md §3) ────────────────────────────────────────
NAME="libreoffice"
VERSION_PROVIDED="ppa-managed"
CATEGORY="optional"
TAGS=("office" "gui")
HOMEPAGE="https://www.libreoffice.org/"
declare -gA DESCRIPTION=(
    [en]="LibreOffice office suite (fresh releases via ppa:libreoffice/ppa)"
    [zh-TW]="LibreOffice 辦公套件(透過 ppa:libreoffice/ppa 取得較新版本)"
)
declare -gA POST_INSTALL_MESSAGE=(
    [en]="Launch LibreOffice from your desktop menu (Writer / Calc / Impress)."
    [zh-TW]="從桌面選單啟動 LibreOffice(Writer / Calc / Impress)。"
)
declare -gA WARN_MESSAGE=()
SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")
SUPPORTED_PLATFORMS=("desktop")
DEPENDS_ON=()
CONFLICTS_WITH=()
SUPPORTS_USER_HOME=false
RISK_LEVEL="low"
REBOOT_REQUIRED=false
INSTALL_TARGET_DEFAULT="sudo"
TEST_VERIFY_CMD="command -v libreoffice && libreoffice --version"

# Engine-consumed metadata: the registry/runner read these post-source, and
# the i18n arrays are dereferenced indirectly via module_i18n_get. Reference
# them once so the linter sees an in-file use (SC2034) without a disable.
: "${DESCRIPTION[*]:-}" "${POST_INSTALL_MESSAGE[*]:-}" "${WARN_MESSAGE[*]:-}" \
    "${SUPPORTS_USER_HOME}" "${INSTALL_TARGET_DEFAULT}"

# ── Archetype A — apt (PPA) ─────────────────────────────────────────────────
# APT_PPA is added by module_default_apt_install before the package install and
# removed by module_default_apt_purge; CONFIG_PATHS is cleared on purge only.
APT_PKGS=("libreoffice")
APT_PPA="ppa:libreoffice/ppa"
CONFIG_PATHS=("${HOME}/.config/libreoffice")
module_use_apt_archetype

# ── Hand-written required hooks ─────────────────────────────────────────────
detect() {
    command -v apt-get >/dev/null 2>&1
}

# Desktop-only recommendation gate (GUI office suite): never pre-tick on
# headless / SBC form factors (doc/module-spec.md §4.3.1).
is_recommended() {
    case "${INIT_UBUNTU_FORM_FACTOR:-}" in
        desktop)
            ! is_installed
            ;;
        *)
            return 1
            ;;
    esac
}

# upgrade / remove / purge / verify / doctor / is_outdated / is_installed all
# come from the apt archetype macro above; the PPA teardown on purge is handled
# by module_default_apt_purge (APT_PPA), so no override is needed here.

# ── Standalone footer ───────────────────────────────────────────────────────
if [[ "${MODULE_STANDALONE:-false}" == "true" ]]; then
    module_standalone_main "$@"
fi
