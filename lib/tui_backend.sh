#!/usr/bin/env bash
# lib/tui_backend.sh — TUI backend detection + menu data helpers (PRD §8, G4)
#
# The TUI is a *frontend* of the CLI (PRD §8 / G4): it renders screens and
# collects selections only. Everything here either
#   - probes / wraps the dialog backend (`dialog` preferred, `whiptail`
#     fallback — §8.5, no auto-install), or
#   - parses ADR-0019 `list --json` / `detect --json` payloads produced by
#     forked `setup_ubuntu` subprocesses.
# This lib NEVER sources engine libs (registry / resolver / runner / state)
# and NEVER writes state — enforced by the G4 grep gate in
# test/unit/tui_backend_spec.bats.
#
# Public API:
#   tui_backend_detect            Print "dialog"|"whiptail"; rc 1 when both missing
#   tui_backend_init              Export TUI_BACKEND or print §8.5 guidance (rc 1)
#   tui_require_sudo              rc 0 when sudo usable; rc 4 + CLI hint otherwise
#   tui_cli_list_json             Fork `setup_ubuntu list --json` (validated)
#   tui_cli_detect_json           Fork `setup_ubuntu detect --json` (validated)
#   tui_categories <json>         Non-empty categories, canonical order (Q44)
#   tui_category_stats <json> <c> "<installed> <total>" for category <c>
#   tui_modules_in_category <json> <c>   Module names, alphabetical
#   tui_main_menu_entries <json>  §8.1 rows as "tag<TAB>label<TAB>description"
#   tui_system_summary <json>     §8.1 one-line header from detect --json
#   tui_checklist_entries <json> <c> <sel>
#                                 §8.2 checklist rows "name<TAB>label<TAB>on|off"
#                                 grouped by TAGS[0], deps collapsed (Q-A3)
#   tui_selection_replace_page / tui_selection_list / tui_selection_count
#                                 In-memory Q43 accumulator (never persisted)
#   tui_cli_install_plan <m...>   Fork `setup_ubuntu install --dry-run` → order
#   tui_plan_deps <plan> <m...>   Plan minus selection = "will pull N deps"
#   tui_install_args <ovr> <m...> Argv for the Proceed fork (one per line)
#   tui_platform_choices          §7.5 form factors as "tag<TAB>desc" rows
#   tui_effective_form_factor <detect_json> <ovr>
#                                 Override (when set) else detected form factor
#   tui_qs_recommended_entries <json> <form>
#                                 §8.2.1 Step-2 rows "name<TAB>label<TAB>on|off"
#                                 (§15.3 platform filter → Q36 enabled tri-state
#                                 → engine `recommended` preselect)
#   tui_qs_tag_entries <json> <tag> <form>
#                                 Same row shape for one TAGS group (Step 3/4)
#   tui_cli_installed_json        Fork `setup_ubuntu list --installed --json`
#   tui_installed_entries <state_json> <list_json> <flat|grouped>
#                                 §8.3 rows "name<TAB>display" (version +
#                                 installed_at; grouped = TAGS[0] buckets)
#   tui_manage_args <action> <m>  Argv for the Update/Remove/Purge fork
#   tui_cli_manage_plan <a> <m>   Fork `<action> --dry-run --no-deps` → order
#   tui_manage_confirm_text <a> <m> <plan>
#                                 §8.4 confirm body (exact cmd + plan + state)
#   tui_render_menu / tui_render_msgbox / tui_render_yesno / tui_render_checklist
#                                 Thin backend wrappers (argv-level unit tests
#                                 via a mock widget binary; live-widget smoke
#                                 belongs to the AC-10 expect harness)
#
# Internal probes `_tui_has_cmd` / `_tui_has_sudo` are deliberately small
# named functions so bats can override them with mocks (same pattern as
# lib/preflight.sh).

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not an executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# i18n engine (issue #185): provides i18n_t. The entrypoint sources this first,
# but this lib is also sourced standalone by the unit bats — guard so the source
# is idempotent and the helper is always available wherever tui_backend is used.
if ! declare -F i18n_t >/dev/null 2>&1; then
    # shellcheck source=lib/i18n.sh
    source "${BASH_SOURCE[0]%/*}/i18n.sh"
fi

