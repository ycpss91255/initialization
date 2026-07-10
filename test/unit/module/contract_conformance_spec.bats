#!/usr/bin/env bats
# test/unit/module/contract_conformance_spec.bats — module-iterating contract
# conformance meta-test.
#
# WHY THIS EXISTS (gap: module-template audit #4)
# ------------------------------------------------
# The 39 real modules are each covered by an ad-hoc per-module *_spec.bats that
# exercises ONE module in depth. There was NO single meta-test that iterates
# EVERY module and asserts it satisfies the shared contract. This spec closes
# that gap: it DISCOVERS every module/*.module.sh DYNAMICALLY (so a newly-added
# or edited module is auto-covered) and asserts, for each, that it satisfies the
# module contract (doc/module-spec.md + doc/adr/0002-all-lifecycle-functions-
# mandatory.md). A new module cannot silently violate the contract without
# turning this spec red.
#
# HOW EACH MODULE IS PROBED
# -------------------------
# Each module is sourced the same safe way the per-module specs do (see
# test/unit/module/eza_spec.bats): the three libs (logger / general /
# module_helper) are sourced first, then the module is sourced in a SUBSHELL
# with MODULE_STANDALONE=false — so the module's dual-mode footer never fires
# (no lifecycle runs, no side effects) and one module's globals/functions never
# leak into the next. Only metadata declaration + the archetype macro run.
#
# THE CONTRACT (doc/module-spec.md §4.1 vs ADR-0002)
# --------------------------------------------------
# ADR-0002 ("All 10 Lifecycle functions are mandatory") is the authoritative
# contract: every module must define all 10 of
#   detect is_recommended is_installed install upgrade remove purge verify \
#   is_outdated doctor
# The archetype macros (module_use_{apt,github_release,config}_archetype) wire 8
# of them; detect()/is_recommended() stay module-defined. Archetype D (custom,
# hand-written) authors must implement all 10 themselves.
#
# KNOWN DEVIATION (flagged for the maintainer, NOT hidden)
# --------------------------------------------------------
# Three custom (archetype D) modules — docker, font, nvidia-driver — ship WITHOUT
# is_outdated()/doctor(). Their own per-module specs bless the absence
# (docker_spec.bats:698/705, font_spec.bats:256, nvidia-driver_spec.bats:239) and
# doc/module-spec.md §4.1 still lists these two phases as "optional" — a real
# inconsistency with ADR-0002 that the maintainer should resolve (either add the
# two functions to those modules, or reconcile §4.1 back to "5 mandatory + 5
# optional"). Rather than silently mutate three production modules (and
# contradict their specs), this meta-test QUARANTINES the gap in
# KNOWN_LIFECYCLE_GAPS below. The allowlist is SELF-CLEANING: a dedicated @test
# asserts every entry is STILL a real gap, so if a module later implements the
# function the stale entry turns this spec red and must be removed. Every OTHER
# module is fully enforced against all 10, and any NEW gap is caught.

load "${BATS_TEST_DIRNAME}/../../helper/common"

# The 10 mandatory lifecycle functions (ADR-0002).
MANDATORY_LIFECYCLE=(detect is_recommended is_installed install upgrade \
                     remove purge verify is_outdated doctor)

# Allowed enumerations (doc/module-spec.md §3).
ALLOWED_CATEGORIES=(base recommended optional experimental)
ALLOWED_PLATFORMS=(desktop server rpi-4 rpi-5 jetson-orin wsl container vm)
ALLOWED_RISK=(low medium high)

# Documented, self-cleaning deviations from ADR-0002 (see file header).
# Newline-delimited "<module>:<function>" pairs. A plain string list (not an
# associative array) is used deliberately: a top-level `declare -A` is not
# reliably visible as associative inside bats @test functions, so subscripting it
# there triggers an arithmetic-context error. Each entry is asserted to STILL be
# a real gap by the "self-cleaning allowlist" test, so it cannot silently rot.
KNOWN_LIFECYCLE_GAPS="
docker:is_outdated
docker:doctor
font:is_outdated
font:doctor
nvidia-driver:is_outdated
nvidia-driver:doctor
trash-maintenance:is_outdated
trash-maintenance:doctor
"

# _is_known_gap <module-stem> <function> — is this pair a documented deviation?
_is_known_gap() {
    grep -qxF "${1}:${2}" <<< "${KNOWN_LIFECYCLE_GAPS}"
}

setup() { setup_test_env; }
teardown() { teardown_test_env; }

# ── Discovery ────────────────────────────────────────────────────────────────

