#!/usr/bin/env bash
# lib/dispatcher.sh — subcommand parsing and routing
#
# Per PRD §7.2 subcommand table (PRD 1.2.1):
#   - `update` is removed (Q40): the registry is in-memory and rebuilt by a
#     dynamic scan on every run, so there is nothing to refresh. It returns
#     exit 2 (unknown subcommand) with a hint at `self-upgrade` (0.3.0) and
#     the gh-latest cache (§7.6).
#   - `config load` is removed (Q6/Q38): config-drop modules go through the
#     normal install pipeline. `config get/set/unset/show` remain.
#   - `status` is deprecated: prints a warning on stderr and forwards to
#     `list --installed`.
#
# Public API:
#   dispatcher_dispatch <args...>
#     Entry point; parses argv, fans out to handlers. Returns the chosen
#     handler's exit code (0/1/2/3/4/5/6/7 per PRD §7.4).

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

: "${INIT_UBUNTU_VERSION:=0.1.0-draft}"
: "${INIT_UBUNTU_DRY_RUN:=false}"
: "${INIT_UBUNTU_YES:=false}"
: "${INIT_UBUNTU_NO_DEPS:=false}"

# i18n_t (issue #185) lives in lib/i18n.sh. The entrypoint sources it before
# dispatching, but make this lib self-sufficient (unit specs source dispatcher.sh
# directly) by loading it on demand when the helper is not yet defined.
if ! declare -F i18n_t >/dev/null 2>&1; then
    # shellcheck source=lib/i18n.sh
    source "${BASH_SOURCE[0]%/*}/i18n.sh"
fi

# ── i18n message table (issue #185, Phase 2) ─────────────────────────────────
# File-local catalog for the HUMAN-readable strings the dispatcher prints to
# stdout/stderr. Resolved by i18n_t (lib/i18n.sh): ${INIT_UBUNTU_LANG}.<key> ->
# en.<key> -> literal <key>. The en.<key> values are byte-identical to the
# original English so existing English-asserting specs keep passing. Only true
# user-facing prose is here — [dispatcher] diagnostics, log_* calls, JSON /
# machine output, and key:value table rows stay English by design.
# kcov-exclude-start (i18n data table; excluded from coverage — kcov counts each entry line as uncoverable, issue #185)
declare -gA DISPATCHER_I18N=(
  ["en.usage"]="Usage: setup_ubuntu <subcommand> [args] [flags]

Subcommands:
  install <module>...    Install modules (with their deps, topologically sorted)
  remove  <module>...    Remove modules (config retained)
  purge   <module>...    Remove modules + their config
  list                   List registered modules (--installed for state.json view)
  show    <module>       Print a module's metadata
  detect                 Print host environment (use --json for machine output)
  export  <file>         Export state.json synced sections (use --modules=<csv>)
  import  <file>         Diff payload vs local state (dry-run default; --apply commits)
  upgrade [<module>...]  Run upgrade() for given modules (or all installed)
  verify  [<module>...]  Run verify() for given modules (or all installed)
  search  <keyword>      Search modules by name / category / tag
  doctor  [<module>...]  Diff state.json vs system reality + run doctor()
                         for given modules (or all installed)
  config  set|get|unset|show <section.key> [<value>]
                         Read / write ~/.config/init_ubuntu/config.ini
  sync    <user@host>    Push state via SSH (or --pull for the reverse)
  help    [<subcmd>]     Show this help
  version                Show tool version

Deprecated:
  status                 Use 'list --installed' (forwards with a warning)

Subcommands (stubbed, later phases):
  self-upgrade           Update the tool itself (planned for 0.3.0)

Global flags (any position):
  --color=auto|always|never
                         ANSI color control (default auto: off when piped,
                         NO_COLOR set, TERM=dumb, or running in background)
  -v / --verbose         Set log level to DEBUG
  --quiet                Set log level to WARN (info suppressed)

Common flags:
  -y / --yes             Assume yes to interactive prompts
  --dry-run              Print intended actions without executing
  --no-deps              Skip dep resolution (install only the named modules)
  --verbose              Stream child command output live (default: captured to JSONL)
  --quiet                Suppress progress lines; keep warn / error only
  --category=<c>         Filter list by category (base|recommended|optional|experimental)
  --tag=<t>              Filter list by tag
  --installed            With list: show modules recorded in state.json (--json for raw)

See PRD §7 for the full CLI specification."
  ["zh-TW.usage"]="用法:setup_ubuntu <subcommand> [args] [flags]

子命令:
  install <module>...    安裝模組(連同其依賴,依拓樸排序)
  remove  <module>...    移除模組(保留設定)
  purge   <module>...    移除模組及其設定
  list                   列出已註冊的模組(--installed 顯示 state.json 視圖)
  show    <module>       印出某個模組的中繼資料
  detect                 印出主機環境(使用 --json 取得機器可讀輸出)
  export  <file>         匯出 state.json 的同步區段(使用 --modules=<csv>)
  import  <file>         比對 payload 與本地狀態(預設為試運行;--apply 才提交)
  upgrade [<module>...]  對指定模組執行 upgrade()(未指定則為所有已安裝模組)
  verify  [<module>...]  對指定模組執行 verify()(未指定則為所有已安裝模組)
  search  <keyword>      依名稱 / 分類 / 標籤搜尋模組
  doctor  [<module>...]  比對 state.json 與系統實際狀態,並執行指定模組的
                         doctor()(未指定則為所有已安裝模組)
  config  set|get|unset|show <section.key> [<value>]
                         讀取 / 寫入 ~/.config/init_ubuntu/config.ini
  sync    <user@host>    透過 SSH 推送狀態(或以 --pull 反向拉取)
  help    [<subcmd>]     顯示此說明
  version                顯示工具版本

已棄用:
  status                 請改用 'list --installed'(會轉發並顯示警告)

子命令(佔位,後續階段):
  self-upgrade           更新工具本身(規劃於 0.3.0)

全域旗標(任意位置):
  --color=auto|always|never
                         ANSI 色彩控制(預設 auto:管線輸出、設定 NO_COLOR、
                         TERM=dumb 或於背景執行時關閉)
  -v / --verbose         將日誌等級設為 DEBUG
  --quiet                將日誌等級設為 WARN(抑制 info)

常用旗標:
  -y / --yes             對互動式提示一律假設為「是」
  --dry-run              印出預定動作但不實際執行
  --no-deps              跳過依賴解析(只安裝指定的模組)
  --verbose              即時串流子命令輸出(預設:擷取至 JSONL)
  --quiet                抑制進度列;僅保留 warn / error
  --category=<c>         依分類過濾 list(base|recommended|optional|experimental)
  --tag=<t>              依標籤過濾 list
  --installed            搭配 list:顯示記錄於 state.json 的模組(--json 取得原始資料)

完整 CLI 規格請參見 PRD §7。"
  ["en.no_installed"]="(no modules recorded as installed)"
  ["zh-TW.no_installed"]="(沒有任何模組被記錄為已安裝)"
  ["en.no_registered"]="(no modules registered)"
  ["zh-TW.no_registered"]="(沒有任何已註冊的模組)"
  ["en.no_match"]="no module matches '{0}'"
  ["zh-TW.no_match"]="沒有符合「{0}」的模組"
  ["en.will_install"]="Will install: {0}"
  ["zh-TW.will_install"]="即將安裝:{0}"
  ["en.proceed_yn"]="Proceed? [Y/n] "
  ["zh-TW.proceed_yn"]="是否繼續?[Y/n] "
  ["en.proceed_ny"]="Proceed? [y/N] "
  ["zh-TW.proceed_ny"]="是否繼續?[y/N] "
  ["en.aborted"]="Aborted."
  ["zh-TW.aborted"]="已中止。"
  ["en.will_upgrade"]="Will upgrade {0} module(s): {1}"
  ["zh-TW.will_upgrade"]="即將升級 {0} 個模組:{1}"
)
# kcov-exclude-end
# DISPATCHER_I18N is consumed by i18n_t via a nameref on the table NAME passed as
# a bareword argument — static analysis cannot follow that indirection, so make
# the read explicit here to keep shellcheck honest (no disable directive).
: "${DISPATCHER_I18N[@]+x}"