# ── i18n table (#185): strings tui_backend.sh ITSELF authors ─────────────────
# Pass-through caller strings (module descriptions, ADR-0019 payload text) are
# NOT translated here — only this lib's own default widget labels / prompts /
# menu captions / confirm bodies. `en.<key>` is byte-identical to the prior
# English literal; zh-TW uses full-width punctuation. {0}{1} are i18n_t args.
# kcov-exclude-start (i18n data table; excluded from coverage — kcov counts each entry line as uncoverable, issue #185)
declare -gA TUI_BACKEND_I18N=(
    # Pre-launch gum install prompt (_tui_prelaunch_backend).
    [en.prompt_install_gum]="Install gum for a nicer TUI? [Y/n] "
    [zh-TW.prompt_install_gum]="是否安裝 gum 以獲得更佳的 TUI 體驗? [Y/n] "

    # gum msgbox "continue" footer (_tui_msgbox_gum).
    [en.press_enter]="Press Enter to continue..."
    [zh-TW.press_enter]="按 Enter 繼續..."

    # §7.5 form-factor menu labels (tui_platform_choices).
    [en.pf_desktop]="Desktop / laptop"
    [zh-TW.pf_desktop]="桌機 / 筆電"
    [en.pf_server]="Headless server"
    [zh-TW.pf_server]="無頭伺服器"
    [en.pf_wsl]="Windows Subsystem for Linux"
    [zh-TW.pf_wsl]="Windows Subsystem for Linux"
    [en.pf_rpi4]="Raspberry Pi 4"
    [zh-TW.pf_rpi4]="Raspberry Pi 4"
    [en.pf_rpi5]="Raspberry Pi 5"
    [zh-TW.pf_rpi5]="Raspberry Pi 5"
    [en.pf_jetson]="NVIDIA Jetson Orin"
    [zh-TW.pf_jetson]="NVIDIA Jetson Orin"

    # §8.1 main-menu category rows (_tui_category_entry) + fixed rows
    # (tui_main_menu_entries). Labels carry {0}/{1} where a count is rendered.
    [en.cat_base_label]="Base Tools"
    [zh-TW.cat_base_label]="基礎工具"
    [en.cat_base_desc]="View / toggle base modules"
    [zh-TW.cat_base_desc]="檢視 / 切換基礎模組"
    [en.cat_recommended_label]="Recommended ({0}/{1})"
    [zh-TW.cat_recommended_label]="推薦 ({0}/{1})"
    [en.cat_recommended_desc]="Environment-aware suggestions"
    [zh-TW.cat_recommended_desc]="依環境提供的建議"
    [en.cat_optional_label]="Optional"
    [zh-TW.cat_optional_label]="選用"
    [en.cat_optional_desc]="Browse optional modules"
    [zh-TW.cat_optional_desc]="瀏覽選用模組"
    [en.cat_experimental_label]="Experimental"
    [zh-TW.cat_experimental_label]="實驗性"
    [en.cat_experimental_desc]="Browse experimental modules"
    [zh-TW.cat_experimental_desc]="瀏覽實驗性模組"

    [en.menu_quick_setup_label]="Quick Setup"
    [zh-TW.menu_quick_setup_label]="快速安裝"
    [en.menu_quick_setup_desc]="Install all recommended"
    [zh-TW.menu_quick_setup_desc]="安裝所有推薦項目"
    [en.menu_manage_label]="Manage Installed"
    [zh-TW.menu_manage_label]="管理已安裝項目"
    [en.menu_manage_desc]="Update / Remove / Purge"
    [zh-TW.menu_manage_desc]="更新 / 移除 / 清除"
    [en.menu_secrets_label]="Manage Secrets"
    [zh-TW.menu_secrets_label]="管理密鑰"
    [en.menu_secrets_desc]="setup_secrets (SSH/GPG)"
    [zh-TW.menu_secrets_desc]="setup_secrets (SSH/GPG)"
    [en.menu_sysinfo_label]="System Info"
    [zh-TW.menu_sysinfo_label]="系統資訊"
    [en.menu_sysinfo_desc]="Environment detection details"
    [zh-TW.menu_sysinfo_desc]="環境偵測詳細資訊"
    [en.menu_run_label]="Run"
    [zh-TW.menu_run_label]="執行"
    [en.menu_run_desc]="Review & install selected modules"
    [zh-TW.menu_run_desc]="檢閱並安裝所選模組"

    # §8.4 destructive-action confirm body (tui_manage_confirm_text).
    [en.confirm_about_to]="About to {0} '{1}':"
    [zh-TW.confirm_about_to]="即將對 '{1}' 執行 {0}:"
    [en.confirm_run]="  - run: setup_ubuntu {0}"
    [zh-TW.confirm_run]="  - 執行: setup_ubuntu {0}"
    [en.confirm_action_module]="  - {0} module: {1}"
    [zh-TW.confirm_action_module]="  - {0} 模組: {1}"
    [en.confirm_remove_from_state]="  - remove '{0}' from state.json"
    [zh-TW.confirm_remove_from_state]="  - 從 state.json 移除 '{0}'"
    [en.confirm_purge_note]="Purge also deletes the module's config files (CONFIG_PATHS)."
    [zh-TW.confirm_purge_note]="清除也會刪除該模組的設定檔 (CONFIG_PATHS)。"
    [en.confirm_remove_note]="The module's config files are retained (Purge deletes them too)."
    [zh-TW.confirm_remove_note]="該模組的設定檔會保留 (清除則會一併刪除)。"
)
# kcov-exclude-end
# TUI_BACKEND_I18N is consumed by i18n_t via a nameref on the table NAME passed
# as a bareword argument — static analysis cannot follow that indirection, so
# make the read explicit here to keep shellcheck honest (no disable directive).
: "${TUI_BACKEND_I18N[@]+x}"

# Canonical CATEGORY order (PRD §6.3 / module contract §9.1).
TUI_CATEGORY_ORDER='["base","recommended","optional","experimental"]'

# Backend dialog geometry. dialog autosizes with 0s but whiptail does not,
# so fixed sizes keep both backends rendering identically (§8.5).
: "${TUI_HEIGHT:=20}"
: "${TUI_WIDTH:=72}"
: "${TUI_MENU_HEIGHT:=10}"

# Sentinel tag for a non-selectable main-menu separator row (#169). The
# dispatch loop ignores it; both dialog and whiptail render arbitrary
# tag/item rows, so a divider row works identically on both backends.
: "${TUI_MENU_SEPARATOR:=-}"

# Checklist chrome (#168): dialog/whiptail render a --checklist row as
# "[status] <tag>   <item>". The fixed overhead is the checkbox + its gutter
# plus the gutter between the tag column and the item — empirically 8 cols on
# both backends for a 72-col box. The item budget is therefore
#   TUI_WIDTH - (longest visible tag/name width) - TUI_CHECKLIST_CHROME
# floored to TUI_CHECKLIST_MIN so a narrow box still shows a usable stub.
: "${TUI_CHECKLIST_CHROME:=8}"
: "${TUI_CHECKLIST_MIN:=20}"

# ── Pure display helpers ─────────────────────────────────────────────────────

