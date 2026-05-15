#!/usr/bin/env bash
# lib/registry.sh — module metadata scanner / registry
#
# Per docs/architecture.md §5 (Module Dynamic Loading) and docs/module-spec.md.
#
# Public API:
#   registry_load_all [<module-dir>]
#     Scan <module-dir>/*.module.sh (default: ${MODULE_DIR:-module}), source
#     each in a sub-shell to read metadata, populate associative arrays:
#       MODULES_NAME[name]               -> path to .module.sh
#       MODULES_CATEGORY[name]           -> base|recommended|optional|experimental
#       MODULES_DEPS[name]               -> space-separated dep names
#       MODULES_TAGS[name]               -> space-separated tags
#       MODULES_SUPPORTED_UBUNTU[name]   -> space-separated versions ("22.04 24.04")
#       MODULES_SUPPORTED_PLATFORMS[name]-> space-separated form factors
#       MODULES_CONFLICTS[name]          -> space-separated conflict names
#     Returns 0 on success, 1 if any module file fails to parse.
#
#   registry_get_field <name> <field>
#     field ∈ {file, category, deps, tags, ubuntu, platforms, conflicts}
#     prints the registered value (empty string if unregistered or unset).
#
#   registry_list_names [--category=<c>] [--tag=<t>]
#     Print registered module names, one per line, alphabetically sorted.
#
#   registry_has <name>
#     Return 0 if module is registered, 1 otherwise.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# Note: registry.sh does NOT declare its own `set -euo pipefail` to avoid
# fighting callers; callers (setup_ubuntu.sh, runner.sh, bats specs) set
# strict mode themselves.

# ── Storage (global, process-local) ──────────────────────────────────────────

declare -gA MODULES_NAME=()
declare -gA MODULES_CATEGORY=()
declare -gA MODULES_DEPS=()
declare -gA MODULES_TAGS=()
declare -gA MODULES_SUPPORTED_UBUNTU=()
declare -gA MODULES_SUPPORTED_PLATFORMS=()
declare -gA MODULES_CONFLICTS=()

# ── Internal: parse one module file in a sub-shell ───────────────────────────
#
# We source the module in a fresh `bash --noprofile --norc -c` so its
# `set -euo pipefail` / variable declarations don't pollute our shell. We
# then print metadata in KEY=VALUE format back to the parent.

_registry_parse_one() {
    local _file="${1:?_registry_parse_one needs <file>}"

    bash --noprofile --norc -c '
        set +e
        # shellcheck disable=SC1090
        source "$1" 2>/dev/null || exit 2

        printf "NAME=%s\n" "${NAME:-}"
        printf "CATEGORY=%s\n" "${CATEGORY:-}"
        printf "DEPS=%s\n" "${DEPENDS_ON[*]:-}"
        printf "TAGS=%s\n" "${TAGS[*]:-}"
        printf "UBUNTU=%s\n" "${SUPPORTED_UBUNTU[*]:-}"
        printf "PLATFORMS=%s\n" "${SUPPORTED_PLATFORMS[*]:-}"
        printf "CONFLICTS=%s\n" "${CONFLICTS_WITH[*]:-}"
    ' _registry_parse_one "${_file}"
}

# ── Public: scan and register all modules ────────────────────────────────────