# ── Help ─────────────────────────────────────────────────────────────────────

_dispatcher_usage() {
    printf '%s\n' "$(i18n_t DISPATCHER_I18N usage)"
}

_dispatcher_version() {
    printf "init_ubuntu %s\n" "${INIT_UBUNTU_VERSION}"
}

# ── list / show ──────────────────────────────────────────────────────────────

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
        _ver="$(state_get_field "${_n}" version_provided)"
        _at="$(state_get_field "${_n}" installed_at)"
        printf "%-30s  %-7s  %-12s  %s\n" "${_n}" "${_manual}" "${_ver}" "${_at}"
    done <<< "${_names}"
}

# Catalog (registry) JSON view (issue #165, ADR-0019 / G4). Emits ONLY a
# JSON document to stdout that the TUI (lib/tui_backend.sh) can parse:
#
#   { "items": [ { "name", "category", "tags":[...],
#                  "supported_platforms":[...], "description", "recommended" }, ... ] }
#
# Honors the same --category= / --tag= filters as the plain list view.
# All strings are escaped by jq (never hand-rolled). description / recommended
# are sourced per-module in an isolated subshell and degrade to JSON null when
# the module omits them or errs (additive fields are optional, ADR-0019).
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

        # description + recommended come from the module itself, sourced in an
        # isolated fork-style subshell (keeps declares / traps scoped, keeps
        # set -u + coverage instrumentation happy — same rationale as runner).
        # Output protocol on stdout: "<recommended-token>\n<description...>".
        # recommended token: true | false | null. A missing description prints
        # nothing after the newline → treated as null below.
        _desc=""
        _rec="null"
        if [[ -n "${_file}" && -f "${_file}" ]]; then
            local _probe _probe_rc=0
            _probe="$(
                # shellcheck source=/dev/null  # module path is dynamic; static resolution impossible — https://www.shellcheck.net/wiki/SC1090
                source "${LIB_DIR}/logger.sh" >/dev/null 2>&1
                # shellcheck source=/dev/null  # dynamic lib path
                source "${LIB_DIR}/general.sh" >/dev/null 2>&1
                # shellcheck source=/dev/null  # dynamic lib path
                source "${LIB_DIR}/module_helper.sh" >/dev/null 2>&1
                # shellcheck source=/dev/null  # module path is dynamic
                source "${_file}" >/dev/null 2>&1 || exit 0
                _r="null"
                if declare -F is_recommended >/dev/null 2>&1; then
                    if is_recommended >/dev/null 2>&1; then _r="true"; else _r="false"; fi
                fi
                printf '%s\n' "${_r}"
                if declare -F module_get_description >/dev/null 2>&1; then
                    module_get_description "${_lang}" 2>/dev/null
                fi
            )" || _probe_rc=$?
            if [[ "${_probe_rc}" -eq 0 ]]; then
                _rec="${_probe%%$'\n'*}"
                case "${_rec}" in true|false|null) ;; *) _rec="null" ;; esac
                if [[ "${_probe}" == *$'\n'* ]]; then
                    _desc="${_probe#*$'\n'}"
                else
                    _desc=""
                fi
            fi
        fi

        # tags / supported_platforms → JSON arrays (jq escapes each element).
        local _tags_json _plats_json
        _tags_json="$(jq -cn '$ARGS.positional' --args "${_tags_arr[@]+"${_tags_arr[@]}"}")"
        _plats_json="$(jq -cn '$ARGS.positional' --args "${_plats_arr[@]+"${_plats_arr[@]}"}")"

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

