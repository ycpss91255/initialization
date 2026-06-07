#!/usr/bin/env bash
# select_unit_matrix.sh — Decide which unit-test jobs a CI run needs
#
# Consumed by the `discover` job in .github/workflows/ci.yaml (issue #31,
# PRD M10). Takes the event name and the JSON array of matched
# paths-filter names (from generate_module_filters.sh filters) and emits
# GITHUB_OUTPUT-style lines:
#
#   modules=["docker","fish"]    JSON array for the test-module matrix
#   core=true|false              whether the `test-unit (core)` job runs
#   full=true|false              whether the selection is the FULL
#                                cartesian (every module + core). The
#                                coverage merge job keys on this: only
#                                full-matrix runs enforce the coverage
#                                gate; narrow PR matrices are report-only
#                                (issue #28 — unrun shards' files still
#                                count in the merged denominator)
#
# Selection rules:
#   1. push event (main / tags)        → full matrix + core
#   2. 'shared' filter matched         → full matrix + core (lib/, script/,
#                                        Makefile, … affect every job)
#   3. no relevant filter matched      → full matrix + core (conservative
#                                        fallback: a code change outside the
#                                        known filters must not silently
#                                        skip unit tests; doc-only changes
#                                        never reach the jobs anyway — the
#                                        `code` gate skips them)
#   4. otherwise                       → matched 'module-<X>' filters
#                                        (intersected with existing
#                                        modules) + core iff 'core' matched
#
# Env:
#   INIT_UBUNTU_MODULE_DIR  Override the module dir scanned for
#                           *.module.sh (tests use a fixture dir).
#
# Usage:
#   ./script/ci/select_unit_matrix.sh --event pull_request \
#       --changed '["module-docker","core"]' >> "$GITHUB_OUTPUT"

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
readonly REPO_ROOT

MODULE_DIR="${INIT_UBUNTU_MODULE_DIR:-${REPO_ROOT}/module}"

_die() { printf '[select-unit-matrix] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat >&2 <<'EOF'
Usage: select_unit_matrix.sh --event <event_name> --changed <json-array>

  --event    GitHub event name (push / pull_request / …)
  --changed  JSON array of matched paths-filter names, e.g.
             '["shared","module-docker","core"]'

Emits `modules=<json-array>`, `core=<bool>` and `full=<bool>` lines on stdout.
EOF
    exit 0
}

# JSON array of every module name discovered from <module-dir>/*.module.sh.
_all_modules_json() {
    local -a _names=()
    local _f
    for _f in "${MODULE_DIR}"/*.module.sh; do
        [[ -e "${_f}" ]] || continue  # empty dir: nullglob not set
        _names+=("$(basename "${_f}" .module.sh)")
    done
    if [[ "${#_names[@]}" -eq 0 ]]; then
        printf '[]'
        return 0
    fi
    printf '%s\n' "${_names[@]}" | jq -R -s -c 'split("\n")[:-1]'
}

main() {
    local event="" changed=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage ;;
            --event)
                [[ $# -ge 2 ]] || _die "--event requires a value"
                event="$2"; shift 2 ;;
            --changed)
                [[ $# -ge 2 ]] || _die "--changed requires a value"
                changed="$2"; shift 2 ;;
            *) _die "Unknown option: $1" ;;
        esac
    done

    [[ -n "${event}" ]] || _die "--event is required"
    [[ -n "${changed}" ]] || changed='[]'
    jq -e 'type == "array"' <<<"${changed}" >/dev/null 2>&1 \
        || _die "--changed must be a JSON array, got: ${changed}"

    local all_json
    all_json="$(_all_modules_json)"

    # Rule 1+2: push or shared change → everything.
    # Rule 3: nothing relevant matched → everything (conservative fallback).
    local relevant
    relevant="$(jq -c '[.[] | select(. == "shared" or . == "core"
                                     or startswith("module-"))]' <<<"${changed}")"
    if [[ "${event}" == "push" ]] \
        || jq -e 'index("shared")' <<<"${changed}" >/dev/null \
        || [[ "${relevant}" == "[]" ]]; then
        printf 'modules=%s\n' "${all_json}"
        printf 'core=true\n'
        printf 'full=true\n'
        return 0
    fi

    # Rule 4: only the matched module-<X> filters (∩ discovered modules)
    # + core iff its filter matched. `full` stays honest even here: a PR
    # whose matched filters happen to cover every module + core IS a
    # full-cartesian run (both arrays are sorted, so string-compare works).
    local mods core full
    mods="$(jq -c --argjson all "${all_json}" \
        '[.[] | select(startswith("module-")) | sub("^module-"; "")]
         | map(select(. as $m | $all | index($m))) | sort' <<<"${changed}")"
    core="$(jq -r 'index("core") != null' <<<"${changed}")"
    full="false"
    [[ "${core}" == "true" && "${mods}" == "${all_json}" ]] && full="true"
    printf 'modules=%s\n' "${mods}"
    printf 'core=%s\n' "${core}"
    printf 'full=%s\n' "${full}"
}

main "$@"
