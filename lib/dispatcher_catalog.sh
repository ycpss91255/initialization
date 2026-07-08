#!/usr/bin/env bash
# lib/dispatcher_catalog.sh — read-only catalog / introspection subcommands
#
# Extracted from lib/dispatcher.sh (architecture-review E1). This is the
# read-mostly cluster: it inspects the in-memory registry, state.json, and the
# host environment without mutating anything.
#
#   _dispatcher_list_installed   list --installed (state.json view; PRD §7.2)
#   _dispatcher_list             list (registry view + catalog --json, #165)
#   _dispatcher_show             show <module> (human table + --json, #211)
#   _dispatcher_search           search <keyword>
#   _dispatcher_detect           detect (host environment; --json)
#
# JSON rendering primitives live in lib/dispatcher_render.sh. Sourced by
# lib/dispatcher.sh; not an executable script.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# ── list / show ──────────────────────────────────────────────────────────────

# _dispatcher_installed_version <name> — the single source of truth for a
# module's INSTALLED version. The Sidecar (module_sidecar_get_version) records
# the RESOLVED version pinned at install time (e.g. 0.44.1); state.json only
# keeps the static VERSION_PROVIDED literal the module declared (often the
# "latest" sentinel). Prefer the Sidecar so `list --installed` shows what is
# actually on disk (architecture-review F2). Fall back to state.json's
# version_provided only when no Sidecar exists — a module that records none, or
# an entry installed before Sidecars existed. NOTE: version_provided keeps its
# meaning as the catalog/declared version; only the INSTALLED display changes.
_dispatcher_installed_version() {
    local _name="$1"
    local _ver
    if declare -F module_sidecar_get_version >/dev/null 2>&1; then
        if _ver="$(module_sidecar_get_version "${_name}" 2>/dev/null)" \
            && [[ -n "${_ver}" ]]; then
            printf '%s' "${_ver}"
            return 0
        fi
    fi
    state_get_field "${_name}" version_provided
}

# list --installed [--json] — the state.json view (replaces `status`, PRD §7.2).
_dispatcher_list_installed() {
    local _json="${1:-false}"

    if ! declare -F state_list_installed >/dev/null 2>&1; then
        printf "[dispatcher] ERROR: state lib not loaded\n" >&2
        return 1
    fi

    if [[ "${_json}" == "true" ]]; then
        local _state_path; _state_path="$(state_get_path)"
        if [[ -f "${_state_path}" ]]; then
            cat "${_state_path}"
        else
            printf '{"version":"%s","installed":{}}\n' "${STATE_SCHEMA_VERSION}"
        fi
        return 0
    fi

    local _names; _names="$(state_list_installed)"
    if [[ -z "${_names}" ]]; then
        printf '%s\n' "$(i18n_t DISPATCHER_I18N no_installed)"
        return 0
    fi
    printf "%-30s  %-7s  %-12s  %s\n" "MODULE" "MANUAL" "VERSION" "INSTALLED AT"
    local _n _manual _ver _at
    while IFS= read -r _n; do
        _manual="$(state_get_field "${_n}" manual)"
        _ver="$(_dispatcher_installed_version "${_n}")"
        _at="$(state_get_field "${_n}" installed_at)"
        printf "%-30s  %-7s  %-12s  %s\n" "${_n}" "${_manual}" "${_ver}" "${_at}"
    done <<< "${_names}"
}

_dispatcher_list() {
    local -a _filter_args=()
    local _installed="false"
    local _json="false"
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            --category=*|--tag=*) _filter_args+=("${_arg}") ;;
            --installed) _installed="true" ;;
            --json)      _json="true" ;;
            --available|--upgradable)
                printf "[dispatcher] WARN: %s is stubbed; ignoring\n" "${_arg}" >&2
                ;;
            *)
                printf "[dispatcher] ERROR: unknown flag %s\n" "${_arg}" >&2
                return 2
                ;;
        esac
    done

    if [[ "${_installed}" == "true" ]]; then
        _dispatcher_list_installed "${_json}"
        return $?
    fi

    if ! declare -F registry_list_names >/dev/null 2>&1; then
        printf "[dispatcher] ERROR: registry not loaded\n" >&2
        return 1
    fi

    local _names
    _names="$(registry_list_names "${_filter_args[@]}")"

    # Catalog JSON view (issue #165): stdout is ONLY JSON. An empty registry
    # still emits a well-formed {"items":[]} so the TUI parses cleanly.
    if [[ "${_json}" == "true" ]]; then
        if [[ -z "${_names}" ]]; then
            printf '{"items":[]}\n'
            return 0
        fi
        _dispatcher_list_catalog_json _names
        return $?
    fi

    if [[ -z "${_names}" ]]; then
        printf '%s\n' "$(i18n_t DISPATCHER_I18N no_registered)"
        return 0
    fi

    printf "%-30s  %-13s  %s\n" "NAME" "CATEGORY" "TAGS"
    local _name _cat _tags
    while IFS= read -r _name; do
        _cat="$(registry_get_field "${_name}" category)"
        _tags="$(registry_get_field "${_name}" tags)"
        printf "%-30s  %-13s  %s\n" "${_name}" "${_cat:-?}" "${_tags:-}"
    done <<< "${_names}"
}