# Localized module DESCRIPTION for `show` (issue #183). Sources the module in
# an isolated fork-style subshell — same mechanism `list --json` uses for the
# description field (keeps declares / traps scoped, set -u + coverage happy) and
# stays fully offline (no network). Honors INIT_UBUNTU_LANG via the i18n catalog
# (module_get_description → module_i18n_get). Prints nothing when the module
# file is missing or exposes no DESCRIPTION.
_dispatcher_module_description() {
    local _file="$1" _lang="${INIT_UBUNTU_LANG:-en}"
    [[ -n "${_file}" && -f "${_file}" ]] || return 0
    (
        # shellcheck source=/dev/null  # module path is dynamic; static resolution impossible — https://www.shellcheck.net/wiki/SC1090
        source "${LIB_DIR}/logger.sh" >/dev/null 2>&1
        # shellcheck source=/dev/null  # dynamic lib path
        source "${LIB_DIR}/general.sh" >/dev/null 2>&1
        # shellcheck source=/dev/null  # dynamic lib path
        source "${LIB_DIR}/module_helper.sh" >/dev/null 2>&1
        # shellcheck source=/dev/null  # module path is dynamic
        source "${_file}" >/dev/null 2>&1 || exit 0
        if declare -F module_get_description >/dev/null 2>&1; then
            module_get_description "${_lang}" 2>/dev/null
        fi
    )
}

# Machine-readable detail for a single module (issue #211, part 1 — the TUI
# module-detail / Manage-detail views consume this). stdout is ONLY a single
# JSON object; warnings/errors stay on stderr (same guarantee as list --json).
# All strings/arrays are escaped by jq (never hand-rolled), matching
# _dispatcher_list_catalog_json. description is sourced in the same isolated
# fork-style subshell as list --json and degrades to JSON null when the module
# omits it (additive fields are optional, ADR-0019). JSON keys use the canonical
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
    _tags_json="$(jq -cn   '$ARGS.positional' --args "${_tags_arr[@]+"${_tags_arr[@]}"}")"
    _deps_json="$(jq -cn   '$ARGS.positional' --args "${_deps_arr[@]+"${_deps_arr[@]}"}")"
    _conf_json="$(jq -cn   '$ARGS.positional' --args "${_conf_arr[@]+"${_conf_arr[@]}"}")"
    _ubuntu_json="$(jq -cn '$ARGS.positional' --args "${_ubuntu_arr[@]+"${_ubuntu_arr[@]}"}")"
    _plats_json="$(jq -cn  '$ARGS.positional' --args "${_plats_arr[@]+"${_plats_arr[@]}"}")"

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
            --verbose)    export INIT_UBUNTU_VERBOSE=true ;;
            --quiet)
                # PRD §7.7.1: no progress lines; only warn/error remain.
                export INIT_UBUNTU_QUIET=true
                export LOG_LEVEL=WARN
                ;;
            --with-orphans|--base|--recommended|--all-base|--category=*|--install-target=*|--force|--profile=*)
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
        # PRD §7.4: the resolver returns 2 (unknown module) / 5 (dep cycle or
        # CONFLICTS_WITH) on failure. setup_ubuntu.sh runs under
        # `set -euo pipefail; shopt -s inherit_errexit`, so a bare command
        # substitution would abort the whole script with status 1 before we
        # could read $? — masking the real 2/5 to a generic 1. The `|| _rc=$?`
        # tail both suspends errexit for the substitution AND preserves the
        # resolver's real status (unlike `if ! ...`, where the negation resets
        # $? to 0 inside the branch), so we can propagate 2/5 verbatim.
        local _resolved _rc=0
        _resolved="$(resolver_resolve "${_modules[@]}")" || _rc=$?
        if [[ "${_rc}" -ne 0 ]]; then
            return "${_rc}"
        fi
        local _line
        while IFS= read -r _line; do
            [[ -n "${_line}" ]] && _order+=("${_line}")
        done <<< "${_resolved}"
    fi

    # Plan + confirm (PRD §7.2, 2026-06-06): without -y, print the resolved
    # plan after dep resolution and ask `Proceed? [Y/n]` (install defaults
    # to yes). Non-tty stdin has nobody to answer, so the default applies.
    # --dry-run executes nothing, so it never prompts.
    if [[ "${_phase}" == "install" \
          && "${INIT_UBUNTU_DRY_RUN}" != "true" \
          && "${INIT_UBUNTU_YES}" != "true" ]]; then
        local -a _plan_deps=()
        local _n
        for _n in "${_order[@]}"; do
            [[ " ${_modules[*]} " == *" ${_n} "* ]] && continue
            _plan_deps+=("${_n}")
        done
        local _plan; _plan="$(i18n_t DISPATCHER_I18N will_install "${_modules[*]}")"
        if [[ "${#_plan_deps[@]}" -gt 0 ]]; then
            local _dep_word="deps"
            [[ "${#_plan_deps[@]}" -eq 1 ]] && _dep_word="dep"
            local _dep_csv
            printf -v _dep_csv '%s, ' "${_plan_deps[@]}"
            _plan+=" + ${#_plan_deps[@]} ${_dep_word} (${_dep_csv%, })"
        fi
        printf '%s\n' "${_plan}"
        printf '%s' "$(i18n_t DISPATCHER_I18N proceed_yn)"
        local _ans=""
        if [[ -t 0 ]]; then
            read -r _ans || _ans=""
        else
            printf '\n'
        fi
        case "${_ans}" in
            [nN]*)
                printf '%s\n' "$(i18n_t DISPATCHER_I18N aborted)"
                return 1
                ;;
        esac
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

