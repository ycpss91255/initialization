#!/usr/bin/env bash
# lib/dispatcher.sh — subcommand parsing and routing
#
# Per PRD §7.2 subcommand table. Phase 2 batch B MVP scope:
#   install / remove / purge / list / show / help / version
# Other subcommands (update / upgrade / search / detect / doctor / sync /
# config / import / export) are stubbed to keep the CLI surface stable
# while later phases fill them in.
#
# Public API:
#   dispatcher_dispatch <args...>
#     Entry point; parses argv, fans out to handlers. Returns the chosen
#     handler's exit code (0/1/2/3/4/5/6/7 per PRD §7.4).

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

: "${INIT_UBUNTU_VERSION:=0.1.0-draft}"
: "${INIT_UBUNTU_DRY_RUN:=false}"
: "${INIT_UBUNTU_YES:=false}"
: "${INIT_UBUNTU_NO_DEPS:=false}"

# ── Help ─────────────────────────────────────────────────────────────────────

_dispatcher_usage() {
    cat <<'EOF'
Usage: setup_ubuntu <subcommand> [args] [flags]

Subcommands (Phase 2 MVP):
  install <module>...    Install modules (with their deps, topologically sorted)
  remove  <module>...    Remove modules (config retained)
  purge   <module>...    Remove modules + their config
  list                   List registered modules
  show    <module>       Print a module's metadata
  detect                 Print host environment (use --json for machine output)
  status                 Print modules recorded as installed (use --json)
  export  <file>         Export installed-state payload (use --modules=<csv>)
  import  <file>         Import payload and install the listed modules
  help    [<subcmd>]     Show this help
  version                Show tool version

Subcommands (stubbed, later phases):
  update / upgrade / search / doctor
  config load|set|get|unset|show
  sync / import / export

Common flags:
  -y / --yes             Assume yes to interactive prompts
  --dry-run              Print intended actions without executing
  --no-deps              Skip dep resolution (install only the named modules)
  --category=<c>         Filter list by category (base|recommended|optional|experimental)
  --tag=<t>              Filter list by tag

See PRD §7 for the full CLI specification.
EOF
}

_dispatcher_version() {
    printf "init_ubuntu %s\n" "${INIT_UBUNTU_VERSION}"
}

# ── list / show ──────────────────────────────────────────────────────────────

_dispatcher_list() {
    local -a _filter_args=()
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            --category=*|--tag=*) _filter_args+=("${_arg}") ;;
            --installed|--available|--json)
                printf "[dispatcher] WARN: %s is stubbed; ignoring\n" "${_arg}" >&2
                ;;
            *)
                printf "[dispatcher] ERROR: unknown flag %s\n" "${_arg}" >&2
                return 2
                ;;
        esac
    done

    if ! declare -F registry_list_names >/dev/null 2>&1; then
        printf "[dispatcher] ERROR: registry not loaded\n" >&2
        return 1
    fi

    local _names
    _names="$(registry_list_names "${_filter_args[@]}")"
    if [[ -z "${_names}" ]]; then
        printf "(no modules registered)\n"
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
    local _name="${1:-}"
    if [[ -z "${_name}" ]]; then
        printf "[dispatcher] ERROR: show requires <module>\n" >&2
        return 2
    fi
    if ! registry_has "${_name}"; then
        printf "[dispatcher] ERROR: unknown module %s\n" "${_name}" >&2
        return 2
    fi
    printf "name:       %s\n"  "${_name}"
    printf "file:       %s\n"  "$(registry_get_field "${_name}" file)"
    printf "category:   %s\n"  "$(registry_get_field "${_name}" category)"
    printf "tags:       %s\n"  "$(registry_get_field "${_name}" tags)"
    printf "deps:       %s\n"  "$(registry_get_field "${_name}" deps)"
    printf "conflicts:  %s\n"  "$(registry_get_field "${_name}" conflicts)"
    printf "ubuntu:     %s\n"  "$(registry_get_field "${_name}" ubuntu)"
    printf "platforms:  %s\n"  "$(registry_get_field "${_name}" platforms)"
}

# ── install / remove / purge ─────────────────────────────────────────────────

