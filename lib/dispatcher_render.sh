#!/usr/bin/env bash
# lib/dispatcher_render.sh — module-metadata → JSON / description renderers
#
# Extracted from lib/dispatcher.sh (architecture-review E1). This is the
# presentation cluster shared by the catalog (`list --json`) and state-io
# (`show --json`) views. It owns the ONE canonical implementation of each
# rendering primitive that used to be copy-pasted 3× inside dispatcher.sh:
#
#   _dispatcher_json_str_array   bash array  → JSON string array (jq-escaped)
#   _dispatcher_module_probe     source a module once → recommended + description
#   _dispatcher_module_description  localized DESCRIPTION for a module
#   _dispatcher_show_json        single-module metadata object (issue #211)
#   _dispatcher_list_catalog_json  registry catalog {"items":[...]} (issue #165)
#
# Sourced by lib/dispatcher.sh; not an executable script.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# ── JSON primitives ──────────────────────────────────────────────────────────

# Render the given positional args as a JSON string array. jq escapes every
# element (never hand-rolled). No args → `[]`. Callers pass whitespace-split
# registry fields, empty-safe via "${arr[@]+"${arr[@]}"}".
_dispatcher_json_str_array() {
    jq -cn '$ARGS.positional' --args "$@"
}

# Source a module ONCE in an isolated fork-style subshell and emit, on stdout:
#   line 1:   recommended token — true | false | null
#   line 2+:  the localized DESCRIPTION (may be empty / absent)
#
# The subshell keeps declares / traps scoped and keeps set -u + coverage
# instrumentation happy (same rationale as the runner), and stays fully offline
# (no network). Honors INIT_UBUNTU_LANG via module_get_description →
# module_i18n_get. A missing / unreadable module file, or a module that omits
# both is_recommended and DESCRIPTION, degrades to "null\n" (recommended null,
# empty description) — additive fields are optional (ADR-0019).
_dispatcher_module_probe() {
    local _file="$1" _lang="${2:-${INIT_UBUNTU_LANG:-en}}"
    if [[ -z "${_file}" || ! -f "${_file}" ]]; then
        printf 'null\n'
        return 0
    fi
    (
        # shellcheck source=/dev/null  # module path is dynamic; static resolution impossible — https://www.shellcheck.net/wiki/SC1090
        source "${LIB_DIR}/logger.sh" >/dev/null 2>&1
        # shellcheck source=/dev/null  # dynamic lib path
        source "${LIB_DIR}/general.sh" >/dev/null 2>&1
        # shellcheck source=/dev/null  # dynamic lib path
        source "${LIB_DIR}/module_helper.sh" >/dev/null 2>&1
        # shellcheck source=/dev/null  # module path is dynamic
        source "${_file}" >/dev/null 2>&1 || { printf 'null\n'; exit 0; }
        _r="null"
        if declare -F is_recommended >/dev/null 2>&1; then
            if is_recommended >/dev/null 2>&1; then _r="true"; else _r="false"; fi
        fi
        printf '%s\n' "${_r}"
        if declare -F module_get_description >/dev/null 2>&1; then
            module_get_description "${_lang}" 2>/dev/null
        fi
    )
}

# Localized module DESCRIPTION for `show` (issue #183). Thin projection over
# _dispatcher_module_probe: drop the recommended token (line 1) and emit only
# the description (line 2+). Prints nothing when the module file is missing or
# exposes no DESCRIPTION.
_dispatcher_module_description() {
    local _file="$1" _lang="${INIT_UBUNTU_LANG:-en}"
    local _probe; _probe="$(_dispatcher_module_probe "${_file}" "${_lang}")"
    if [[ "${_probe}" == *$'\n'* ]]; then
        printf '%s' "${_probe#*$'\n'}"
    fi
}