# ── status (deprecated) / import / export ────────────────────────────────────

# status — deprecated alias (PRD §7.2): warn on stderr, forward to
# `list --installed`. Flag validation is delegated to _dispatcher_list.
_dispatcher_status() {
    printf "[dispatcher] WARN: 'status' is deprecated; use 'list --installed' instead (forwarding)\n" >&2
    _dispatcher_list --installed "$@"
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

# import — ADR-0013 conflict pipeline, same rules as `sync --pull`:
# dry-run by default (print the plan, write nothing), `--apply` commits.
# Union of modules, remote-wins on version/depends_on, `manual` sticky to
# true. The payload's `local` sections are never applied (ADR-0018); the
# receiver rebuilds `local` via its own install pipeline.
_dispatcher_import() {
    local _in=""
    local _apply="false"
    local _dry="false"
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            -y|--yes) export INIT_UBUNTU_YES=true ;;
            --apply) _apply="true" ;;
            --dry-run) _dry="true" ;;
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
    # Dry-run is the default; an explicit --dry-run (flag or global env)
    # always wins over --apply.
    [[ "${_dry}" == "true" || "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]] && _apply="false"

    if ! declare -F state_io_import_plan >/dev/null 2>&1; then
        printf "[dispatcher] ERROR: state_io lib not loaded\n" >&2
        return 1
    fi

    local _plan _rc
    _plan="$(state_io_import_plan "${_in}")"
    _rc=$?
    if [[ "${_rc}" -ne 0 ]]; then
        return "${_rc}"
    fi

    local _source
    _source="$(jq -r 'if .source_host then ((.source_user // "?") + "@" + .source_host) else "local file" end' \
        "${_in}" 2>/dev/null || printf 'local file')"

    printf "IMPORT DIFF (source: %s)\n" "${_source}"
    jq -r '.[]
        | if .action == "install" then
            "  + \(.name)\tinstall\t\(.remote_version)\tmanual=\(.synced.manual // false)"
          elif .action == "upgrade" then
            "  ~ \(.name)\tupgrade\t\(.local_version) -> \(.remote_version)"
          elif .action == "flag-manual" then
            "  * \(.name)\tmanual\tflag manual=true (sticky)"
          elif .action == "keep" then
            "  = \(.name)\tkeep\t\(.local_version)\t(local only)"
          elif .action == "noop" then
            "  = \(.name)\tup-to-date\t\(.local_version)"
          else
            "  ! \(.name)\tskip\t\(.reason)"
          end' <<< "${_plan}"

    if [[ "${_apply}" != "true" ]]; then
        printf "\n[dispatcher] dry-run (default): nothing was changed. Re-run with --apply to commit.\n"
        return 0
    fi

    # Modules that need a real lifecycle run on this machine.
    local -a _installs=() _upgrades=()
    local _n
    while IFS= read -r _n; do
        [[ -n "${_n}" ]] && _installs+=("${_n}")
    done < <(jq -r '.[] | select(.action == "install") | .name' <<< "${_plan}")
    while IFS= read -r _n; do
        [[ -n "${_n}" ]] && _upgrades+=("${_n}")
    done < <(jq -r '.[] | select(.action == "upgrade") | .name' <<< "${_plan}")

    # Refuse root only when we'll actually mutate the system (PRD §10);
    # a flag-manual-only apply is a pure state.json write and stays
    # root-safe for CI / bats.
    if [[ "$(( ${#_installs[@]} + ${#_upgrades[@]} ))" -gt 0 && "${EUID:-0}" -eq 0 ]]; then
        printf "[dispatcher] ERROR: do not run import --apply as root. Re-run as a regular user; sudo will be requested per-module.\n" >&2
        return 4
    fi

    # ADR-0013 --apply: each affected module runs through the normal
    # install / upgrade lifecycle, then the merged synced sections land in
    # state.json (remote-wins). Partial failure → exit 6 (PRD §7.4).
    local _lifecycle_rc=0
    if [[ "${#_installs[@]}" -gt 0 ]]; then
        _dispatcher_lifecycle install "${_installs[@]}" || _lifecycle_rc=$?
    fi
    if [[ "${#_upgrades[@]}" -gt 0 ]] && declare -F runner_upgrade >/dev/null 2>&1; then
        runner_upgrade "${_upgrades[@]}" || _lifecycle_rc=$?
    fi

    # Never let state.json claim an install that did not land: any
    # install-entry module still missing from state is excluded from the
    # state merge.
    local _skip_csv=""
    for _n in "${_installs[@]}"; do
        if ! state_is_recorded "${_n}"; then
            _skip_csv="${_skip_csv:+${_skip_csv},}${_n}"
        fi
    done

    # Hand the pre-lifecycle plan to the apply phase: the install runs
    # above already changed local state, so recomputing the plan here
    # would shift the actions (install→upgrade/noop) and lose remote-wins.
    local _plan_file
    _plan_file="$(mktemp /tmp/init_ubuntu_import_plan.XXXXXX.json)"
    printf '%s\n' "${_plan}" > "${_plan_file}"

    local -a _apply_args=("${_in}" "--plan=${_plan_file}")
    [[ -n "${_skip_csv}" ]] && _apply_args+=("--skip=${_skip_csv}")
    state_io_import_apply "${_apply_args[@]}"
    local _apply_rc=$?
    rm -f "${_plan_file}"
    [[ "${_apply_rc}" -ne 0 ]] && return 1

    if [[ "${_lifecycle_rc}" -ne 0 ]]; then
        printf "[dispatcher] import applied with partial failures\n" >&2
        return 6
    fi
    printf "[dispatcher] import applied.\n"
    return 0
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

# ── upgrade / search / doctor / config / sync ───────────────────────────────

# `update` was removed (PRD §7.2, Q40): the registry is in-memory and
# rebuilt by a dynamic scan on every run — there is no index to go stale.
# It is treated as an unknown subcommand (exit 2) with a targeted hint.
_dispatcher_update_removed() {
    printf "[dispatcher] ERROR: unknown subcommand 'update' (removed; the registry is rebuilt in-memory on every run)\n" >&2
    printf "[dispatcher] hint: release freshness comes from the gh-latest cache (TTL 1h, see PRD §7.6);\n" >&2
    printf "[dispatcher] hint: to update the tool itself, use 'self-upgrade' (planned for 0.3.0).\n" >&2
    return 2
}

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

_dispatcher_upgrade() {
    # upgrade = re-run install() for the named modules (or every installed
    # module if no names given). Real install path; refuses root same as
    # _dispatcher_lifecycle (BUT only when we'd actually call runner).
    local -a _modules=()
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            -y|--yes) export INIT_UBUNTU_YES=true ;;
            --dry-run) export INIT_UBUNTU_DRY_RUN=true ;;
            --verbose) export INIT_UBUNTU_VERBOSE=true ;;
            --quiet)
                export INIT_UBUNTU_QUIET=true
                export LOG_LEVEL=WARN
                ;;
            -*) printf "[dispatcher] ERROR: unknown flag %s\n" "${_arg}" >&2; return 2 ;;
            *) _modules+=("${_arg}") ;;
        esac
    done

    if [[ "${#_modules[@]}" -eq 0 ]]; then
        local _line
        while IFS= read -r _line; do
            [[ -n "${_line}" ]] && _modules+=("${_line}")
        done < <(state_list_installed)
    fi

    if [[ "${#_modules[@]}" -eq 0 ]]; then
        printf "[dispatcher] nothing recorded as installed; nothing to upgrade\n"
        return 0
    fi

    log_info "[dispatcher] upgrading ${#_modules[@]} module(s): ${_modules[*]}"

    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        printf "[dispatcher] DRY-RUN: would upgrade in this order:\n"
        local _n
        for _n in "${_modules[@]}"; do
            printf "  - %s\n" "${_n}"
        done
        return 0
    fi

    # Plan + confirm (PRD §7.6): upgrade keeps the conservative [y/N]
    # default (unlike install's [Y/n]). Non-tty stdin has nobody to
    # answer, so the default (no) applies and the run aborts.
    if [[ "${INIT_UBUNTU_YES}" != "true" ]]; then
        printf '%s\n' "$(i18n_t DISPATCHER_I18N will_upgrade "${#_modules[@]}" "${_modules[*]}")"
        printf '%s' "$(i18n_t DISPATCHER_I18N proceed_ny)"
        local _ans=""
        if [[ -t 0 ]]; then
            read -r _ans || _ans=""
        else
            printf '\n'
        fi
        case "${_ans}" in
            [yY]*) ;;
            *)
                printf '%s\n' "$(i18n_t DISPATCHER_I18N aborted)"
                return 1
                ;;
        esac
    fi

    # Real run: refuse root (PRD §10). Check is HERE so dry-run + empty
    # paths above stay root-safe for CI / bats.
    if [[ "${EUID:-0}" -eq 0 ]]; then
        printf "[dispatcher] ERROR: do not run upgrade as root.\n" >&2
        return 4
    fi

    runner_upgrade "${_modules[@]}"
}