_dispatcher_lifecycle() {
    local _phase="${1:?_dispatcher_lifecycle needs <phase>}"  # install|remove|purge
    shift

    local -a _modules=()
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            -y|--yes)     export INIT_UBUNTU_YES=true ;;
            --dry-run)    export INIT_UBUNTU_DRY_RUN=true ;;
            --no-deps)    export INIT_UBUNTU_NO_DEPS=true ;;
            --with-orphans|--base|--recommended|--all-base|--category=*|--install-target=*|--force)
                printf "[dispatcher] WARN: %s is stubbed; ignoring\n" "${_arg}" >&2
                ;;
            -*)
                printf "[dispatcher] ERROR: unknown flag %s\n" "${_arg}" >&2
                return 2
                ;;
            *)
                _modules+=("${_arg}")
                ;;
        esac
    done

    if [[ "${#_modules[@]}" -eq 0 ]]; then
        printf "[dispatcher] ERROR: %s requires at least one <module>\n" "${_phase}" >&2
        return 2
    fi

    local -a _order=()
    if [[ "${INIT_UBUNTU_NO_DEPS}" == "true" ]]; then
        _order=("${_modules[@]}")
    else
        local _resolved
        _resolved="$(resolver_resolve "${_modules[@]}")"
        local _rc=$?
        if [[ "${_rc}" -ne 0 ]]; then
            return "${_rc}"
        fi
        local _line
        while IFS= read -r _line; do
            [[ -n "${_line}" ]] && _order+=("${_line}")
        done <<< "${_resolved}"
    fi

    # Refuse root only when we'll actually mutate the system (PRD §10).
    # Resolved AFTER resolver so unknown-module / cycle errors still surface
    # their own exit codes (2 / 5) rather than getting masked by exit 4.
    # Dry-run + read-only paths stay root-safe so CI and bats can drive them.
    if [[ "${INIT_UBUNTU_DRY_RUN}" != "true" && "${EUID:-0}" -eq 0 ]]; then
        printf "[dispatcher] ERROR: do not run %s as root. Re-run as a regular user; sudo will be requested per-module.\n" "${_phase}" >&2
        return 4
    fi

    if [[ "${INIT_UBUNTU_DRY_RUN}" == "true" ]]; then
        printf "[dispatcher] DRY-RUN: would %s in this order:\n" "${_phase}"
        local _n
        for _n in "${_order[@]}"; do
            printf "  - %s\n" "${_n}"
        done
        return 0
    fi

    # Mark user-requested top-level modules so runner can flag them as
    # manual=true in state.json. Space-padded for substring match.
    export INIT_UBUNTU_REQUESTED_MODULES=" ${_modules[*]} "

    case "${_phase}" in
        install) runner_install "${_order[@]}" ;;
        remove)  runner_remove  "${_order[@]}" ;;
        purge)   runner_purge   "${_order[@]}" ;;
    esac
}

# ── status / import / export ─────────────────────────────────────────────────

_dispatcher_status() {
    local _json="false"
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            --json) _json="true" ;;
            -*)
                printf "[dispatcher] ERROR: unknown flag %s\n" "${_arg}" >&2
                return 2
                ;;
            *)
                printf "[dispatcher] ERROR: status takes no positional args (got '%s')\n" "${_arg}" >&2
                return 2
                ;;
        esac
    done

    if ! declare -F state_list_installed >/dev/null 2>&1; then
        printf "[dispatcher] ERROR: state lib not loaded\n" >&2
        return 1
    fi

    local _state_path; _state_path="$(state_get_path)"
    if [[ "${_json}" == "true" ]]; then
        if [[ -f "${_state_path}" ]]; then
            cat "${_state_path}"
        else
            printf '{"version":"0.1.0","installed":{}}\n'
        fi
        return 0
    fi

    local _names; _names="$(state_list_installed)"
    if [[ -z "${_names}" ]]; then
        printf "(no modules recorded as installed)\n"
        return 0
    fi
    printf "%-30s  %-7s  %-12s  %s\n" "MODULE" "MANUAL" "VERSION" "INSTALLED AT"
    local _n _manual _ver _at
    while IFS= read -r _n; do
        _manual="$(state_get_field "${_n}" manual)"
        _ver="$(state_get_field "${_n}" version_provided)"
        _at="$(state_get_field "${_n}" installed_at)"
        printf "%-30s  %-7s  %-12s  %s\n" "${_n}" "${_manual}" "${_ver}" "${_at}"
    done <<< "${_names}"
}

_dispatcher_export() {
    local _out=""
    local -a _passthrough=()
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            --modules=*) _passthrough+=("${_arg}") ;;
            -*) printf "[dispatcher] ERROR: unknown flag %s\n" "${_arg}" >&2; return 2 ;;
            *)
                if [[ -z "${_out}" ]]; then
                    _out="${_arg}"
                else
                    printf "[dispatcher] ERROR: export takes one <out-file>\n" >&2
                    return 2
                fi
                ;;
        esac
    done
    if [[ -z "${_out}" ]]; then
        printf "[dispatcher] ERROR: export needs <out-file>\n" >&2
        return 2
    fi

    state_io_export "${_out}" "${_passthrough[@]}"
    local _rc=$?
    if [[ "${_rc}" -eq 0 ]]; then
        printf "[dispatcher] state exported to %s\n" "${_out}"
    fi
    return "${_rc}"
}

