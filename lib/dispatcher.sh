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

# ── Responsibility-cluster libs (architecture-review E1) ─────────────────────
# lib/dispatcher.sh stays a thin orchestrator: global-flag parsing + subcommand
# routing + the shared i18n table above. The cohesive handler clusters live in
# sibling libs, sourced here (after DISPATCHER_I18N is declared, so their
# runtime i18n_t lookups resolve). They are behavior-identical extractions of
# what used to be one 1291-line god-file:
#   dispatcher_render.sh    module-metadata → JSON / description renderers
#   dispatcher_catalog.sh   list / show / search / detect (read-only)
#   dispatcher_lifecycle.sh install / remove / purge / upgrade / verify / doctor
#   dispatcher_state_io.sh  status / export / import / config / sync
_dispatcher_dir="${BASH_SOURCE[0]%/*}"
# shellcheck source=lib/dispatcher_render.sh
source "${_dispatcher_dir}/dispatcher_render.sh"
# shellcheck source=lib/dispatcher_catalog.sh
source "${_dispatcher_dir}/dispatcher_catalog.sh"
# shellcheck source=lib/dispatcher_lifecycle.sh
source "${_dispatcher_dir}/dispatcher_lifecycle.sh"
# shellcheck source=lib/dispatcher_state_io.sh
source "${_dispatcher_dir}/dispatcher_state_io.sh"
unset _dispatcher_dir

# ── Help / version ───────────────────────────────────────────────────────────

_dispatcher_usage() {
    printf '%s\n' "$(i18n_t DISPATCHER_I18N usage)"
}

_dispatcher_version() {
    printf "init_ubuntu %s\n" "${INIT_UBUNTU_VERSION}"
}

# ── update (removed) / stub ──────────────────────────────────────────────────

# `update` was removed (PRD §7.2, Q40): the registry is in-memory and
# rebuilt by a dynamic scan on every run — there is no index to go stale.
# It is treated as an unknown subcommand (exit 2) with a targeted hint.
_dispatcher_update_removed() {
    printf "[dispatcher] ERROR: unknown subcommand 'update' (removed; the registry is rebuilt in-memory on every run)\n" >&2
    printf "[dispatcher] hint: release freshness comes from the gh-latest cache (TTL 1h, see PRD §7.6);\n" >&2
    printf "[dispatcher] hint: to update the tool itself, use 'self-upgrade' (planned for 0.3.0).\n" >&2
    return 2
}

_dispatcher_stub() {
    local _name="$1"
    printf "[dispatcher] '%s' is not implemented yet (planned for a later phase)\n" "${_name}" >&2
    return 1
}

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

# ── Main dispatch ────────────────────────────────────────────────────────────

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