_dispatcher_verify() {
    # verify = run verify() for the named modules (or every installed module
    # if no names given). Read-mostly; modules typically just confirm
    # is_installed + run TEST_VERIFY_CMD. Does not refuse root because
    # verify is safe to invoke as root (no apt mutation).
    local -a _modules=()
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            --dry-run) export INIT_UBUNTU_DRY_RUN=true ;;
            -*) printf "[dispatcher] ERROR: unknown flag %s\n" "${_arg}" >&2; return 2 ;;
            *) _modules+=("${_arg}") ;;
        esac
    done

    if [[ "${#_modules[@]}" -eq 0 ]]; then
        local _line
        while IFS= read -r _line; do
            [[ -n "${_line}" ]] && _modules+=("${_line}")
        done < <(state_list_installed)
    fi

    if [[ "${#_modules[@]}" -eq 0 ]]; then
        printf "[dispatcher] nothing recorded as installed; nothing to verify\n"
        return 0
    fi

    log_info "[dispatcher] verifying ${#_modules[@]} module(s): ${_modules[*]}"

    if [[ "${INIT_UBUNTU_DRY_RUN:-false}" == "true" ]]; then
        printf "[dispatcher] DRY-RUN: would verify in this order:\n"
        local _n
        for _n in "${_modules[@]}"; do
            printf "  - %s\n" "${_n}"
        done
        return 0
    fi

    runner_verify "${_modules[@]}"
}