_dispatcher_import() {
    local _in=""
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            -y|--yes) export INIT_UBUNTU_YES=true ;;
            --dry-run) export INIT_UBUNTU_DRY_RUN=true ;;
            -*) printf "[dispatcher] ERROR: unknown flag %s\n" "${_arg}" >&2; return 2 ;;
            *)
                if [[ -z "${_in}" ]]; then
                    _in="${_arg}"
                else
                    printf "[dispatcher] ERROR: import takes one <in-file>\n" >&2
                    return 2
                fi
                ;;
        esac
    done
    if [[ -z "${_in}" ]]; then
        printf "[dispatcher] ERROR: import needs <in-file>\n" >&2
        return 2
    fi

    local _modules
    _modules="$(state_io_payload_modules "${_in}")"
    local _rc=$?
    if [[ "${_rc}" -ne 0 ]]; then
        return "${_rc}"
    fi
    if [[ -z "${_modules}" ]]; then
        printf "[dispatcher] payload has no modules; nothing to do.\n"
        return 0
    fi

    # Hand the names to the install lifecycle path so deps are resolved
    # and the user's per-flag choices (dry-run, yes) are honored.
    local -a _names=()
    local _line
    while IFS= read -r _line; do
        [[ -n "${_line}" ]] && _names+=("${_line}")
    done <<< "${_modules}"

    _dispatcher_lifecycle install "${_names[@]}"
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

    if ! declare -F detect_environment >/dev/null 2>&1; then
        printf "[dispatcher] ERROR: detect_environment not loaded\n" >&2
        return 1
    fi

    local _env_json _form
    _env_json="$(detect_environment)"
    _form="$(platform_classify "${_env_json}")"

    if [[ "${_json_only}" == "true" ]]; then
        # Splice form_factor into the JSON by replacing the closing '}'.
        # This keeps lib/detect.sh free of any platform.sh coupling.
        printf '%s,"form_factor":"%s"}\n' "${_env_json%\}}" "${_form}"
        return 0
    fi

    # Human-readable: "<dotted key>: <value>" per line.
    printf '%s\n' "----- init_ubuntu environment ------"
    printf 'os.id:           %s\n' "$(detect_get_field os.id)"
    printf 'os.version:      %s\n' "$(detect_get_field os.version)"
    printf 'os.codename:     %s\n' "$(detect_get_field os.codename)"
    printf 'arch:            %s\n' "$(detect_get_field arch)"
    printf 'cpu.vendor:      %s\n' "$(detect_get_field cpu.vendor)"
    printf 'gpu.vendor:      %s\n' "$(detect_get_field gpu.vendor)"
    printf 'gpu.model:       %s\n' "$(detect_get_field gpu.model)"
    printf 'desktop:         %s\n' "$(detect_get_field desktop)"
    printf 'session_type:    %s\n' "$(detect_get_field session_type)"
    printf 'virt.container:  %s\n' "$(detect_get_field virt.container)"
    printf 'virt.vm:         %s\n' "$(detect_get_field virt.vm)"
    printf 'wsl:             %s\n' "$(detect_get_field wsl)"
    printf 'board:           %s\n' "$(detect_get_field board)"
    printf 'form_factor:     %s\n' "${_form}"
}

# ── Stub group ───────────────────────────────────────────────────────────────

_dispatcher_stub() {
    local _name="$1"
    printf "[dispatcher] '%s' is not implemented yet (planned for a later phase)\n" "${_name}" >&2
    return 1
}

# ── Main dispatch ────────────────────────────────────────────────────────────

dispatcher_dispatch() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || -z "${1:-}" ]]; then
        _dispatcher_usage
        return 0
    fi
    if [[ "${1}" == "--version" ]]; then
        _dispatcher_version
        return 0
    fi

    local _sub="$1"
    shift

    case "${_sub}" in
        help)    _dispatcher_usage ;;
        version) _dispatcher_version ;;
        list)    _dispatcher_list "$@" ;;
        show)    _dispatcher_show "$@" ;;
        detect)  _dispatcher_detect "$@" ;;
        status)  _dispatcher_status "$@" ;;
        export)  _dispatcher_export "$@" ;;
        import)  _dispatcher_import "$@" ;;
        install|remove|purge)
            _dispatcher_lifecycle "${_sub}" "$@"
            ;;
        update|upgrade|search|doctor|sync|config|self-upgrade)
            _dispatcher_stub "${_sub}"
            ;;
        *)
            printf "[dispatcher] ERROR: unknown subcommand '%s'\n" "${_sub}" >&2
            printf "Run 'setup_ubuntu --help' to see the supported subcommands.\n" >&2
            return 2
            ;;
    esac
}