_dispatcher_show() {
    local _name="" _json="false"
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            --json) _json="true" ;;
            -*)
                printf "[dispatcher] ERROR: unknown flag %s\n" "${_arg}" >&2
                return 2
                ;;
            *) _name="${_arg}" ;;
        esac
    done

    if [[ -z "${_name}" ]]; then
        printf "[dispatcher] ERROR: show requires <module>\n" >&2
        return 2
    fi
    if ! registry_has "${_name}"; then
        printf "[dispatcher] ERROR: unknown module %s\n" "${_name}" >&2
        return 2
    fi

    if [[ "${_json}" == "true" ]]; then
        _dispatcher_show_json "${_name}"
        return $?
    fi

    local _file; _file="$(registry_get_field "${_name}" file)"
    printf "name:        %s\n"  "${_name}"
    printf "file:        %s\n"  "${_file}"
    printf "description: %s\n"  "$(_dispatcher_module_description "${_file}")"
    printf "category:    %s\n"  "$(registry_get_field "${_name}" category)"
    printf "tags:        %s\n"  "$(registry_get_field "${_name}" tags)"
    printf "deps:        %s\n"  "$(registry_get_field "${_name}" deps)"
    printf "conflicts:   %s\n"  "$(registry_get_field "${_name}" conflicts)"
    printf "ubuntu:      %s\n"  "$(registry_get_field "${_name}" ubuntu)"
    printf "platforms:   %s\n"  "$(registry_get_field "${_name}" platforms)"
}

# ── search ───────────────────────────────────────────────────────────────────

_dispatcher_search() {
    local _kw="${1:-}"
    if [[ -z "${_kw}" ]]; then
        printf "[dispatcher] ERROR: search needs <keyword>\n" >&2
        return 2
    fi
    if ! declare -F registry_list_names >/dev/null 2>&1; then
        printf "[dispatcher] ERROR: registry not loaded\n" >&2
        return 1
    fi
    local _names; _names="$(registry_list_names)"
    if [[ -z "${_names}" ]]; then
        printf '%s\n' "$(i18n_t DISPATCHER_I18N no_registered)"
        return 0
    fi

    local _kw_lc="${_kw,,}"
    local _found=0
    local _n _cat _tags _hay
    while IFS= read -r _n; do
        _cat="$(registry_get_field "${_n}" category)"
        _tags="$(registry_get_field "${_n}" tags)"
        _hay=" ${_n,,} ${_cat,,} ${_tags,,} "
        if [[ "${_hay}" == *"${_kw_lc}"* ]]; then
            if [[ "${_found}" -eq 0 ]]; then
                printf "%-30s  %-13s  %s\n" "NAME" "CATEGORY" "TAGS"
                _found=1
            fi
            printf "%-30s  %-13s  %s\n" "${_n}" "${_cat:-?}" "${_tags:-}"
        fi
    done <<< "${_names}"

    if [[ "${_found}" -eq 0 ]]; then
        printf '%s\n' "$(i18n_t DISPATCHER_I18N no_match "${_kw}")"
    fi
}

# ── detect ───────────────────────────────────────────────────────────────────

_dispatcher_detect() {
    local _json_only="false"
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            --json) _json_only="true" ;;
            -*)
                printf "[dispatcher] ERROR: unknown flag %s\n" "${_arg}" >&2
                return 2
                ;;
            *)
                printf "[dispatcher] ERROR: detect takes no positional args (got '%s')\n" "${_arg}" >&2
                return 2
                ;;
        esac
    done

    if ! declare -F environment_snapshot >/dev/null 2>&1; then
        printf "[dispatcher] ERROR: environment_snapshot not loaded\n" >&2
        return 1
    fi

    # Fetch the snapshot ONCE (probe + classify behind one call) and read
    # every field off it, instead of probing per field.
    local _snap
    _snap="$(environment_snapshot)"

    if [[ "${_json_only}" == "true" ]]; then
        # The snapshot already carries form_factor in the contract-stable
        # wire shape (probe JSON with `,"form_factor":"X"` before the '}').
        printf '%s\n' "${_snap}"
        return 0
    fi

    # Human-readable: "<dotted key>: <value>" per line.
    printf '%s\n' "----- init_ubuntu environment ------"
    printf 'os.id:           %s\n' "$(environment_field os.id "${_snap}")"
    printf 'os.version:      %s\n' "$(environment_field os.version "${_snap}")"
    printf 'os.codename:     %s\n' "$(environment_field os.codename "${_snap}")"
    printf 'arch:            %s\n' "$(environment_field arch "${_snap}")"
    printf 'cpu.vendor:      %s\n' "$(environment_field cpu.vendor "${_snap}")"
    printf 'gpu.vendor:      %s\n' "$(environment_field gpu.vendor "${_snap}")"
    printf 'gpu.model:       %s\n' "$(environment_field gpu.model "${_snap}")"
    printf 'desktop:         %s\n' "$(environment_field desktop "${_snap}")"
    printf 'session_type:    %s\n' "$(environment_field session_type "${_snap}")"
    printf 'virt.container:  %s\n' "$(environment_field virt.container "${_snap}")"
    printf 'virt.vm:         %s\n' "$(environment_field virt.vm "${_snap}")"
    printf 'wsl:             %s\n' "$(environment_field wsl "${_snap}")"
    printf 'board:           %s\n' "$(environment_field board "${_snap}")"
    printf 'form_factor:     %s\n' "$(environment_field form_factor "${_snap}")"
}