# doctor --validate-modules (PRD §9.1 / §7.4 / AC-24): lint every registered
# module's metadata. Each module must declare a name + category, every
# DEPENDS_ON entry must resolve through the registry, and every CONFLICTS_WITH
# entry must name a real module. Any invalid metadata / unresolvable dep is an
# argument-class error → exit 2 (NOT the drift-report 0/1 of plain doctor).
_dispatcher_doctor_validate_modules() {
    if ! declare -F registry_list_names >/dev/null 2>&1; then
        printf "[dispatcher] ERROR: registry not loaded\n" >&2
        return 1
    fi

    printf "%-30s  %s\n" "MODULE" "METADATA"
    local _names; _names="$(registry_list_names)"
    local _invalid=0
    local _n _cat _deps _conflicts _c
    local -a _conflict_arr
    if [[ -n "${_names}" ]]; then
        while IFS= read -r _n; do
            [[ -n "${_n}" ]] || continue
            _cat="$(registry_get_field "${_n}" category)"
            _deps="$(registry_get_field "${_n}" deps)"
            _conflicts="$(registry_get_field "${_n}" conflicts)"

            if [[ -z "${_cat}" ]]; then
                printf "%-30s  %s\n" "${_n}" "INVALID (missing category)"
                _invalid=$((_invalid + 1))
                continue
            fi

            # DEPENDS_ON must resolve (resolver returns 2 unknown / 5 cycle).
            if ! resolver_resolve "${_n}" >/dev/null 2>&1; then
                printf "%-30s  %s\n" "${_n}" "INVALID (unresolvable DEPENDS_ON / dep conflict)"
                _invalid=$((_invalid + 1))
                continue
            fi

            # CONFLICTS_WITH must name real modules.
            local _bad_conflict=""
            if [[ -n "${_conflicts}" ]]; then
                read -r -a _conflict_arr <<< "${_conflicts}"
                for _c in "${_conflict_arr[@]}"; do
                    [[ -z "${_c}" ]] && continue
                    if ! registry_has "${_c}"; then
                        _bad_conflict="${_c}"
                        break
                    fi
                done
            fi
            if [[ -n "${_bad_conflict}" ]]; then
                printf "%-30s  %s\n" "${_n}" "INVALID (CONFLICTS_WITH unknown module ${_bad_conflict})"
                _invalid=$((_invalid + 1))
                continue
            fi

            printf "%-30s  %s\n" "${_n}" "OK"
        done <<< "${_names}"
    fi

    if [[ "${_invalid}" -gt 0 ]]; then
        printf "\n[dispatcher] doctor --validate-modules: %s module(s) have invalid metadata\n" "${_invalid}" >&2
        return 2
    fi
    printf "\n[dispatcher] doctor --validate-modules: all module metadata is valid.\n"
}