# Internal helper: scan one dir into the global MODULES_* maps.
# Args: <dir> <is_user_local: 0|1>
# When is_user_local=1, name collisions with an already-registered bundled
# module emit a warn (the user-local entry wins by overwriting). Returns the
# failure count for callers to aggregate.
_registry_load_one_dir() {
    local _dir="${1:?_registry_load_one_dir needs <dir>}"
    local _is_user_local="${2:-0}"
    local _file _line _key _val _failed=0

    [[ -d "${_dir}" ]] || return 0

    # Collect *.module.sh entries without depending on `shopt -s nullglob`
    # (which would require save/restore via `shopt -p nullglob` — that exits
    # 1 when the option is unset, tripping `set -e` in bats test bodies).
    local -a _files=()
    local _glob
    for _glob in "${_dir}"/*.module.sh; do
        [[ -e "${_glob}" ]] || continue
        _files+=("${_glob}")
    done

    for _file in "${_files[@]}"; do
        local _name_parsed="" _category="" _deps="" _tags=""
        local _ubuntu="" _platforms="" _conflicts=""

        while IFS= read -r _line; do
            _key="${_line%%=*}"
            _val="${_line#*=}"
            case "${_key}" in
                NAME)      _name_parsed="${_val}" ;;
                CATEGORY)  _category="${_val}"    ;;
                DEPS)      _deps="${_val}"        ;;
                TAGS)      _tags="${_val}"        ;;
                UBUNTU)    _ubuntu="${_val}"      ;;
                PLATFORMS) _platforms="${_val}"   ;;
                CONFLICTS) _conflicts="${_val}"   ;;
            esac
        done < <(_registry_parse_one "${_file}")

        if [[ -z "${_name_parsed}" ]]; then
            printf "[registry] WARN: skipping %s (missing NAME)\n" "${_file##*/}" >&2
            _failed=$(( _failed + 1 ))
            continue
        fi

        local _expected_name="${_file##*/}"
        _expected_name="${_expected_name%.module.sh}"
        if [[ "${_name_parsed}" != "${_expected_name}" ]]; then
            printf "[registry] WARN: %s declares NAME=%s; expected %s (skipping)\n" \
                "${_file##*/}" "${_name_parsed}" "${_expected_name}" >&2
            _failed=$(( _failed + 1 ))
            continue
        fi

        # User-local override: emit log_warn when overwriting a bundled entry.
        # PRD §13.2 Q35 — user-local wins on collision.
        if (( _is_user_local == 1 )) && [[ -n "${MODULES_NAME[${_name_parsed}]:-}" ]]; then
            local _bundled_path="${MODULES_NAME[${_name_parsed}]}"
            if declare -F log_warn >/dev/null 2>&1; then
                log_warn "[registry] user-local override of bundled module '${_name_parsed}' (bundled=${_bundled_path}, user=${_file})"
            else
                printf "[registry] WARN: user-local override of bundled module '%s' (bundled=%s, user=%s)\n" \
                    "${_name_parsed}" "${_bundled_path}" "${_file}" >&2
            fi
        fi

        MODULES_NAME["${_name_parsed}"]="${_file}"
        MODULES_CATEGORY["${_name_parsed}"]="${_category}"
        MODULES_DEPS["${_name_parsed}"]="${_deps}"
        MODULES_TAGS["${_name_parsed}"]="${_tags}"
        MODULES_SUPPORTED_UBUNTU["${_name_parsed}"]="${_ubuntu}"
        MODULES_SUPPORTED_PLATFORMS["${_name_parsed}"]="${_platforms}"
        MODULES_CONFLICTS["${_name_parsed}"]="${_conflicts}"
    done

    return "${_failed}"
}

registry_load_all() {
    local _bundled_dir="${1:-${MODULE_DIR:-${REPO_ROOT:-.}/modules}}"
    local _user_dir="${INIT_UBUNTU_USER_MODULE_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/init_ubuntu/modules}"

    MODULES_NAME=()
    MODULES_CATEGORY=()
    MODULES_DEPS=()
    MODULES_TAGS=()
    MODULES_SUPPORTED_UBUNTU=()
    MODULES_SUPPORTED_PLATFORMS=()
    MODULES_CONFLICTS=()

    # Bundled first (so user-local wins on collision via overwrite + warn).
    # Per PRD §13.2 Q35 (user-local module discovery).
    local _failed_bundled=0 _failed_user=0
    _registry_load_one_dir "${_bundled_dir}" 0 || _failed_bundled=$?
    _registry_load_one_dir "${_user_dir}"    1 || _failed_user=$?

    return $(( _failed_bundled + _failed_user ))
}

# ── Public: get a specific field ─────────────────────────────────────────────

registry_get_field() {
    local _name="${1:?registry_get_field needs <name>}"
    local _field="${2:?registry_get_field needs <field>}"

    case "${_field}" in
        file)      printf "%s" "${MODULES_NAME[${_name}]:-}" ;;
        category)  printf "%s" "${MODULES_CATEGORY[${_name}]:-}" ;;
        deps)      printf "%s" "${MODULES_DEPS[${_name}]:-}" ;;
        tags)      printf "%s" "${MODULES_TAGS[${_name}]:-}" ;;
        ubuntu)    printf "%s" "${MODULES_SUPPORTED_UBUNTU[${_name}]:-}" ;;
        platforms) printf "%s" "${MODULES_SUPPORTED_PLATFORMS[${_name}]:-}" ;;
        conflicts) printf "%s" "${MODULES_CONFLICTS[${_name}]:-}" ;;
        *)
            printf "[registry] ERROR: unknown field %s\n" "${_field}" >&2
            return 1
            ;;
    esac
}

# ── Public: query helpers ────────────────────────────────────────────────────

registry_has() {
    local _name="${1:?registry_has needs <name>}"
    [[ -n "${MODULES_NAME[${_name}]:-}" ]]
}

registry_list_names() {
    local _category="" _tag=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --category=*) _category="${1#*=}"; shift ;;
            --tag=*)      _tag="${1#*=}"; shift ;;
            *) printf "[registry] ERROR: unknown flag %s\n" "$1" >&2; return 1 ;;
        esac
    done

    local _name
    for _name in "${!MODULES_NAME[@]}"; do
        if [[ -n "${_category}" && "${MODULES_CATEGORY[${_name}]:-}" != "${_category}" ]]; then
            continue
        fi
        if [[ -n "${_tag}" ]]; then
            local _haystack=" ${MODULES_TAGS[${_name}]:-} "
            [[ "${_haystack}" == *" ${_tag} "* ]] || continue
        fi
        printf "%s\n" "${_name}"
    done | sort
}