# ── Single-module detail object (issue #211) ─────────────────────────────────
# Machine-readable detail for a single module. stdout is ONLY a single JSON
# object; warnings/errors stay on stderr (same guarantee as list --json). All
# strings/arrays are escaped by jq. description is sourced in the isolated
# fork-style subshell and degrades to JSON null when the module omits it
# (additive fields are optional, ADR-0019). JSON keys use the canonical
# module-spec snake_case (depends_on / conflicts / supported_ubuntu /
# supported_platforms) — the names issue #211 expects.
_dispatcher_show_json() {
    local _name="$1"
    local _file; _file="$(registry_get_field "${_name}" file)"
    local _cat;  _cat="$(registry_get_field "${_name}" category)"

    local -a _tags_arr _deps_arr _conf_arr _ubuntu_arr _plats_arr
    read -r -a _tags_arr   <<< "$(registry_get_field "${_name}" tags)"
    read -r -a _deps_arr   <<< "$(registry_get_field "${_name}" deps)"
    read -r -a _conf_arr   <<< "$(registry_get_field "${_name}" conflicts)"
    read -r -a _ubuntu_arr <<< "$(registry_get_field "${_name}" ubuntu)"
    read -r -a _plats_arr  <<< "$(registry_get_field "${_name}" platforms)"

    local _tags_json _deps_json _conf_json _ubuntu_json _plats_json
    _tags_json="$(_dispatcher_json_str_array   "${_tags_arr[@]+"${_tags_arr[@]}"}")"
    _deps_json="$(_dispatcher_json_str_array   "${_deps_arr[@]+"${_deps_arr[@]}"}")"
    _conf_json="$(_dispatcher_json_str_array   "${_conf_arr[@]+"${_conf_arr[@]}"}")"
    _ubuntu_json="$(_dispatcher_json_str_array "${_ubuntu_arr[@]+"${_ubuntu_arr[@]}"}")"
    _plats_json="$(_dispatcher_json_str_array  "${_plats_arr[@]+"${_plats_arr[@]}"}")"

    # description is a JSON string or null (empty/missing → null).
    local _desc; _desc="$(_dispatcher_module_description "${_file}")"
    local _desc_json='null'
    [[ -n "${_desc}" ]] && _desc_json="$(jq -cn --arg d "${_desc}" '$d')"

    jq -cn \
        --arg name "${_name}" \
        --arg category "${_cat}" \
        --argjson description "${_desc_json}" \
        --argjson tags "${_tags_json}" \
        --argjson depends_on "${_deps_json}" \
        --argjson conflicts "${_conf_json}" \
        --argjson supported_ubuntu "${_ubuntu_json}" \
        --argjson supported_platforms "${_plats_json}" \
        '{name:$name, category:$category, description:$description,
          tags:$tags, depends_on:$depends_on, conflicts:$conflicts,
          supported_ubuntu:$supported_ubuntu,
          supported_platforms:$supported_platforms}'
}

# ── Catalog view (issue #165, ADR-0019 / G4) ─────────────────────────────────
# Emits ONLY a JSON document to stdout that the TUI (lib/tui_backend.sh) can
# parse:
#
#   { "items": [ { "name", "category", "tags":[...],
#                  "supported_platforms":[...], "description", "recommended" }, ... ] }
#
# Honors the same --category= / --tag= filters as the plain list view (applied
# by the caller before handing us the pre-filtered name list). All strings are
# escaped by jq (never hand-rolled). description / recommended are sourced
# per-module via _dispatcher_module_probe and degrade to JSON null when the
# module omits them or errs (additive fields are optional, ADR-0019).
_dispatcher_list_catalog_json() {
    local -n _names_ref="$1"

    local _lang="${INIT_UBUNTU_LANG:-en}"
    local -a _rows=()
    local _name _cat _tags_raw _plats_raw _file _desc _rec
    local -a _tags_arr _plats_arr

    while IFS= read -r _name; do
        [[ -n "${_name}" ]] || continue
        _cat="$(registry_get_field "${_name}" category)"
        _tags_raw="$(registry_get_field "${_name}" tags)"
        _plats_raw="$(registry_get_field "${_name}" platforms)"
        _file="$(registry_get_field "${_name}" file)"

        # Whitespace-split into arrays; empty → empty array.
        read -r -a _tags_arr <<< "${_tags_raw}"
        read -r -a _plats_arr <<< "${_plats_raw}"

        # description + recommended come from the module itself, sourced once in
        # an isolated subshell. Probe protocol: "<recommended-token>\n<desc...>".
        # recommended token: true | false | null. A missing description leaves
        # nothing after the newline → treated as null below.
        _desc=""
        _rec="null"
        local _probe; _probe="$(_dispatcher_module_probe "${_file}" "${_lang}")"
        _rec="${_probe%%$'\n'*}"
        case "${_rec}" in true|false|null) ;; *) _rec="null" ;; esac
        if [[ "${_probe}" == *$'\n'* ]]; then
            _desc="${_probe#*$'\n'}"
        else
            _desc=""
        fi

        # tags / supported_platforms → JSON arrays (jq escapes each element).
        local _tags_json _plats_json
        _tags_json="$(_dispatcher_json_str_array "${_tags_arr[@]+"${_tags_arr[@]}"}")"
        _plats_json="$(_dispatcher_json_str_array "${_plats_arr[@]+"${_plats_arr[@]}"}")"

        # Per-item object: jq escapes every string. description is passed as a
        # JSON value (string or null); recommended is raw JSON (true/false/null).
        local _desc_json='null'
        [[ -n "${_desc}" ]] && _desc_json="$(jq -cn --arg d "${_desc}" '$d')"

        local _row
        _row="$(jq -cn \
            --arg name "${_name}" \
            --arg category "${_cat}" \
            --argjson tags "${_tags_json}" \
            --argjson supported_platforms "${_plats_json}" \
            --argjson description "${_desc_json}" \
            --argjson recommended "${_rec}" \
            '{name:$name, category:$category, tags:$tags,
              supported_platforms:$supported_platforms,
              description:$description, recommended:$recommended}')"
        _rows+=("${_row}")
    done <<< "${_names_ref}"

    # Combine all per-item objects into the final {"items":[...]} document.
    printf '%s\n' "${_rows[@]+"${_rows[@]}"}" | jq -s '{items: .}'
}