# _dispatcher_doctor_drift [<module>...]: the state.json-vs-reality report.
# Iterates every module state records as installed, sources each in a fresh
# subshell to run is_installed, and prints a STATE-RECORD vs SYSTEM-ACTUAL
# table. An optional positional filter restricts the table to the named modules
# (intersected with what state records installed) — `doctor <module>` uses it.
# Returns 1 when any drift item is found, 0 when state and host agree.
_dispatcher_doctor_drift() {
    local _filter_str=""
    [[ "$#" -gt 0 ]] && _filter_str=" $* "

    printf "%-30s  %-15s  %-15s  %s\n" "MODULE" "STATE-RECORD" "SYSTEM-ACTUAL" "STATUS"
    local _names; _names="$(state_list_installed)"
    local _issues=0
    local _n _file _actual _status
    if [[ -n "${_names}" ]]; then
        while IFS= read -r _n; do
            [[ -n "${_n}" ]] || continue
            # Scope to the named modules when a filter was supplied.
            [[ -n "${_filter_str}" && "${_filter_str}" != *" ${_n} "* ]] && continue
            _file="$(registry_get_field "${_n}" file)"
            if [[ -z "${_file}" ]]; then
                _actual="not-registered"
                _status="STALE (no module file)"
                _issues=$((_issues + 1))
            elif (
                # shellcheck source=/dev/null  # module path is dynamic; static resolution impossible — https://www.shellcheck.net/wiki/SC1090
                bash --noprofile --norc -c "
                    source '${LIB_DIR}/logger.sh' >/dev/null 2>&1
                    source '${LIB_DIR}/general.sh' >/dev/null 2>&1
                    source '${_file}'
                    is_installed
                " >/dev/null 2>&1
            ); then
                _actual="installed"
                _status="OK"
            else
                _actual="missing"
                _status="DRIFTED (state says yes, host says no)"
                _issues=$((_issues + 1))
            fi
            printf "%-30s  %-15s  %-15s  %s\n" "${_n}" "installed" "${_actual}" "${_status}"
        done <<< "${_names}"
    fi

    if [[ "${_issues}" -gt 0 ]]; then
        printf "\n[dispatcher] doctor found %s drift / inconsistency item(s)\n" "${_issues}" >&2
        printf "[dispatcher] use 'doctor --fix' (planned for 0.3.0) to auto-resolve\n" >&2
        # Diag class (PRD §7.4): 0 = pass, 1 = fail (7 reserved for network).
        return 1
    fi
    printf "\n[dispatcher] doctor: state.json and system are consistent.\n"
    return 0
}

_dispatcher_doctor() {
    # PRD §9.1 / AC-24: `--validate-modules` runs the metadata linter instead
    # of the state-drift report. Parse argv so the flag is honored; an unknown
    # flag is an argument error (exit 2). Positional args name specific modules
    # to diagnose (else every installed module).
    local -a _requested=()
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            --validate-modules)
                _dispatcher_doctor_validate_modules
                return $?
                ;;
            --fix)
                printf "[dispatcher] WARN: %s is stubbed; ignoring\n" "${_arg}" >&2
                ;;
            -*)
                printf "[dispatcher] ERROR: unknown doctor flag %s\n" "${_arg}" >&2
                return 2
                ;;
            *)
                _requested+=("${_arg}")
                ;;
        esac
    done

    if ! declare -F state_list_installed >/dev/null 2>&1; then
        printf "[dispatcher] ERROR: state lib not loaded\n" >&2
        return 1
    fi

    # Named modules must resolve through the registry (argument-class error).
    local _m
    for _m in ${_requested[@]+"${_requested[@]}"}; do
        if declare -F registry_has >/dev/null 2>&1 && ! registry_has "${_m}"; then
            printf "[dispatcher] ERROR: unknown module '%s'\n" "${_m}" >&2
            return 2
        fi
    done

    # Target set: the named modules, else every module recorded installed.
    local -a _targets=()
    if [[ "${#_requested[@]}" -gt 0 ]]; then
        _targets=("${_requested[@]}")
    else
        local _line
        while IFS= read -r _line; do
            [[ -n "${_line}" ]] && _targets+=("${_line}")
        done < <(state_list_installed)
    fi

    # Part 1 (PRESERVED): the state-drift report, scoped to the target set.
    local _drift_rc=0
    _dispatcher_doctor_drift ${_targets[@]+"${_targets[@]}"} || _drift_rc=$?

    # Part 2 (F1 / ADR-0002 / ADR-0009): AUGMENT the drift report by invoking
    # each target module's doctor() override through the runner. This is the
    # wiring the templates promise — without it the overrides were dead code.
    local _doctor_rc=0
    if declare -F runner_doctor >/dev/null 2>&1; then
        runner_doctor ${_targets[@]+"${_targets[@]}"} || _doctor_rc=$?
    fi

    # Diag class (PRD §7.4): 0 = pass, 1 = fail. Fail if EITHER half flags.
    if [[ "${_drift_rc}" -ne 0 || "${_doctor_rc}" -ne 0 ]]; then
        return 1
    fi
    return 0
}