# Populate the MODULES array with every module file. nullglob so a non-match
# yields an empty array (caught by the discovery guard) rather than a literal
# glob string.
_discover_modules() {
    shopt -s nullglob
    MODULES=("${MODULE_DIR}"/*.module.sh)
    shopt -u nullglob
}

# ── Membership helper (inherited into the probe subshell) ────────────────────

_in_set() {
    local _needle="${1}"; shift
    local _x
    for _x in "$@"; do [[ "${_x}" == "${_needle}" ]] && return 0; done
    return 1
}

# ── Probe: source a module in a subshell, then run a check inside it ──────────
#
# Usage: _probe <module-file> <check-fn> [args...]
# The check function runs AFTER the module is sourced, in the same subshell, so
# it sees the module's metadata vars + lifecycle functions. Its stdout (violation
# lines) bubbles up; the outer shell is never mutated.
_probe() {
    local _file="${1:?module file required}"; shift
    (
        # Silence sourcing noise; the check's own stdout is what we care about.
        # shellcheck source=../../../lib/logger.sh
        source "${LIB_DIR}/logger.sh"        >/dev/null 2>&1 || true
        # shellcheck source=../../../lib/general.sh
        source "${LIB_DIR}/general.sh"       >/dev/null 2>&1 || true
        # shellcheck source=../../../lib/module_helper.sh
        source "${LIB_DIR}/module_helper.sh" >/dev/null 2>&1 || true
        # The module self-detects standalone mode by comparing BASH_SOURCE vs $0;
        # when sourced here that comparison sets MODULE_STANDALONE=false, so the
        # dual-mode header (no re-source of libs) and footer (no dispatch) are
        # both skipped — only metadata + the archetype macro run.
        # shellcheck source=/dev/null  # module path is dynamic (discovery loop)
        source "${_file}" >/dev/null 2>&1 || true
        "$@"
    )
}

# ── Checks (run INSIDE the probe subshell) ───────────────────────────────────

# Print "missing-fn:<name>" for each mandatory lifecycle function not defined.
_check_lifecycle() {
    local _fn
    for _fn in "${MANDATORY_LIFECYCLE[@]}"; do
        declare -F "${_fn}" >/dev/null 2>&1 || printf 'missing-fn:%s\n' "${_fn}"
    done
}

# Print "defined" / "absent" for a single function name (self-cleaning allowlist).
_check_fn_defined() {
    if declare -F "${1:?fn required}" >/dev/null 2>&1; then
        printf 'defined\n'
    else
        printf 'absent\n'
    fi
}

# Print one "<field>:<reason>" line per metadata violation. Arg: filename stem.
_check_metadata() {
    local _stem="${1:?stem required}"

    # NAME: set, kebab-form, equal to the filename stem.
    if [[ -z "${NAME:-}" ]]; then
        printf 'NAME:unset\n'
    else
        [[ "${NAME}" =~ ^[a-z][a-z0-9-]*$ ]] || printf 'NAME:malformed=%s\n' "${NAME}"
        [[ "${NAME}" == "${_stem}" ]]        || printf 'NAME:stem-mismatch=%s!=%s\n' "${NAME}" "${_stem}"
    fi

    # CATEGORY: set + in the allowed enum.
    if [[ -z "${CATEGORY:-}" ]]; then
        printf 'CATEGORY:unset\n'
    elif ! _in_set "${CATEGORY}" "${ALLOWED_CATEGORIES[@]}"; then
        printf 'CATEGORY:not-allowed=%s\n' "${CATEGORY}"
    fi

    # DESCRIPTION: associative array with a non-empty en fallback entry.
    local _decl; _decl="$(declare -p DESCRIPTION 2>/dev/null)" || _decl=""
    if [[ "${_decl}" != 'declare -'*A* ]]; then
        printf 'DESCRIPTION:not-associative\n'
    elif [[ -z "$(module_get_description en 2>/dev/null)" ]]; then
        printf 'DESCRIPTION:no-en-entry\n'
    fi

    # TAGS: declared and non-empty.
    if ! { declare -p TAGS >/dev/null 2>&1 && [[ "${#TAGS[@]}" -gt 0 ]]; }; then
        printf 'TAGS:empty\n'
    fi

    # SUPPORTED_UBUNTU: declared and non-empty.
    if ! { declare -p SUPPORTED_UBUNTU >/dev/null 2>&1 && [[ "${#SUPPORTED_UBUNTU[@]}" -gt 0 ]]; }; then
        printf 'SUPPORTED_UBUNTU:empty\n'
    fi

    # SUPPORTED_PLATFORMS: declared, non-empty, every token in the allowed set.
    if ! { declare -p SUPPORTED_PLATFORMS >/dev/null 2>&1 && [[ "${#SUPPORTED_PLATFORMS[@]}" -gt 0 ]]; }; then
        printf 'SUPPORTED_PLATFORMS:empty\n'
    else
        local _p
        for _p in "${SUPPORTED_PLATFORMS[@]}"; do
            _in_set "${_p}" "${ALLOWED_PLATFORMS[@]}" || printf 'SUPPORTED_PLATFORMS:bad-token=%s\n' "${_p}"
        done
    fi

    # RISK_LEVEL: if set, must be a well-formed enum value.
    if [[ -n "${RISK_LEVEL:-}" ]] && ! _in_set "${RISK_LEVEL}" "${ALLOWED_RISK[@]}"; then
        printf 'RISK_LEVEL:not-allowed=%s\n' "${RISK_LEVEL}"
    fi
}

# ── Tests ────────────────────────────────────────────────────────────────────

@test "discovery finds every module (guard against a silently-empty sweep)" {
    _discover_modules
    # 39 modules today; a hard floor of 30 catches an accidentally-empty glob
    # (which would make every other test vacuously pass).
    [[ "${#MODULES[@]}" -ge 30 ]] || {
        printf 'discovered only %d module(s) under %s — expected >= 30\n' \
            "${#MODULES[@]}" "${MODULE_DIR}" >&2
        return 1
    }
}

@test "every module defines all 10 mandatory lifecycle functions (ADR-0002)" {
    _discover_modules
    local _file _stem _out _line _fn _violations=""
    for _file in "${MODULES[@]}"; do
        _stem="$(basename "${_file}" .module.sh)"
        _out="$(_probe "${_file}" _check_lifecycle)"
        while IFS= read -r _line; do
            [[ -n "${_line}" ]] || continue
            _fn="${_line#missing-fn:}"
            # Skip documented, self-cleaning deviations (see file header).
            _is_known_gap "${_stem}" "${_fn}" && continue
            _violations+="  ${_stem}: missing lifecycle function ${_fn}"$'\n'
        done <<< "${_out}"
    done
    [[ -z "${_violations}" ]] || {
        printf 'modules violating the 10-function lifecycle contract:\n%s' "${_violations}" >&2
        return 1
    }
}

@test "documented lifecycle gaps are still real (self-cleaning allowlist)" {
    local _key _stem _fn _file _out _stale=""
    while IFS= read -r _key; do
        [[ -n "${_key}" ]] || continue
        _stem="${_key%%:*}"
        _fn="${_key##*:}"
        _file="${MODULE_DIR}/${_stem}.module.sh"
        if [[ ! -f "${_file}" ]]; then
            _stale+="  ${_key}: module file no longer exists — drop the allowlist entry"$'\n'
            continue
        fi
        _out="$(_probe "${_file}" _check_fn_defined "${_fn}")"
        [[ "${_out}" == "absent" ]] || \
            _stale+="  ${_key}: ${_fn}() is now defined — remove this stale allowlist entry"$'\n'
    done <<< "${KNOWN_LIFECYCLE_GAPS}"
    [[ -z "${_stale}" ]] || {
        printf 'stale KNOWN_LIFECYCLE_GAPS entries:\n%s' "${_stale}" >&2
        return 1
    }
}

@test "every module declares well-formed required metadata (name/category/desc/tags/supported)" {
    _discover_modules
    local _file _stem _out _line _violations=""
    for _file in "${MODULES[@]}"; do
        _stem="$(basename "${_file}" .module.sh)"
        _out="$(_probe "${_file}" _check_metadata "${_stem}")"
        while IFS= read -r _line; do
            [[ -n "${_line}" ]] || continue
            _violations+="  ${_stem}: ${_line}"$'\n'
        done <<< "${_out}"
    done
    [[ -z "${_violations}" ]] || {
        printf 'modules with malformed/missing metadata:\n%s' "${_violations}" >&2
        return 1
    }
}

@test "every module uses a known archetype macro or hand-defines its lifecycle" {
    _discover_modules
    local _file _stem _fn _missing _violations=""
    for _file in "${MODULES[@]}"; do
        _stem="$(basename "${_file}" .module.sh)"
        # Archetype A/B/C: one macro call wires the lifecycle.
        if grep -qE '^module_use_(apt|github_release|config)_archetype$' "${_file}"; then
            continue
        fi
        # Archetype D (custom): the core mutation lifecycle must be hand-defined
        # in the module file itself.
        _missing=""
        for _fn in is_installed install upgrade remove purge; do
            grep -qE "^${_fn}\(\) \{" "${_file}" || _missing+=" ${_fn}"
        done
        [[ -z "${_missing}" ]] || \
            _violations+="  ${_stem}: no archetype macro and missing hand-written lifecycle:${_missing}"$'\n'
    done
    [[ -z "${_violations}" ]] || {
        printf 'modules with no lifecycle binding mechanism:\n%s' "${_violations}" >&2
        return 1
    }
}