# _tui_clip <string> <max> → <string> clipped to <max> chars with a trailing
# single-char ellipsis "…" when it would exceed <max>, unchanged otherwise.
# Pure (no globals, no I/O) so it is directly unit-testable.
_tui_clip() {
    local _s="$1" _max="$2"
    # UTF-8 locale so ${#_s} counts characters (not bytes) and ${_s:0:n}
    # slices on character boundaries — module descriptions carry zh-TW
    # (multibyte), and CI's kcov image runs under C/POSIX where byte-vs-char
    # would mis-truncate. C.UTF-8 is always present on Debian/Ubuntu.
    local LC_ALL=C.UTF-8
    if (( ${#_s} > _max )); then
        printf '%s…\n' "${_s:0:_max-1}"
    else
        printf '%s\n' "${_s}"
    fi
}

# _tui_disp_width <string> → terminal display COLUMNS on stdout. Counts
# East-Asian Wide / Fullwidth codepoints (CJK ideographs, kana, hangul,
# fullwidth punctuation) as 2 columns and everything else as 1. zh-TW / ja
# labels are double-width, so a char-count pad (printf '%-Ns') makes the menu
# description column ragged — this is the width primitive that fixes it.
# Pure (no globals, no I/O) so it is directly unit-testable.
_tui_disp_width() {
    local _s="$1" _i _ch _cp _w=0
    # UTF-8 locale: ${_s:_i:1} slices on char boundaries and the printf "'…"
    # trick yields the multibyte codepoint (not a raw byte). C.UTF-8 is always
    # present on Debian/Ubuntu and in the kcov image (see _tui_clip).
    local LC_ALL=C.UTF-8
    for (( _i = 0; _i < ${#_s}; _i++ )); do
        _ch="${_s:_i:1}"
        printf -v _cp '%d' "'${_ch}"
        if (( (_cp >= 0x1100 && _cp <= 0x115F) \
           || (_cp >= 0x2E80 && _cp <= 0x303E) \
           || (_cp >= 0x3041 && _cp <= 0x33FF) \
           || (_cp >= 0x3400 && _cp <= 0x4DBF) \
           || (_cp >= 0x4E00 && _cp <= 0x9FFF) \
           || (_cp >= 0xA000 && _cp <= 0xA4CF) \
           || (_cp >= 0xAC00 && _cp <= 0xD7A3) \
           || (_cp >= 0xF900 && _cp <= 0xFAFF) \
           || (_cp >= 0xFE30 && _cp <= 0xFE4F) \
           || (_cp >= 0xFF00 && _cp <= 0xFF60) \
           || (_cp >= 0xFFE0 && _cp <= 0xFFE6) \
           || (_cp >= 0x20000 && _cp <= 0x3FFFD) )); then
            _w=$(( _w + 2 ))
        else
            _w=$(( _w + 1 ))
        fi
    done
    printf '%s\n' "${_w}"
}

# _tui_pad_label <label> <columns> → <label> right-padded with spaces to at
# least <columns> DISPLAY columns (never truncates). Display-width aware so
# zh-TW / ja labels align the same as ASCII ones. Pure (no globals, no I/O).
_tui_pad_label() {
    local _label="$1" _cols="$2" _w _pad
    _w="$(_tui_disp_width "${_label}")"
    _pad=$(( _cols > _w ? _cols - _w : 0 ))
    printf '%s%*s' "${_label}" "${_pad}" ''
}

# _tui_clip_budget <tag1> <tag2> ... → per-page item width budget on stdout.
# The budget is derived from the longest tag/name across the rows, so each
# checklist sizes its own tag column:
#   budget = TUI_WIDTH - longest-name - TUI_CHECKLIST_CHROME  (floored to MIN)
# Pure (no globals beyond the TUI_* knobs, no I/O) — directly unit-testable.
_tui_clip_budget() {
    local LC_ALL=C.UTF-8  # char-accurate widths for the budget math (see _tui_clip)
    local _name _longest=0
    for _name in "$@"; do
        (( ${#_name} > _longest )) && _longest=${#_name}
    done
    local _budget=$(( TUI_WIDTH - _longest - TUI_CHECKLIST_CHROME ))
    (( _budget < TUI_CHECKLIST_MIN )) && _budget=${TUI_CHECKLIST_MIN}
    printf '%s\n' "${_budget}"
}

# _tui_clip_checklist_args <tag item status ...> → the same triples on stdout
# (one field per line) with each ITEM field (the rendered "[tag] description")
# clipped to the whiptail box budget; tag and status pass through untouched.
# This is the #168 clip — it lives in the WHIPTAIL adapter only (#183): the
# shared entries producers now emit FULL descriptions so the gum backend, which
# manages its own width, renders them unclipped. The budget needs the longest
# tag first, so we buffer all triples (checklists are short — tens of rows).
_tui_clip_checklist_args() {
    local -a _tags=() _items=() _stats=()
    while (( $# >= 3 )); do
        _tags+=("$1"); _items+=("$2"); _stats+=("$3"); shift 3
    done
    local _budget
    _budget="$(_tui_clip_budget "${_tags[@]}")"
    local _i
    for _i in "${!_tags[@]}"; do
        printf '%s\n%s\n%s\n' \
            "${_tags[_i]}" "$(_tui_clip "${_items[_i]}" "${_budget}")" "${_stats[_i]}"
    done
}

# ── Probes (mockable) ────────────────────────────────────────────────────────

_tui_has_cmd() {
    command -v -- "$1" >/dev/null 2>&1
}

# 0 = we can escalate (root, passwordless sudo, or interactive sudo).
# Mirrors lib/preflight.sh `_preflight_has_sudo` — duplicated on purpose:
# sourcing preflight would couple the TUI to engine startup (G4).
_tui_has_sudo() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        return 0
    fi
    _tui_has_cmd sudo || return 1
    if sudo -n true 2>/dev/null; then
        return 0
    fi
    # sudo exists but wants a password — only viable when a tty can prompt.
    [[ -t 0 ]]
}

# ── Backend selection (§8.5, #171: gum > whiptail; dialog dropped) ───────────

# Print the chosen backend on stdout. Preference: gum > whiptail (#171 —
# dialog dropped from the set). A pre-set TUI_BACKEND (gum|whiptail) is an
# explicit override and short-circuits probing (the --backend flag / CI lever).
tui_backend_detect() {
    case "${TUI_BACKEND:-}" in
        gum | whiptail)
            printf '%s\n' "${TUI_BACKEND}"
            return 0
            ;;
    esac
    if _tui_has_cmd gum; then
        printf 'gum\n'
        return 0
    fi
    if _tui_has_cmd whiptail; then
        printf 'whiptail\n'
        return 0
    fi
    return 1
}

# Export TUI_BACKEND, or print the §8.5 fix guidance and return 1.
# No auto-install — apt is only ever *suggested* to the user.
tui_backend_init() {
    if ! TUI_BACKEND="$(tui_backend_detect)"; then
        cat >&2 <<'EOF'
FATAL: TUI requires 'gum' (preferred) or 'whiptail' (default Ubuntu).
       Both missing — your install is unusually stripped.
       Fix:  sudo apt install whiptail
       Or:   use CLI mode: setup_ubuntu install <module>
EOF
        return 1
    fi
    export TUI_BACKEND
}

# ── Pre-launch backend resolution (#171) ─────────────────────────────────────
# Decide which backend to launch with, possibly offering to install gum.
# Prints the resolved backend ("gum"|"whiptail") on stdout; the §8.5 fatal
# guidance + rc 1 only when whiptail itself is missing (no backend at all).
#
# Flow:
#   gum present                         → gum (no prompt)
#   gum absent + interactive (-t 0)     → plain stdin read prompt (default Yes)
#       yes → fork `setup_ubuntu install gum` (G4: the TUI installs nothing
#             itself), re-check `command -v gum`; success → gum, else warn +
#             whiptail
#       no  → whiptail
#   gum absent + non-interactive        → whiptail silently
#
# The prompt is plain stdin/stdout — no TUI tool is assumed at this point.
# `_tui_stdin_is_tty` is a tiny mockable seam (same pattern as _tui_has_cmd).
_tui_stdin_is_tty() { [[ -t 0 ]]; }

_tui_prelaunch_backend() {
    if _tui_has_cmd gum; then
        printf 'gum\n'
        return 0
    fi
    if ! _tui_has_cmd whiptail; then
        # No backend at all → reuse the §8.5 fatal guidance.
        tui_backend_init >/dev/null
        return 1
    fi
    if ! _tui_stdin_is_tty; then
        printf 'whiptail\n'  # non-interactive: no prompt (#171)
        return 0
    fi

    # Interactive: plain stdin prompt, default Yes.
    i18n_t TUI_BACKEND_I18N prompt_install_gum >&2
    local _ans=""
    read -r _ans || _ans=""
    case "${_ans}" in
        [Nn] | [Nn][Oo])
            printf 'whiptail\n'
            return 0
            ;;
    esac

    # Yes (default): fork the CLI to install gum (G4 — never install here).
    # The fork's stdout is redirected to stderr so command-substitution
    # callers capture ONLY the resolved backend name from this function.
    if "${TUI_CLI:?TUI_CLI not set}" install gum >&2 && _tui_has_cmd gum; then
        printf 'gum\n'
        return 0
    fi
    printf 'WARN: gum install failed — falling back to whiptail.\n' >&2
    printf 'whiptail\n'
}

# ── Sudo gate (PRD §8.5: no sudo → exit 4, suggest CLI mode) ────────────────

tui_require_sudo() {
    if _tui_has_sudo; then
        return 0
    fi
    cat >&2 <<'EOF'
ERROR: the TUI needs sudo to be available (module installs escalate).
       sudo is not usable here — switch to CLI mode instead:
         setup_ubuntu list
         setup_ubuntu install <module> --install-target=user-home
EOF
    return 4
}

# ── CLI fork helpers (G4 single data path) ───────────────────────────────────
# TUI_CLI is set by setup_ubuntu_tui.sh. Both helpers validate that the
# subprocess actually produced JSON so a stubbed / failing CLI surfaces as
# one clear error instead of downstream jq noise.

_tui_cli_json() {
    local _payload
    if ! _payload="$("${TUI_CLI:?TUI_CLI not set}" "$@" 2>/dev/null)"; then
        printf "ERROR: 'setup_ubuntu %s' failed\n" "$*" >&2
        return 1
    fi
    if ! jq -e . >/dev/null 2>&1 <<<"${_payload}"; then
        printf "ERROR: 'setup_ubuntu %s' did not return JSON (ADR-0019)\n" "$*" >&2
        return 1
    fi
    printf '%s\n' "${_payload}"
}

tui_cli_list_json()      { _tui_cli_json list --json; }
tui_cli_detect_json()    { _tui_cli_json detect --json; }
tui_cli_installed_json() { _tui_cli_json list --installed --json; }

# Resolver-ordered install plan for the Review screen, one module per line:
#   tui_cli_install_plan <module...>
# Forks `setup_ubuntu install --dry-run <module...>` and strips the
# "  - <name>" bullets. The resolver stays the single dep authority (G4) —
# the TUI never recomputes dep closures itself.
tui_cli_install_plan() {
    local _out
    if ! _out="$("${TUI_CLI:?TUI_CLI not set}" install --dry-run "$@" 2>/dev/null)"; then
        printf "ERROR: 'setup_ubuntu install --dry-run %s' failed\n" "$*" >&2
        return 1
    fi
    if [[ "${_out}" != *"DRY-RUN: would install"* ]]; then
        printf "ERROR: 'setup_ubuntu install --dry-run %s' returned no plan\n" "$*" >&2
        return 1
    fi
    awk '/^  - / { sub(/^  - /, ""); print }' <<<"${_out}"
}

# Pulled-in deps = plan minus the user's own selection (the "will pull N
# deps" payload, arch Q-A3 collapsed summary):
#   tui_plan_deps <plan-lines> <selected...>
tui_plan_deps() {
    local _plan="$1"
    shift
    local _selected=" $* " _name
    while IFS= read -r _name; do
        [[ -z "${_name}" ]] && continue
        if [[ "${_selected}" != *" ${_name} "* ]]; then
            printf '%s\n' "${_name}"
        fi
    done <<<"${_plan}"
}

# ── ADR-0019 payload parsing ─────────────────────────────────────────────────

# Non-empty categories present in the payload, canonical order (Q44:
# empty CATEGORYs — experimental today — never reach the main menu).
tui_categories() {
    jq -r --argjson order "${TUI_CATEGORY_ORDER}" '
        ([.items[].category] | unique) as $present
        | $order | map(select(. as $c | $present | index($c))) | .[]
    ' <<<"$1"
}

# "<installed-count> <total>" for one category.
tui_category_stats() {
    jq -r --arg c "$2" '
        [.items[] | select(.category == $c)]
        | "\([.[] | select(.installed == true)] | length) \(length)"
    ' <<<"$1"
}

# Module names in one category, alphabetical (ADR-0019 sort order).
tui_modules_in_category() {
    jq -r --arg c "$2" '
        [.items[] | select(.category == $c) | .name] | sort | .[]
    ' <<<"$1"
}

# ── Checkbox accumulator data (#70, Q43 / §8.2) ──────────────────────────────

# Checklist rows for one category as "name<TAB>label<TAB>on|off" lines.
#   tui_checklist_entries <list_json> <category> <selected>
# <selected> is a space-separated module-name list (the in-memory
# accumulator) — those rows come back "on" so reopening a page shows the
# current selection. Rows are grouped by TAGS[0] (§8.2: each module shows
# up only under its first tag), groups and names alphabetical. Dep chains
# stay collapsed: a "(will pull N deps)" hint per §8.2 / arch Q-A3, never
# the expanded chain (the Review screen owns the expandable detail).
# The label is emitted FULL (#183): clipping to the whiptail box budget happens
# inside the whiptail adapter (_tui_checklist_whiptail), so gum shows full text.
tui_checklist_entries() {
    local _json="$1" _cat="$2" _selected=" ${3:-} "
    jq -r --arg c "$2" --arg sel "${_selected}" '
        [.items[] | select(.category == $c)]
        | sort_by(.tags[0], .name)
        | .[]
        | .name as $n
        | ((.depends_on // []) | length) as $ndeps
        | "\($n)\t[\(.tags[0])] \(.description)"
          + (if $ndeps > 0 then " (will pull \($ndeps) deps)" else "" end)
          + "\t"
          + (if ($sel | contains(" " + $n + " ")) then "on" else "off" end)
    ' <<<"$1"
}

# ── In-memory selection accumulator (Q43) ────────────────────────────────────
# The whole accumulator lives in this associative array (module → 1) inside
# the TUI process. Q43 contract: it NEVER touches disk — `< Exit >` simply
# drops the process and with it every selection (zero side effects).
declare -gA TUI_SELECTION=()

# `< OK >` semantics for one checklist page (§8.1 execution model):
#   tui_selection_replace_page <list_json> <category> [<name>...]
# Drops every module belonging to <category> from the accumulator, then
# stores the page's checked names — so unchecking sticks and other
# categories' selections survive. `< Back >` is simply "don't call this".
tui_selection_replace_page() {
    local _json="$1" _cat="$2"
    shift 2
    local _name
    while IFS= read -r _name; do
        unset "TUI_SELECTION[${_name}]"
    done < <(tui_modules_in_category "${_json}" "${_cat}")
    for _name in "$@"; do
        TUI_SELECTION["${_name}"]=1
    done
}

# Accumulated module names, sorted, one per line (empty output when none).
tui_selection_list() {
    [[ "${#TUI_SELECTION[@]}" -eq 0 ]] && return 0
    printf '%s\n' "${!TUI_SELECTION[@]}" | sort
}

tui_selection_count() {
    printf '%s\n' "${#TUI_SELECTION[@]}"
}

# Argv for the Proceed fork, one arg per line (G4: the TUI runs
# `"${TUI_CLI}" $(this)` — it never assembles a shell string, so module
# names can't be re-split or glob-expanded):
#   tui_install_args <platform_override> <module...>
# `-y` because Review & Install IS the confirmation — re-prompting via the
# CLI's apt-style Proceed? would double-ask (§8.2.1 Proceed semantics).
tui_install_args() {
    local _override="$1"
    shift
    printf 'install\n'
    if [[ -n "${_override}" ]]; then
        printf -- '--profile=%s\n' "${_override}"
    fi
    local _name
    for _name in "$@"; do
        printf '%s\n' "${_name}"
    done
    printf -- '-y\n'
}

# ── Quick Setup data (#71, §8.2.1) ───────────────────────────────────────────

# §7.5 / §15.2 form-factor vocabulary as "tag<TAB>description" rows —
# single source for every platform-override menu (System Info, Quick
# Setup Step 1).
tui_platform_choices() {
    printf 'desktop\t%s\n'     "$(i18n_t TUI_BACKEND_I18N pf_desktop)"
    printf 'server\t%s\n'      "$(i18n_t TUI_BACKEND_I18N pf_server)"
    printf 'wsl\t%s\n'         "$(i18n_t TUI_BACKEND_I18N pf_wsl)"
    printf 'rpi-4\t%s\n'       "$(i18n_t TUI_BACKEND_I18N pf_rpi4)"
    printf 'rpi-5\t%s\n'       "$(i18n_t TUI_BACKEND_I18N pf_rpi5)"
    printf 'jetson-orin\t%s\n' "$(i18n_t TUI_BACKEND_I18N pf_jetson)"
}

# The form factor the wizard filters against: the in-memory override when
# the user picked one (§8.2.1 Step 1), else the detect payload's verdict.
#   tui_effective_form_factor <detect_json> <override>
tui_effective_form_factor() {
    if [[ -n "${2:-}" ]]; then
        printf '%s\n' "$2"
        return 0
    fi
    jq -r '.form_factor // "unknown"' <<<"$1"
}

# Quick Setup row builder: "name<TAB>label<TAB>on|off" lines, §15.3 filter
# pipeline order. The two #71 additive ADR-0019 fields drive it:
#   recommended  bool|null  engine is_recommended() verdict
#   enabled      bool|null  Q36 `[modules.<n>] enabled` config tri-state
# Pipeline: SUPPORTED_PLATFORMS ∋ form factor FIRST (fail → row dropped,
# is_recommended never consulted), then enabled=false → dropped (force
# exclude), enabled=true → "on" (force include), unset → recommended
# decides the precheck. Absent fields read as null (ADR-0019: additive
# fields are optional), which lands on "off" — never a silent install.
# Descriptions are emitted FULL (#183): the whiptail adapter clips, gum doesn't.
#   _tui_qs_entries <list_json> category <category> <form>
#   _tui_qs_entries <list_json> tag <tag> <form>
_tui_qs_entries() {
    jq -r --arg key "$2" --arg v "$3" --arg f "$4" '
        [.items[]
         | select(if $key == "category"
                  then .category == $v
                  else ((.tags // []) | index($v)) != null end)
         | select(((.supported_platforms // []) | index($f)) != null)
         | select(.enabled != false)]
        | sort_by(.name)
        | .[]
        | "\(.name)\t\(.description)\t"
          + (if .enabled == true or .recommended == true then "on" else "off" end)
    ' <<<"$1"
}

# §8.2.1 Step 2: recommended-category modules surviving the filter pipeline.
tui_qs_recommended_entries() { _tui_qs_entries "$1" category recommended "$2"; }

# §8.2.1 Steps 3/4: one TAGS group (cli-essentials suite / agent CLIs).
tui_qs_tag_entries() { _tui_qs_entries "$1" tag "$2" "$3"; }

# ── Manage Installed data + action argv (#72, §8.3 / §8.4) ───────────────────

# §8.3 rows as "name<TAB>display" lines:
#   tui_installed_entries <state_json> <list_json> <flat|grouped>
# <state_json> is the forked `list --installed --json` payload (raw
# state.json, ADR-0018) — the single §8.3 data source for version /
# installed_at. <list_json> only supplies TAGS[0] for the grouped view;
# modules missing from it (file deleted, state survives) fall back to the
# "other" bucket instead of erroring. flat sorts by name, grouped by
# tag-then-name with a "[tag]" prefix (same convention as §8.2 checklists).
tui_installed_entries() {
    local _state="$1" _list="$2" _mode="${3:-flat}"
    jq -r --argjson list "${_list}" --arg mode "${_mode}" '
        ([$list.items[]? | {key: .name, value: (.tags[0] // "other")}]
         | from_entries) as $tagof
        | (.installed // {}) | to_entries
        | map({name: .key,
               version: (((.value.synced.version_provided // "?")
                          + "              ")[0:14]),
               at: ((.value.synced.installed_at // "?")
                    | sub("T"; " ") | .[0:16]),
               tag: ($tagof[.key] // "other")})
        | (if $mode == "grouped" then sort_by(.tag, .name)
           else sort_by(.name) end)
        | .[]
        | if $mode == "grouped"
          then "\(.name)\t[\(.tag)] \(.version)\(.at)"
          else "\(.name)\t\(.version)\(.at)"
          end
    ' <<<"${_state}"
}

# Argv for an Update / Remove / Purge fork, one arg per line (G4 — same
# never-a-shell-string contract as tui_install_args):
#   tui_manage_args <update|remove|purge> <module>
# - update maps to the CLI's `upgrade` subcommand (`update` was removed,
#   PRD §7.2 Q40); upgrade takes only the named modules, no dep expansion.
# - remove/purge pass --no-deps: the resolver expands DEPENDS_ON closures
#   (correct for install), but tearing down a module must NOT cascade into
#   its still-shared dependencies. §8.4 scopes the action to the named
#   module only.
# - `-y` because the TUI owns consent: the action menu (update) or the
#   §8.4 Proceed button (remove/purge) IS the confirmation — the CLI's own
#   prompt would double-ask.
tui_manage_args() {
    local _action="$1" _module="$2"
    case "${_action}" in
        update)       printf 'upgrade\n%s\n-y\n' "${_module}" ;;
        remove|purge) printf '%s\n--no-deps\n%s\n-y\n' "${_action}" "${_module}" ;;
        *)
            printf 'ERROR: tui_manage_args: unknown action %s\n' "${_action}" >&2
            return 2
            ;;
    esac
}

# Dry-run plan for the §8.4 confirm dialog, one module per line:
#   tui_cli_manage_plan <remove|purge> <module>
# Forks `setup_ubuntu <action> --dry-run --no-deps <module>` — the CLI
# stays the single authority on what the action will touch (G4); the TUI
# only re-renders its DRY-RUN bullets.
tui_cli_manage_plan() {
    local _action="$1" _module="$2" _out
    if ! _out="$("${TUI_CLI:?TUI_CLI not set}" "${_action}" --dry-run --no-deps "${_module}" 2>/dev/null)"; then
        printf "ERROR: 'setup_ubuntu %s --dry-run --no-deps %s' failed\n" \
            "${_action}" "${_module}" >&2
        return 1
    fi
    if [[ "${_out}" != *"DRY-RUN: would ${_action}"* ]]; then
        printf "ERROR: 'setup_ubuntu %s --dry-run --no-deps %s' returned no plan\n" \
            "${_action}" "${_module}" >&2
        return 1
    fi
    awk '/^  - / { sub(/^  - /, ""); print }' <<<"${_out}"
}

# §8.4 confirm-dialog body: enumerate the CONCRETE actions —
#   tui_manage_confirm_text <remove|purge> <module> <plan>
#   - the exact CLI command the Proceed button forks (G4: what you read
#     is literally what runs),
#   - the dry-run-derived module plan (<plan> = tui_cli_manage_plan lines),
#   - the state.json change.
# Per-package/path enumeration (apt-get purge <pkgs>, rm -rf CONFIG_PATHS)
# needs the CLI to expose APT_PKGS/CONFIG_PATHS first (`show --json`,
# future) — until then the module-level plan + config-fate note is the
# §8.4 payload the CLI surface can back.
tui_manage_confirm_text() {
    local _action="$1" _module="$2" _plan="$3"
    local -a _argv=()
    mapfile -t _argv < <(tui_manage_args "${_action}" "${_module}")

    local _text; _text="$(i18n_t TUI_BACKEND_I18N confirm_about_to "${_action^^}" "${_module}")"$'\n'
    _text+="$(i18n_t TUI_BACKEND_I18N confirm_run "${_argv[*]}")"$'\n'
    local _n
    while IFS= read -r _n; do
        [[ -n "${_n}" ]] && _text+="$(i18n_t TUI_BACKEND_I18N confirm_action_module "${_action}" "${_n}")"$'\n'
    done <<<"${_plan}"
    _text+="$(i18n_t TUI_BACKEND_I18N confirm_remove_from_state "${_module}")"$'\n\n'
    case "${_action}" in
        purge)
            _text+="$(i18n_t TUI_BACKEND_I18N confirm_purge_note)" ;;
        remove)
            _text+="$(i18n_t TUI_BACKEND_I18N confirm_remove_note)" ;;
    esac
    printf '%s\n' "${_text}"
}

# One §8.1 category row as "tag<TAB>label<TAB>description".
_tui_category_entry() {
    local _json="$1" _cat="$2"
    local _installed _total
    read -r _installed _total <<<"$(tui_category_stats "${_json}" "${_cat}")"
    case "${_cat}" in
        base)
            printf 'base\t%s\t%s\n' \
                "$(i18n_t TUI_BACKEND_I18N cat_base_label)" \
                "$(i18n_t TUI_BACKEND_I18N cat_base_desc)" ;;
        recommended)
            printf 'recommended\t%s\t%s\n' \
                "$(i18n_t TUI_BACKEND_I18N cat_recommended_label "${_installed}" "${_total}")" \
                "$(i18n_t TUI_BACKEND_I18N cat_recommended_desc)" ;;
        optional)
            printf 'optional\t%s\t%s\n' \
                "$(i18n_t TUI_BACKEND_I18N cat_optional_label)" \
                "$(i18n_t TUI_BACKEND_I18N cat_optional_desc)" ;;
        experimental)
            printf 'experimental\t%s\t%s\n' \
                "$(i18n_t TUI_BACKEND_I18N cat_experimental_label)" \
                "$(i18n_t TUI_BACKEND_I18N cat_experimental_desc)" ;;
    esac
}

# #169 non-selectable divider row: sentinel tag + a box-drawing rule in the
# label column, empty description. The main loop's _tui_dispatch ignores the
# sentinel tag, so landing on it is a harmless no-op on both backends.
_tui_menu_separator() {
    printf '%s\t──────────────\t\n' "${TUI_MENU_SEPARATOR}"
}

# Full §8.1 main-menu rows ("tag<TAB>label<TAB>description" per line).
# Category rows are derived from the live payload, so empty categories
# disappear and future non-empty ones appear without a spec change (Q44).
tui_main_menu_entries() {
    local _json="$1" _cat

    # #169: three logical groups, divided by non-selectable separator rows
    # (sentinel tag TUI_MENU_SEPARATOR). A divider row renders identically on
    # dialog and whiptail (both accept arbitrary tag/item rows); the main loop
    # treats the sentinel as a no-op so it never dispatches an action.
    #   Group 1 — build the pick: quick-setup + category browse rows
    #   Group 2 — manage / info:  manage, secrets, sysinfo
    #   Group 3 — action:         run (the only batch execution point, Q43)
    printf 'quick-setup\t%s\t%s\n' \
        "$(i18n_t TUI_BACKEND_I18N menu_quick_setup_label)" \
        "$(i18n_t TUI_BACKEND_I18N menu_quick_setup_desc)"
    while IFS= read -r _cat; do
        _tui_category_entry "${_json}" "${_cat}"
    done < <(tui_categories "${_json}")
    _tui_menu_separator
    printf 'manage\t%s\t%s\n' \
        "$(i18n_t TUI_BACKEND_I18N menu_manage_label)" \
        "$(i18n_t TUI_BACKEND_I18N menu_manage_desc)"
    printf 'secrets\t%s\t%s\n' \
        "$(i18n_t TUI_BACKEND_I18N menu_secrets_label)" \
        "$(i18n_t TUI_BACKEND_I18N menu_secrets_desc)"
    printf 'sysinfo\t%s\t%s\n' \
        "$(i18n_t TUI_BACKEND_I18N menu_sysinfo_label)" \
        "$(i18n_t TUI_BACKEND_I18N menu_sysinfo_desc)"
    _tui_menu_separator
    # §8.1 < Run > — the ONLY batch execution point (Q43). Rendered as the
    # last menu row because a second action button next to OK exists only
    # on dialog (--extra-button), not whiptail; a row keeps both backends
    # behaviorally identical. < Exit > is the relabeled Cancel button.
    printf 'run\t%s\t%s\n' \
        "$(i18n_t TUI_BACKEND_I18N menu_run_label)" \
        "$(i18n_t TUI_BACKEND_I18N menu_run_desc)"
}

# §8.1 header line from a detect --json payload, e.g.
# "Ubuntu 24.04 / NVIDIA RTX 4090 / GNOME / x11". Null fields are skipped.
tui_system_summary() {
    jq -r '
        [ (((.os.id // "unknown") | (.[0:1] | ascii_upcase) + .[1:])
            + " " + (.os.version // "?")),
          (.gpu.model // .gpu.vendor),
          .desktop,
          .session_type ]
        | map(select(. != null and . != "")) | join(" / ")
    ' <<<"$1"
}

# ── Backend rendering wrappers (#171 dispatcher → _tui_<widget>_<backend>) ────
# The 4 contract widgets (menu / checklist / msgbox / yesno) keep a stable
# argv contract (frontend passes `tag item [status]`, reads back the TAG),
# but each backend renders natively. tui_render_* are thin dispatchers keyed
# on the backend FAMILY (basename of TUI_BACKEND):
#   - gum       → _tui_<widget>_gum   (modern; gum manages its own width)
#   - otherwise → _tui_<widget>_whiptail  (whiptail family — also covers a
#                 dialog-named binary, same --menu/--msgbox/--yesno shape)
# Live-widget behavior is covered by the AC-10 dual-backend smoke harness;
# argv-level + tag/index mapping by the unit bats.
_tui_backend_family() {
    case "${TUI_BACKEND##*/}" in
        gum) printf 'gum\n' ;;
        *)   printf 'whiptail\n' ;;
    esac
}

# ── whiptail family (the current, unchanged behavior) ────────────────────────
# whiptail (and a dialog-named binary) spell the Cancel-relabel flag
# differently; this is how §8.1 < Exit > and §8.2 < Back > captions reach the
# backend. Callers opt in via TUI_CANCEL_LABEL (call-scoped).
_tui_cancel_button_args() {
    case "${TUI_BACKEND##*/}" in
        whiptail) printf -- '--cancel-button\n%s\n' "$1" ;;
        *)        printf -- '--cancel-label\n%s\n'  "$1" ;;
    esac
}

_tui_menu_whiptail() {
    local _title="$1" _text="$2"
    shift 2
    local -a _cancel=()
    if [[ -n "${TUI_CANCEL_LABEL:-}" ]]; then
        mapfile -t _cancel < <(_tui_cancel_button_args "${TUI_CANCEL_LABEL}")
    fi
    "${TUI_BACKEND:?TUI_BACKEND not set}" --title "${_title}" "${_cancel[@]}" \
        --menu "${_text}" "${TUI_HEIGHT}" "${TUI_WIDTH}" "${TUI_MENU_HEIGHT}" \
        "$@" 3>&1 1>&2 2>&3
}

_tui_checklist_whiptail() {
    local _title="$1" _text="$2"
    shift 2
    local -a _cancel=()
    if [[ -n "${TUI_CANCEL_LABEL:-}" ]]; then
        mapfile -t _cancel < <(_tui_cancel_button_args "${TUI_CANCEL_LABEL}")
    fi
    # #183: the clip lives HERE (whiptail-only). The shared entries producers
    # emit full descriptions; whiptail's 72-col modal box can't wrap, so each
    # item is clipped to the per-page budget before it reaches the binary.
    local -a _rows=()
    mapfile -t _rows < <(_tui_clip_checklist_args "$@")
    "${TUI_BACKEND:?TUI_BACKEND not set}" --title "${_title}" "${_cancel[@]}" \
        --separate-output \
        --checklist "${_text}" "${TUI_HEIGHT}" "${TUI_WIDTH}" "${TUI_MENU_HEIGHT}" \
        "${_rows[@]}" 3>&1 1>&2 2>&3
}

_tui_msgbox_whiptail() {
    "${TUI_BACKEND:?TUI_BACKEND not set}" --title "$1" \
        --msgbox "$2" "${TUI_HEIGHT}" "${TUI_WIDTH}"
}

# Yes/No relabel flags (the §8.4 < Proceed > / < Cancel > captions);
# same split as _tui_cancel_button_args. Opt in via TUI_YES_LABEL/TUI_NO_LABEL.
_tui_yesno_button_args() {
    case "${TUI_BACKEND##*/}" in
        whiptail) printf -- '--yes-button\n%s\n--no-button\n%s\n' "$1" "$2" ;;
        *)        printf -- '--yes-label\n%s\n--no-label\n%s\n'   "$1" "$2" ;;
    esac
}

_tui_yesno_whiptail() {
    local -a _btn=()
    if [[ -n "${TUI_YES_LABEL:-}" || -n "${TUI_NO_LABEL:-}" ]]; then
        mapfile -t _btn < <(_tui_yesno_button_args \
            "${TUI_YES_LABEL:-Yes}" "${TUI_NO_LABEL:-No}")
    fi
    "${TUI_BACKEND:?TUI_BACKEND not set}" --title "$1" "${_btn[@]}" \
        --yesno "$2" "${TUI_HEIGHT}" "${TUI_WIDTH}"
}

# ── gum family (#171; default styling, gum owns its own width) ────────────────
# gum has NO hidden value: `gum choose` echoes the chosen ITEM label, so the
# menu/checklist adapters map the echoed label(s) back to the TAG by INDEX
# over the (tag,item) pairs. Index-mapping is duplicate-label-safe: a label
# that appears twice resolves to its FIRST occurrence's tag. Items pass to gum
# unclipped — gum manages wrapping, so _tui_clip is NOT applied here (#168).

# _tui_menu_gum <title> <text> <tag1> <item1> [...] → chosen tag on stdout.
# rc != 0 (incl. gum's 130 on Esc/Ctrl-C) propagates as cancel/Back.
_tui_menu_gum() {
    local _title="$1" _text="$2"
    shift 2
    local -a _tags=() _items=()
    while (( $# >= 2 )); do
        _tags+=("$1"); _items+=("$2"); shift 2
    done
    local _picked
    _picked="$("${TUI_BACKEND:?TUI_BACKEND not set}" choose \
        --header "${_title}: ${_text}" -- "${_items[@]}")" || return $?
    # Map the chosen item label back to its tag by first index match.
    local _i
    for _i in "${!_items[@]}"; do
        if [[ "${_items[_i]}" == "${_picked}" ]]; then
            printf '%s\n' "${_tags[_i]}"
            return 0
        fi
    done
    return 1  # gum echoed something we never offered — treat as cancel
}

# _tui_checklist_gum <title> <text> <tag item status ...>
#   → checked tags, one per line (matches the whiptail --separate-output
#     contract). Preselected ("on") rows are passed via gum --selected.
_tui_checklist_gum() {
    local _title="$1" _text="$2"
    shift 2
    local -a _tags=() _items=() _preselected=()
    while (( $# >= 3 )); do
        _tags+=("$1"); _items+=("$2")
        [[ "$3" == "on" ]] && _preselected+=("$2")
        shift 3
    done
    local -a _selflag=()
    if (( ${#_preselected[@]} > 0 )); then
        local _csv
        printf -v _csv '%s,' "${_preselected[@]}"
        _selflag=(--selected "${_csv%,}")
    fi
    local _picked
    _picked="$("${TUI_BACKEND:?TUI_BACKEND not set}" choose --no-limit \
        "${_selflag[@]}" --header "${_title}: ${_text}" -- "${_items[@]}")" \
        || return $?
    # Map each checked item label back to its tag (first index match), one
    # per line. Empty pick → empty stdout + success (nothing checked).
    local _line _i
    while IFS= read -r _line; do
        [[ -z "${_line}" ]] && continue
        for _i in "${!_items[@]}"; do
            if [[ "${_items[_i]}" == "${_line}" ]]; then
                printf '%s\n' "${_tags[_i]}"
                break
            fi
        done
    done <<<"${_picked}"
}

# _tui_msgbox_gum <title> <text> → render + single-key continue.
_tui_msgbox_gum() {
    "${TUI_BACKEND:?TUI_BACKEND not set}" style --border rounded --padding "1 2" \
        "$1" "" "$2"
    i18n_t TUI_BACKEND_I18N press_enter >&2
    read -r REPLY || true
}

# _tui_yesno_gum <title> <text> → gum confirm (native rc 0 yes / nonzero no).
# Esc/Ctrl-C 130 and confirm-No 1 both propagate as nonzero (not swallowed).
_tui_yesno_gum() {
    local -a _flags=()
    [[ -n "${TUI_YES_LABEL:-}" ]] && _flags+=(--affirmative "${TUI_YES_LABEL}")
    [[ -n "${TUI_NO_LABEL:-}" ]] && _flags+=(--negative "${TUI_NO_LABEL}")
    "${TUI_BACKEND:?TUI_BACKEND not set}" confirm "${_flags[@]}" "$1: $2"
}

# ── Public dispatchers (stable contract) ─────────────────────────────────────
tui_render_menu()      { "_tui_menu_$(_tui_backend_family)" "$@"; }
tui_render_checklist() { "_tui_checklist_$(_tui_backend_family)" "$@"; }
tui_render_msgbox()    { "_tui_msgbox_$(_tui_backend_family)" "$@"; }
tui_render_yesno()     { "_tui_yesno_$(_tui_backend_family)" "$@"; }