_dispatcher_config() {
    local _action="${1:-}"; shift || true
    case "${_action}" in
        set)
            if [[ "$#" -lt 2 ]]; then
                printf "[dispatcher] ERROR: config set needs <section.key> <value>\n" >&2
                return 2
            fi
            config_set "$@"
            ;;
        get)
            if [[ "$#" -lt 1 ]]; then
                printf "[dispatcher] ERROR: config get needs <section.key>\n" >&2
                return 2
            fi
            config_get "$@"
            ;;
        unset)
            if [[ "$#" -lt 1 ]]; then
                printf "[dispatcher] ERROR: config unset needs <section.key>\n" >&2
                return 2
            fi
            config_unset "$@"
            ;;
        show|"")
            config_show "$@"
            ;;
        *)
            # `config load` was removed (Q6/Q38): config-drop modules go
            # through the normal install pipeline (e.g. `install git-config`).
            printf "[dispatcher] ERROR: unknown config action '%s' (try set/get/unset/show)\n" "${_action}" >&2
            return 2
            ;;
    esac
}

_dispatcher_sync() {
    local _target=""
    local _pull="false"
    local _apply="false"
    local -a _passthrough=()
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            --pull) _pull="true" ;;
            --apply) _apply="true" ;;
            --modules=*|--include-config|--dry-run) _passthrough+=("${_arg}") ;;
            -*) printf "[dispatcher] ERROR: unknown sync flag %s\n" "${_arg}" >&2; return 2 ;;
            *)
                if [[ -z "${_target}" ]]; then
                    _target="${_arg}"
                else
                    printf "[dispatcher] ERROR: sync takes one <user@host>\n" >&2
                    return 2
                fi
                ;;
        esac
    done
    if [[ -z "${_target}" ]]; then
        printf "[dispatcher] ERROR: sync needs <user@host>\n" >&2
        return 2
    fi

    if [[ "${_pull}" == "true" ]]; then
        # sync_pull prints a temp file path on stdout (the downloaded
        # payload) which we feed into the local import pipeline —
        # ADR-0013: dry-run by default, --apply commits.
        local _payload
        _payload="$(sync_pull "${_target}" "${_passthrough[@]}")"
        local _rc=$?
        if [[ "${_rc}" -ne 0 ]]; then return "${_rc}"; fi
        if [[ -n "${_payload}" && -f "${_payload}" ]]; then
            local -a _import_args=("${_payload}")
            [[ "${_apply}" == "true" ]] && _import_args+=("--apply")
            _dispatcher_import "${_import_args[@]}"
            _rc=$?
            rm -f "${_payload}"
            return "${_rc}"
        fi
    else
        # Push defaults to dry-run on the remote side too (ADR-0013):
        # without --apply the remote prints its diff back over ssh.
        [[ "${_apply}" == "true" ]] && _passthrough+=("--apply")
        sync_push "${_target}" "${_passthrough[@]}"
    fi
}

# ── Stub group (remaining) ──────────────────────────────────────────────────

_dispatcher_stub() {
    local _name="$1"
    printf "[dispatcher] '%s' is not implemented yet (planned for a later phase)\n" "${_name}" >&2
    return 1
}

# ── Main dispatch ────────────────────────────────────────────────────────────

# ── Global flags (PRD §7.5, issue #45) ──────────────────────────────────────
# Position-independent flags consumed before subcommand routing:
#   --color=auto|always|never  → color_init (lib/color.sh)
#   --verbose / -v             → LOG_LEVEL=DEBUG
#   --quiet                    → LOG_LEVEL=WARN
# Fills the caller-scoped array DISPATCHER_ARGV with the remaining argv
# (bash dynamic scoping: dispatcher_dispatch declares it local).
# Returns 2 on an invalid --color value.
_dispatcher_parse_global_flags() {
    DISPATCHER_ARGV=()
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            --color=*)
                if declare -F color_init >/dev/null 2>&1; then
                    color_init "${_arg#--color=}" || return 2
                fi
                ;;
            -v|--verbose) export LOG_LEVEL=DEBUG ;;
            --quiet)      export LOG_LEVEL=WARN ;;
            *) DISPATCHER_ARGV+=("${_arg}") ;;
        esac
    done
    return 0
}

dispatcher_dispatch() {
    local -a DISPATCHER_ARGV=()
    _dispatcher_parse_global_flags "$@" || return 2
    set -- ${DISPATCHER_ARGV[@]+"${DISPATCHER_ARGV[@]}"}

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
        update)  _dispatcher_update_removed ;;
        upgrade) _dispatcher_upgrade "$@" ;;
        verify)  _dispatcher_verify "$@" ;;
        search)  _dispatcher_search "$@" ;;
        doctor)  _dispatcher_doctor "$@" ;;
        config)  _dispatcher_config "$@" ;;
        sync)    _dispatcher_sync "$@" ;;
        install|remove|purge)
            _dispatcher_lifecycle "${_sub}" "$@"
            ;;
        self-upgrade)
            _dispatcher_stub "${_sub}"
            ;;
        *)
            printf "[dispatcher] ERROR: unknown subcommand '%s'\n" "${_sub}" >&2
            printf "Run 'setup_ubuntu --help' to see the supported subcommands.\n" >&2
            return 2
            ;;
    esac
}
