#!/usr/bin/env bash
# lib/module_bootstrap.sh — shared dual-mode bootstrap for module/*.module.sh
#
# Every module used to carry ~17 identical header lines: set MODULE_STANDALONE
# by comparing BASH_SOURCE vs $0, then in standalone mode flip on strict mode,
# resolve MODULE_DIR / REPO_ROOT / LIB_DIR, and source logger.sh + general.sh +
# module_helper.sh. In engine mode lib/runner.sh has already sourced those three
# libs into the module sub-shell, so the block was skipped. That boilerplate is
# now centralized here so the per-module header collapses to a ~4-line stub.
#
# Contract (ADR-0001 standalone/engine boundary is preserved):
#   module_bootstrap
#     - Engine mode  (MODULE_STANDALONE != "true"): NO-OP. The runner already
#       sourced logger.sh / general.sh / module_helper.sh and set strict mode in
#       the sub-shell; re-sourcing or re-setting here would be redundant (the
#       lib guards make a re-source harmless, but we skip it outright).
#     - Standalone mode (MODULE_STANDALONE == "true"):
#         1. set -euo pipefail; shopt -s inherit_errexit  (byte-identical to the
#            old per-module header).
#         2. Resolve MODULE_DIR / REPO_ROOT / LIB_DIR (env vars take precedence,
#            so `LIB_DIR=/path bash module/foo.module.sh` keeps working) and
#            export them — module bodies read ${MODULE_DIR} for their config dir.
#         3. source logger.sh, general.sh, module_helper.sh — same files, same
#            order as before.
#
# Self-location: this file lives in lib/, so it derives LIB_DIR from its OWN
# ${BASH_SOURCE[0]} rather than the caller's. REPO_ROOT is LIB_DIR/.., and
# MODULE_DIR is REPO_ROOT/module. The standalone module file lives in module/,
# so REPO_ROOT/module equals the old `dirname "${module-file}"` result —
# behavior is unchanged for callers that read ${MODULE_DIR}.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not an executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# module_bootstrap — see file header for the full contract.
module_bootstrap() {
    # Engine mode: the runner already sourced the libs + set strict mode. No-op.
    [[ "${MODULE_STANDALONE:-false}" == "true" ]] || return 0

    set -euo pipefail
    shopt -s inherit_errexit 2>/dev/null || true

    # Self-locate from THIS file's path (lib/module_bootstrap.sh), independent
    # of the caller's BASH_SOURCE. Env vars take precedence so tests and
    # relocations keep working (same precedence as the old per-module header).
    local _self_lib
    _self_lib="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-}")" && pwd -P)"
    LIB_DIR="${LIB_DIR:-${_self_lib}}"
    REPO_ROOT="${REPO_ROOT:-$(cd -- "${LIB_DIR}/.." && pwd -P)}"
    MODULE_DIR="${MODULE_DIR:-${REPO_ROOT}/module}"
    export MODULE_DIR REPO_ROOT LIB_DIR

    # Same three libs, same order as the pre-extraction module header.
    # shellcheck source=logger.sh
    source "${LIB_DIR}/logger.sh"
    # shellcheck source=general.sh
    source "${LIB_DIR}/general.sh"
    # shellcheck source=module_helper.sh
    source "${LIB_DIR}/module_helper.sh"
}
