#!/usr/bin/env bash
# lib/tui_backend.sh — TUI backend detection + menu data helpers (PRD §8, G4)
#
# The TUI is a *frontend* of the CLI (PRD §8 / G4): it renders screens and
# collects selections only. Everything here either
#   - probes / wraps the whiptail dialog backend (the Fallback tier; gum is
#     dropped per ADR-0024 — §8.5, no auto-install), or
#   - parses ADR-0019 `list --json` / `detect --json` payloads produced by
#     forked `setup_ubuntu` subprocesses.
# This lib NEVER sources engine libs (registry / resolver / runner / state)
# and NEVER writes state — enforced by the G4 grep gate in
# test/unit/tui_backend_spec.bats.
#
# Public API:
#   tui_backend_detect            Print "whiptail"; rc 1 when it is missing
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
#   tui_render_input <title> <prompt> [default]
#                                 §5 single-line text input (whiptail
#                                 --inputbox). Success → value + rc 0;
#                                 cancel (nonzero rc) propagates; EMPTY result =
#                                 cancel → rc 1. NO no-echo variant (secret
#                                 values never pass through this widget — AC-20)
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
    [en.menu_help_label]="Help"
    [zh-TW.menu_help_label]="說明"
    [en.menu_help_desc]="Keyboard reference for this backend"
    [zh-TW.menu_help_desc]="此後端的鍵盤操作說明"

    # #203 Help screen body (design §3). The whiptail body centers on Tab (the
    # non-obvious "Tab reaches the Back/Exit buttons"), plus space/enter/esc.
    # Multi-line (\n expanded by i18n consumers); NO emoji.
    [en.help_whiptail]="whiptail backend keys:\n\n  Tab             move between the list and the < Back > / < Exit >\n                  buttons (the key people miss)\n  arrows          move within the list\n  space           toggle a checklist row\n  enter           activate the focused item / button\n  esc             back one level (Exit on the main menu)\n\nThere is no key footer on whiptail, so use Tab to reach the buttons.\nOn the MAIN menu, Exit / esc DROPS any unsent selections.\nCtrl+C quits cleanly from anywhere."
    [zh-TW.help_whiptail]="whiptail 後端按鍵:\n\n  Tab             在清單與 < 返回 > / < 離開 > 按鈕之間移動\n                  (最容易被忽略的按鍵)\n  方向鍵          在清單內移動\n  space           切換勾選列\n  enter           啟用所選項目 / 按鈕\n  esc             返回上一層 (主選單為離開)\n\nwhiptail 沒有按鍵列,請用 Tab 移到按鈕。\n在主選單上,離開 / esc 會捨棄尚未送出的選擇。\nCtrl+C 可從任何畫面乾淨地退出。"
    # whiptail multi-select inline hint (design §3; gated by ui.tui_hints).
    # Prepended to the --checklist body text only — the menu widget is untouched.
    [en.hint_checklist_whiptail]="(space toggle · tab to buttons · enter confirm)"
    [zh-TW.hint_checklist_whiptail]="(space 勾選 · tab 到按鈕 · enter 確認)"

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

    # Module detail view (#211 part 2 / #215). Read-only label:value lines built
    # from a forked `setup_ubuntu show <module> --json` payload. (none) is the
    # placeholder for an absent description or an empty array.
    [en.detail_name]="Name:"
    [zh-TW.detail_name]="名稱:"
    [en.detail_category]="Category:"
    [zh-TW.detail_category]="類別:"
    [en.detail_description]="Description:"
    [zh-TW.detail_description]="描述:"
    [en.detail_tags]="Tags:"
    [zh-TW.detail_tags]="標籤:"
    [en.detail_depends_on]="Depends on:"
    [zh-TW.detail_depends_on]="相依於:"
    [en.detail_conflicts]="Conflicts:"
    [zh-TW.detail_conflicts]="衝突:"
    [en.detail_supported_ubuntu]="Supported Ubuntu:"
    [zh-TW.detail_supported_ubuntu]="支援的 Ubuntu:"
    [en.detail_supported_platforms]="Supported platforms:"
    [zh-TW.detail_supported_platforms]="支援的平台:"
    [en.detail_none]="(none)"
    [zh-TW.detail_none]="(無)"
    # #215: unregistered installed entry — present in state.json but absent from
    # the current catalog (`show --json` fails). version_provided / installed_at
    # are whatever state.json holds; the note makes the gap explicit.
    [en.detail_version]="Installed version:"
    [zh-TW.detail_version]="已安裝版本:"
    [en.detail_installed_at]="Installed at:"
    [zh-TW.detail_installed_at]="安裝時間:"
    [en.detail_unregistered_note]="This module is not in the current catalog (showing state.json data only)."
    [zh-TW.detail_unregistered_note]="此模組不在目前的目錄中(僅顯示 state.json 資料)。"
    # Compact marker appended to an unregistered module's Manage-list row.
    [en.detail_unregistered_marker]="(unregistered)"
    [zh-TW.detail_unregistered_marker]="(未登錄)"
    # Review / pre-install dependency provenance (#214, #213). Per-item origin
    # annotation rendered by tui_review_text / tui_summary_text: a user pick is
    # "(your selection)"; an engine-pulled dep is "(required by <module>)".
    [en.prov_self]="{0} (your selection)"
    [zh-TW.prov_self]="{0} (你的選擇)"
    [en.prov_required_by]="{0} (required by {1})"
    [zh-TW.prov_required_by]="{0} (由 {1} 連帶安裝)"

    # #7 data broker single error path (tui_broker_init fork failure). {0} is
    # the failed subcommand (e.g. "list --json"). One msgbox, then clean abort.
    [en.broker_fork_failed_title]="Data error"
    [zh-TW.broker_fork_failed_title]="資料錯誤"
    [en.broker_fork_failed]="Failed to read catalog data ('setup_ubuntu {0}'). Aborting."
    [zh-TW.broker_fork_failed]="無法讀取目錄資料('setup_ubuntu {0}')。即將中止。"
)
# kcov-exclude-end
# TUI_BACKEND_I18N is consumed by i18n_t via a nameref on the table NAME passed
# as a bareword argument — static analysis cannot follow that indirection, so
# make the read explicit here to keep shellcheck honest (no disable directive).
: "${TUI_BACKEND_I18N[@]+x}"

# Canonical CATEGORY order (PRD §6.3 / module contract §9.1).
TUI_CATEGORY_ORDER='["base","recommended","optional","experimental"]'

# #203 inline-hint switch (`ui.tui_hints`, design §3). 1 = show the per-screen
# inline hints (whiptail multi-select hint line); 0 = render clean and rely on
# the Help menu entry. The entrypoint resolves the
# config value ONCE at startup (fork: setup_ubuntu config get ui.tui_hints) and
# exports TUI_HINTS; this default keeps unit tests / standalone sourcing ON,
# matching how TUI_BACKEND is threaded as a single global.
: "${TUI_HINTS:=1}"

# Backend dialog geometry. dialog autosizes with 0s but whiptail does not,
# so fixed sizes keep both backends rendering identically (§8.5).
: "${TUI_HEIGHT:=20}"
: "${TUI_WIDTH:=72}"
: "${TUI_MENU_HEIGHT:=10}"

# Checklist chrome (#168): dialog/whiptail render a --checklist row as
# "[status] <tag>   <item>". The fixed overhead is the checkbox + its gutter
# plus the gutter between the tag column and the item — empirically 8 cols on
# both backends for a 72-col box. The item budget is therefore
#   TUI_WIDTH - (longest visible tag/name width) - TUI_CHECKLIST_CHROME
# floored to TUI_CHECKLIST_MIN so a narrow box still shows a usable stub.
: "${TUI_CHECKLIST_CHROME:=8}"
: "${TUI_CHECKLIST_MIN:=20}"

# ── Pure display helpers ─────────────────────────────────────────────────────

# _tui_clip <string> <max> → <string> clipped to <max> DISPLAY COLUMNS with a
# trailing single-column ellipsis "…" when it would exceed <max>, unchanged
# otherwise. Display-width aware (via _tui_disp_width): a zh-TW/ja glyph is 2
# columns, so a char-count clip truncated at the wrong visual boundary and
# over-ran whiptail's box. Never splits a wide glyph. Pure (no globals, no I/O).
_tui_clip() {
    local _s="$1" _max="$2"
    # UTF-8 locale so ${_s:i:1} slices on character boundaries (multibyte
    # zh-TW); C.UTF-8 is always present on Debian/Ubuntu and in the kcov image.
    local LC_ALL=C.UTF-8
    if (( $(_tui_disp_width "${_s}") <= _max )); then
        printf '%s\n' "${_s}"
        return
    fi
    # Reserve 1 column for the ellipsis; accumulate whole glyphs up to the budget.
    local _budget=$(( _max - 1 )) _out="" _w=0 _i _ch _cw
    for (( _i = 0; _i < ${#_s}; _i++ )); do
        _ch="${_s:_i:1}"
        _cw=$(_tui_disp_width "${_ch}")
        (( _w + _cw > _budget )) && break
        _out+="${_ch}"
        _w=$(( _w + _cw ))
    done
    printf '%s…\n' "${_out}"
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
    local LC_ALL=C.UTF-8  # display-width math (see _tui_clip / _tui_disp_width)
    local _name _longest=0 _w
    for _name in "$@"; do
        _w=$(_tui_disp_width "${_name}")
        (( _w > _longest )) && _longest=${_w}
    done
    local _budget=$(( TUI_WIDTH - _longest - TUI_CHECKLIST_CHROME ))
    (( _budget < TUI_CHECKLIST_MIN )) && _budget=${TUI_CHECKLIST_MIN}
    printf '%s\n' "${_budget}"
}

# _tui_clip_checklist_args <tag item status ...> → the same triples on stdout
# (one field per line) with each ITEM field (the rendered "[tag] description")
# clipped to the whiptail box budget; tag and status pass through untouched.
# This is the #168 clip — it lives in the WHIPTAIL adapter only (#183): the
# shared entries producers now emit FULL descriptions so the fzf tier, which
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

# ── Backend selection (§8.5; whiptail is the dialog backend) ─────────────────
# gum is no longer a TUI backend (ADR-0024 drops it; the Rich tier is fzf, the
# Fallback tier is whiptail). These helpers cover only the whiptail dialog
# binary used by the Fallback tier and by the fzf tier's delegated screens.

# Print the dialog backend on stdout. whiptail is the only valid value: a
# pre-set TUI_BACKEND=whiptail is the explicit override (the --backend flag /
# CI lever); anything else is rejected. rc 1 when whiptail is missing.
tui_backend_detect() {
    case "${TUI_BACKEND:-}" in
        whiptail)
            printf '%s\n' "${TUI_BACKEND}"
            return 0
            ;;
    esac
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
FATAL: TUI requires 'whiptail' (default on Ubuntu).
       It is missing — your install is unusually stripped.
       Fix:  sudo apt install whiptail
       Or:   use CLI mode: setup_ubuntu install <module>
EOF
        return 1
    fi
    export TUI_BACKEND
}

# `_tui_stdin_is_tty` is a tiny mockable seam (same pattern as _tui_has_cmd),
# used by the fzf-tier install-prompt resolution in setup_ubuntu_tui.sh.
_tui_stdin_is_tty() { [[ -t 0 ]]; }

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

# ── Session data broker (#7, ADR-0024 #5 shared data layer) ──────────────────
# The session-wide `list --json` + `detect --json` payloads change for the
# whole TUI lifetime only across an install/manage action (which `exit`s the
# process), so they are fetched ONCE at launch and served from cache for every
# screen / preview thereafter. The broker is the single owner of that cache and
# of the single fork-failure error path.
#
# Two adapters justify the seam (ADR-0024: real CLI fork in prod, injected JSON
# in tests) — and BOTH keep G4 intact (the broker sources no engine lib):
#   1. PROD  — tui_broker_init forks `list --json` / `detect --json` ONCE and
#              caches each to a session temp file (paths exported so the fzf
#              `--preview` re-invocation reads the cache instead of re-forking).
#   2. TESTS — when TUI_BROKER_LIST_CACHE / TUI_BROKER_DETECT_CACHE already
#              point at readable files, tui_broker_init treats them as injected
#              payloads and forks NOTHING. This is the unit-test seam: a spec
#              writes fixture JSON to two temp files, exports the two vars, and
#              the accessors serve them with no CLI present.
#
# Cache file paths (exported so the preview subprocess inherits them):
: "${TUI_BROKER_LIST_CACHE:=}"
: "${TUI_BROKER_DETECT_CACHE:=}"

# Single error path: emit ONE error surface + return 1 (clean abort). In a live
# TUI a dialog backend is wired (TUI_BACKEND set), so render one msgbox; without
# it (standalone sourcing / unit bats / the fzf preview subprocess) degrade to a
# single stderr line. Either way it is ONE error surface, not scattered per-call
# diagnostics. Gate on TUI_BACKEND (not just `declare -F tui_render_msgbox`,
# which is always defined by this lib) so the widget is only driven when a
# backend binary actually exists.
#   _tui_broker_fail <what>
_tui_broker_fail() {
    local _what="$1"
    local _msg; _msg="$(i18n_t TUI_BACKEND_I18N broker_fork_failed "${_what}")"
    if [[ -n "${TUI_BACKEND:-}" ]] && declare -F tui_render_msgbox >/dev/null 2>&1; then
        tui_render_msgbox "$(i18n_t TUI_BACKEND_I18N broker_fork_failed_title)" "${_msg}"
    else
        printf '%s\n' "${_msg}" >&2
    fi
    return 1
}

# Fetch list + detect ONCE and cache to session temp files. Idempotent: a second
# call with both caches already populated is a no-op (re-running a screen never
# re-forks). On ANY fork failure, route through the single error path and abort
# (rc 1) without leaving a half-populated cache. The injected-JSON seam: when a
# cache var already points at a readable file, that payload is adopted as-is and
# NOT re-forked (tests + the fzf preview subprocess both rely on this).
tui_broker_init() {
    # detect cache
    if [[ -n "${TUI_BROKER_DETECT_CACHE}" && -r "${TUI_BROKER_DETECT_CACHE}" ]]; then
        : # injected (tests) or already initialized — keep it
    else
        local _detect
        _detect="$(tui_cli_detect_json)" || { _tui_broker_fail "detect --json"; return 1; }
        TUI_BROKER_DETECT_CACHE="$(mktemp)"
        printf '%s' "${_detect}" >"${TUI_BROKER_DETECT_CACHE}"
    fi
    # list cache
    if [[ -n "${TUI_BROKER_LIST_CACHE}" && -r "${TUI_BROKER_LIST_CACHE}" ]]; then
        : # injected (tests) or already initialized — keep it
    else
        local _list
        _list="$(tui_cli_list_json)" || { _tui_broker_fail "list --json"; return 1; }
        TUI_BROKER_LIST_CACHE="$(mktemp)"
        printf '%s' "${_list}" >"${TUI_BROKER_LIST_CACHE}"
    fi
    export TUI_BROKER_LIST_CACHE TUI_BROKER_DETECT_CACHE
    return 0
}

# Cached accessors — return the session payload on stdout, NO re-fork. They
# require tui_broker_init to have run (or the cache vars to be injected); a
# missing/unreadable cache is the single error path again (a programming error,
# not a per-call CLI failure).
tui_broker_list_json() {
    if [[ -z "${TUI_BROKER_LIST_CACHE}" || ! -r "${TUI_BROKER_LIST_CACHE}" ]]; then
        _tui_broker_fail "list --json"
        return 1
    fi
    cat -- "${TUI_BROKER_LIST_CACHE}"
}

tui_broker_detect_json() {
    if [[ -z "${TUI_BROKER_DETECT_CACHE}" || ! -r "${TUI_BROKER_DETECT_CACHE}" ]]; then
        _tui_broker_fail "detect --json"
        return 1
    fi
    cat -- "${TUI_BROKER_DETECT_CACHE}"
}

# Drop the session cache files (called on TUI exit; the selstate temp is wiped
# alongside). Safe to call when nothing was cached.
tui_broker_cleanup() {
    [[ -n "${TUI_BROKER_LIST_CACHE}" ]] && rm -f -- "${TUI_BROKER_LIST_CACHE}"
    [[ -n "${TUI_BROKER_DETECT_CACHE}" ]] && rm -f -- "${TUI_BROKER_DETECT_CACHE}"
    return 0
}

# Module detail payload for the #211 detail view, one forked subprocess:
#   tui_cli_show_json <module>
# Forks `setup_ubuntu show <module> --json` (G4 — the engine `show --json`
# already exists, lib/dispatcher.sh). The CLI returns rc 2 + "unknown module"
# on stderr for a name absent from the registry, so an UNREGISTERED installed
# module (state.json survives, the module file is gone) makes this fail — the
# caller falls back to a state-only detail (#215). Success → the JSON object on
# stdout, rc 0; failure → rc 1 (the engine's diagnostic stays on stderr).
tui_cli_show_json() { _tui_cli_json show "$1" --json; }

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

# ── Dependency provenance (#214) ─────────────────────────────────────────────
# Per-item origin for the Review / pre-install summary, in resolver plan order:
#   tui_plan_provenance <list_json> <plan-lines> <selected...>
# Each output line is "<name><TAB>self" (a user pick) or "<name><TAB>req:<m>"
# (an engine-pulled dep, <m> = the FIRST requested module whose transitive
# depends_on closure contains it). The depends_on graph is parsed from
# `list --json` (the same source the checklist basic-first sort uses, #212) —
# the TUI never re-resolves the closure, it only attributes the resolver's plan.
tui_plan_provenance() {
    local _json="$1" _plan="$2"
    shift 2
    jq -r --arg sel " $* " --arg plan "${_plan}" '
        (reduce .items[] as $m ({}; .[$m.name] = ($m.depends_on // []))) as $deps
        | def transitive($n):
            { seen: [], frontier: ($deps[$n] // []) }
            | until((.frontier | length) == 0;
                .seen as $s
                | (.frontier | map(select(. as $x | ($s | index($x)) | not)))
                  as $new
                | { seen: ($s + $new | unique),
                    frontier: ([$new[] | ($deps[.] // [])] | add // []) })
            | .seen;
        ($sel | split(" ") | map(select(. != ""))) as $picks
        | ($plan | split("\n") | map(select(. != "")))[]
        | . as $node
        | if ($picks | index($node)) then "\($node)\tself"
          else
            ([$picks[] | select(transitive(.) | index($node))] | first) as $by
            | "\($node)\treq:\($by // "?")"
          end
    ' <<<"${_json}"
}

# Render a provenance map (tui_plan_provenance output) into human lines using
# the i18n templates: "<name> (your selection)" / "<name> (required by X)".
#   _tui_render_provenance <provenance-tsv>
_tui_render_provenance() {
    local _name _role
    while IFS=$'\t' read -r _name _role; do
        [[ -z "${_name}" ]] && continue
        if [[ "${_role}" == "self" ]]; then
            i18n_t TUI_BACKEND_I18N prov_self "${_name}"
        else
            i18n_t TUI_BACKEND_I18N prov_required_by "${_name}" "${_role#req:}"
        fi
        printf '\n'
    done <<<"$1"
}

# Review-screen body (#214): every plan node with its per-item provenance,
# replacing the old flat "will pull N deps" count. Resolver plan order.
#   tui_review_text <list_json> <plan-lines> <selected...>
tui_review_text() {
    local _json="$1" _plan="$2"
    shift 2
    _tui_render_provenance "$(tui_plan_provenance "${_json}" "${_plan}" "$@")"
}

# Pre-install summary body (#213): identical provenance listing, reused before
# the install fork so the user sees BOTH picks and pulled deps. Kept distinct
# from tui_review_text so callers/intents read clearly (same content today).
#   tui_summary_text <list_json> <plan-lines> <selected...>
tui_summary_text() {
    tui_review_text "$@"
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

# ── Sub-category structure (TAGS[0] grouping — shared between tiers) ──────────
# The distinct TAGS[0] buckets of a category, alphabetical; a module with no
# tags falls into the "other" bucket. A category with >1 bucket gets a
# sub-category drill-down (whiptail tier) / branch screen (fzf tier); a single
# bucket goes straight to the module leaf. This is the ONE bucketing producer
# both tiers consume (ADR-0024 D10) — tui_fzf_subtags is a thin wrapper.
#   tui_subtags <list_json> <category>
tui_subtags() {
    jq -r --arg c "$2" '
        [.items[] | select(.category == $c) | (.tags[0] // "other")]
        | unique | sort | .[]
    ' <<<"$1"
}

# How many distinct TAGS[0] buckets a category has (drives the "drill-down vs
# straight-to-leaf" decision: >1 → sub-category screen, else module leaf).
#   tui_subtag_count <list_json> <category>
tui_subtag_count() {
    tui_subtags "$1" "$2" | grep -c .
}

# "<selected> <total>" for a whole category — PRD D2: the main/category-menu
# count is SELECTED/total (from the in-memory accumulator), NOT installed/total.
# <selected> is a space-separated module-name list (whitespace padding is fine).
# Mirrors tui_fzf_category_sel_stats so both tiers agree.
#   tui_category_sel_stats <list_json> <category> <selected>
tui_category_sel_stats() {
    local _sel=" ${3:-} "
    jq -r --arg c "$2" --arg sel "${_sel}" '
        [.items[] | select(.category == $c)]
        | "\([.[] | .name as $n | select($sel | contains(" " + $n + " "))] | length) \(length)"
    ' <<<"$1"
}

# "<selected> <total>" for one sub-category bucket (the sub-category menu row
# count, the whiptail analogue of _tui_fzf_subtag_stats).
#   tui_subcategory_sel_stats <list_json> <category> <subtag> <selected>
tui_subcategory_sel_stats() {
    local _sel=" ${4:-} "
    jq -r --arg c "$2" --arg t "$3" --arg sel "${_sel}" '
        [.items[] | select(.category == $c) | select((.tags[0] // "other") == $t)]
        | "\([.[] | .name as $n | select($sel | contains(" " + $n + " "))] | length) \(length)"
    ' <<<"$1"
}

# Module names in one (category, subtag) bucket, alphabetical — the page-replace
# scope for the drill-down leaf.
#   tui_modules_in_subcategory <list_json> <category> <subtag>
tui_modules_in_subcategory() {
    jq -r --arg c "$2" --arg t "$3" '
        [.items[] | select(.category == $c) | select((.tags[0] // "other") == $t) | .name]
        | sort | .[]
    ' <<<"$1"
}

# Pure recommended pre-selection set (PRD D4): the is_recommended module names
# that survive the §15.3 platform filter, one per line, alphabetical. Reuses
# the SAME filter pipeline as Quick Setup (tui_qs_recommended_entries: platform
# ∋ form factor → enabled tri-state → recommended). BOTH tiers wrap this — the
# fzf tier writes the set into the selstate file (tui_fzf_recommended_preselect),
# the whiptail tier seeds the in-memory accumulator. Only rows the engine marks
# recommended (status "on") are emitted; an "off" row is never auto-selected.
#   tui_recommended_preselect_modules <list_json> <form_factor>
tui_recommended_preselect_modules() {
    local _name _label _status
    while IFS=$'\t' read -r _name _label _status; do
        [[ "${_status}" == "on" ]] && printf '%s\n' "${_name}"
    done < <(tui_qs_recommended_entries "$1" "$2")
    return 0  # a trailing "off" row leaves the loop rc 1 — normalize to 0
}

# ── Checkbox accumulator data (#70, Q43 / §8.2) ──────────────────────────────

# Checklist rows for one category as "name<TAB>label<TAB>on|off" lines.
#   tui_checklist_entries <list_json> <category> <selected>
# <selected> is a space-separated module-name list (the in-memory
# accumulator) — those rows come back "on" so reopening a page shows the
# current selection. Rows are grouped by TAGS[0] (§8.2: each module shows up
# only under its first tag). Groups AND the items inside them are ordered
# BASIC-FIRST (issue #212, decision on #212): a module that OTHERS depend on
# ranks earlier. "Basic-ness" is the transitive REVERSE-dependency count
# derived from the whole payload's depends_on graph — a base module like
# curl, which many modules depend_on, sorts before its dependents. A group inherits the
# max rank of its members, so the sub-category holding the most-depended-on
# module renders first. Alphabetical (TAGS[0] then name) is the stable
# fallback for ties — no new metadata field is introduced. Dep chains stay
# collapsed: a "(will pull N deps)" hint per §8.2 / arch Q-A3, never the
# expanded chain (the Review screen owns the expandable detail). The label is
# emitted FULL (#183): clipping to the whiptail box budget happens inside the
# whiptail adapter (_tui_checklist_whiptail); the fzf tier renders full text.
# A non-empty 4th arg <subtag> scopes the rows to a single TAGS[0] bucket (the
# sub-category drill-down leaf, ADR-0024 D10) — "" yields the whole category.
tui_checklist_entries() {
    local _json="$1" _cat="$2" _selected=" ${3:-} " _subtag="${4:-}"
    jq -r --arg c "$2" --arg sel "${_selected}" --arg sub "${_subtag}" '
        # Direct forward deps per module name (over the WHOLE payload — a base
        # module is typically depended on from OTHER categories).
        (reduce .items[] as $m ({}; .[$m.name] = ($m.depends_on // []))) as $deps
        # transitive($n): the full set of modules $n (transitively) depends on.
        # Iterates the closure to a fixed point; the catalog graph is a DAG, so
        # the `until` terminates once no new ancestor is added.
        | def transitive($n):
            { seen: [], frontier: ($deps[$n] // []) }
            | until((.frontier | length) == 0;
                .seen as $seen
                | (.frontier | map(select(. as $x | ($seen | index($x)) | not)))
                  as $new
                | { seen: ($seen + $new | unique),
                    frontier: ([$new[] | ($deps[.] // [])] | add // []) })
            | .seen;
        # rank($n) = transitive REVERSE-dependency count: how many modules have
        # $n anywhere in their transitive dep closure. Higher = more basic.
        ([.items[].name] | map({ (.): 0 }) | add) as $zero
        | (reduce (.items[].name) as $m ($zero;
            reduce (transitive($m)[]) as $anc (.; .[$anc] += 1))) as $rank
        # Render only the requested category (optionally narrowed to one TAGS[0]
        # bucket for the drill-down leaf), but rank against the full graph.
        | [.items[]
           | select(.category == $c)
           | select($sub == "" or (.tags[0] // "other") == $sub)]
        # Group rank = the max member rank, so the sub-category that owns the
        # most-depended-on module sorts first. Sort groups basic-first then
        # alphabetically (negate the rank so jq ascending sort = basic-first).
        | group_by(.tags[0])
        | map({ tag: .[0].tags[0],
                grank: ([.[] | $rank[.name]] | max),
                items: . })
        | sort_by([(- .grank), .tag])
        | map(.items | sort_by([(- $rank[.name]), .name]))
        | add
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

# `< OK >` semantics for one SUB-CATEGORY drill-down page (ADR-0024 D10):
#   tui_selection_replace_subpage <list_json> <category> <subtag> [<name>...]
# Drops only the modules in that (category, subtag) bucket, then stores the
# page's checked names — so unchecking sticks within the bucket WITHOUT
# disturbing the OTHER sub-categories' picks (a category-wide replace would
# wipe them when the user drills one bucket at a time).
tui_selection_replace_subpage() {
    local _json="$1" _cat="$2" _subtag="$3"
    shift 3
    local _name
    while IFS= read -r _name; do
        unset "TUI_SELECTION[${_name}]"
    done < <(tui_modules_in_subcategory "${_json}" "${_cat}" "${_subtag}")
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
# Descriptions are emitted FULL (#183): the whiptail adapter clips, the fzf
# tier does not.
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
# #215: a name present in state.json but ABSENT from the catalog (list --json)
# is UNREGISTERED — its module file is gone (or it was a stale test install),
# so it has no metadata to act on. Such rows used to render with a bare "other"
# tag, indistinguishable from a registered module that merely lacks a TAGS[0].
# They now carry an explicit " (unregistered)" marker so the user can tell the
# two apart; the registered rows are unchanged. (The bare "unknown" VERSION is
# the legitimate state.json default — lib/state.sh writes it when a module
# exports no VERSION_PROVIDED — so it is left as-is, not relabelled.)
tui_installed_entries() {
    local _state="$1" _list="$2" _mode="${3:-flat}"
    local _marker; _marker="$(i18n_t TUI_BACKEND_I18N detail_unregistered_marker)"
    jq -r --argjson list "${_list}" --arg mode "${_mode}" --arg mark "${_marker}" '
        ([$list.items[]? | {key: .name, value: (.tags[0] // "other")}]
         | from_entries) as $tagof
        | (.installed // {}) | to_entries
        | map(.key as $k
              | {name: $k,
               registered: ($tagof | has($k)),
               version: (((.value.synced.version_provided // "?")
                          + "              ")[0:14]),
               at: ((.value.synced.installed_at // "?")
                    | sub("T"; " ") | .[0:16]),
               tag: ($tagof[$k] // "other")})
        | (if $mode == "grouped" then sort_by(.tag, .name)
           else sort_by(.name) end)
        | .[]
        | (if .registered then "" else " " + $mark end) as $suffix
        | if $mode == "grouped"
          then "\(.name)\t[\(.tag)] \(.version)\(.at)\($suffix)"
          else "\(.name)\t\(.version)\(.at)\($suffix)"
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

# ── Module detail view (#211 part 2 / #215) ──────────────────────────────────

# A single show-payload field as a readable string for the detail msgbox:
# arrays are comma-joined; an empty array or a JSON null becomes the localized
# "(none)" placeholder. <show_json> is a `show --json` object; <jq-path> selects
# the field (e.g. .tags, .description).
#   _tui_detail_field <show_json> <jq-path>
_tui_detail_field() {
    local _none; _none="$(i18n_t TUI_BACKEND_I18N detail_none)"
    jq -r --arg none "${_none}" "
        ($2) as \$v
        | if (\$v | type) == \"array\"
          then (if (\$v | length) == 0 then \$none else (\$v | join(\", \")) end)
          else (\$v // \$none)
          end" <<<"$1"
}

# Read-only detail text for a REGISTERED module, built from a forked
# `setup_ubuntu show <module> --json` payload (#211 fields only):
#   tui_detail_text <show_json>
# Emits localized "Label: value" lines (arrays comma-joined). Pure rendering —
# it forks nothing and never prints an action/command (it is a read-only view).
tui_detail_text() {
    local _json="$1" _text=""
    _text+="$(i18n_t TUI_BACKEND_I18N detail_name) $(_tui_detail_field "${_json}" .name)"$'\n'
    _text+="$(i18n_t TUI_BACKEND_I18N detail_category) $(_tui_detail_field "${_json}" .category)"$'\n'
    _text+="$(i18n_t TUI_BACKEND_I18N detail_description) $(_tui_detail_field "${_json}" .description)"$'\n'
    _text+="$(i18n_t TUI_BACKEND_I18N detail_tags) $(_tui_detail_field "${_json}" .tags)"$'\n'
    _text+="$(i18n_t TUI_BACKEND_I18N detail_depends_on) $(_tui_detail_field "${_json}" .depends_on)"$'\n'
    _text+="$(i18n_t TUI_BACKEND_I18N detail_conflicts) $(_tui_detail_field "${_json}" .conflicts)"$'\n'
    _text+="$(i18n_t TUI_BACKEND_I18N detail_supported_ubuntu) $(_tui_detail_field "${_json}" .supported_ubuntu)"$'\n'
    _text+="$(i18n_t TUI_BACKEND_I18N detail_supported_platforms) $(_tui_detail_field "${_json}" .supported_platforms)"
    printf '%s\n' "${_text}"
}

# #215 fallback: detail text for an UNREGISTERED installed entry — present in
# state.json but absent from the current catalog (`show --json` failed). Shows
# the facts state.json actually holds (version_provided / installed_at) plus a
# clear "not in current catalog" note:
#   tui_detail_unregistered_text <module> <state_json>
tui_detail_unregistered_text() {
    local _module="$1" _state="$2"
    local _none; _none="$(i18n_t TUI_BACKEND_I18N detail_none)"
    local _ver _at
    _ver="$(jq -r --arg m "${_module}" --arg none "${_none}" \
        '.installed[$m].synced.version_provided // $none' <<<"${_state}")"
    _at="$(jq -r --arg m "${_module}" --arg none "${_none}" \
        '(.installed[$m].synced.installed_at // $none) | sub("T"; " ") | .[0:16]' <<<"${_state}")"
    local _text=""
    _text+="$(i18n_t TUI_BACKEND_I18N detail_name) ${_module}"$'\n'
    _text+="$(i18n_t TUI_BACKEND_I18N detail_version) ${_ver}"$'\n'
    _text+="$(i18n_t TUI_BACKEND_I18N detail_installed_at) ${_at}"$'\n\n'
    _text+="$(i18n_t TUI_BACKEND_I18N detail_unregistered_note)"
    printf '%s\n' "${_text}"
}

# One §8.1 category row as "tag<TAB>label<TAB>description". PRD D2: the row
# count is SELECTED/total (from the in-memory accumulator <selected>), NOT
# installed/total — mirrors tui_fzf_menu_rows so both tiers show the same count.
# <selected> is a space-separated module-name list ("" → 0 selected).
#   _tui_category_entry <list_json> <category> [<selected>]
_tui_category_entry() {
    local _json="$1" _cat="$2" _selected="${3:-}"
    local _sel _tot
    read -r _sel _tot <<<"$(tui_category_sel_stats "${_json}" "${_cat}" "${_selected}")"
    local _label _desc
    case "${_cat}" in
        base)
            _label="$(i18n_t TUI_BACKEND_I18N cat_base_label)"
            _desc="$(i18n_t TUI_BACKEND_I18N cat_base_desc)" ;;
        recommended)
            # The recommended label has its own {0}/{1} count slot.
            _label="$(i18n_t TUI_BACKEND_I18N cat_recommended_label "${_sel}" "${_tot}")"
            _desc="$(i18n_t TUI_BACKEND_I18N cat_recommended_desc)" ;;
        optional)
            _label="$(i18n_t TUI_BACKEND_I18N cat_optional_label)"
            _desc="$(i18n_t TUI_BACKEND_I18N cat_optional_desc)" ;;
        experimental)
            _label="$(i18n_t TUI_BACKEND_I18N cat_experimental_label)"
            _desc="$(i18n_t TUI_BACKEND_I18N cat_experimental_desc)" ;;
        *)
            return 0 ;;
    esac
    # D2: every category row carries SELECTED/total. recommended already has it
    # in the label; the others (no {0}/{1} slot) get the count appended.
    [[ "${_cat}" != "recommended" ]] && _label="${_label} (${_sel}/${_tot})"
    printf '%s\t%s\t%s\n' "${_cat}" "${_label}" "${_desc}"
}

# Full §8.1 main-menu rows ("tag<TAB>label<TAB>description" per line).
# Category rows are derived from the live payload, so empty categories
# disappear and future non-empty ones appear without a spec change (Q44).
# <selected> (optional 2nd arg) is the space-separated accumulator names — the
# category rows render SELECTED/total from it (PRD D2; "" → 0 selected).
tui_main_menu_entries() {
    local _json="$1" _selected="${2:-}" _cat

    # Three logical groups, in order (no separator rows: whiptail has no
    # non-selectable row, so a divider could be landed on and was confusing —
    # #216 removed them; ordering conveys the grouping):
    #   Group 1 — build the pick: quick-setup + category browse rows
    #   Group 2 — manage / info:  manage, secrets, sysinfo
    #   Group 3 — action:         run (the only batch execution point, Q43)
    printf 'quick-setup\t%s\t%s\n' \
        "$(i18n_t TUI_BACKEND_I18N menu_quick_setup_label)" \
        "$(i18n_t TUI_BACKEND_I18N menu_quick_setup_desc)"
    while IFS= read -r _cat; do
        _tui_category_entry "${_json}" "${_cat}" "${_selected}"
    done < <(tui_categories "${_json}")
    printf 'manage\t%s\t%s\n' \
        "$(i18n_t TUI_BACKEND_I18N menu_manage_label)" \
        "$(i18n_t TUI_BACKEND_I18N menu_manage_desc)"
    printf 'secrets\t%s\t%s\n' \
        "$(i18n_t TUI_BACKEND_I18N menu_secrets_label)" \
        "$(i18n_t TUI_BACKEND_I18N menu_secrets_desc)"
    printf 'sysinfo\t%s\t%s\n' \
        "$(i18n_t TUI_BACKEND_I18N menu_sysinfo_label)" \
        "$(i18n_t TUI_BACKEND_I18N menu_sysinfo_desc)"
    # #203 Help — a backend-aware key reference (design §3). Placed after info
    # and before Run so the action row stays last; a contextual `?`-key inside a
    # widget is impossible on both backends, so this menu entry IS the mechanism.
    printf 'help\t%s\t%s\n' \
        "$(i18n_t TUI_BACKEND_I18N menu_help_label)" \
        "$(i18n_t TUI_BACKEND_I18N menu_help_desc)"
    # §8.1 < Run > — the ONLY batch execution point (Q43). Rendered as the
    # last menu row because a second action button next to OK exists only
    # on dialog (--extra-button), not whiptail; a row keeps both backends
    # behaviorally identical. < Exit > is the relabeled Cancel button.
    printf 'run\t%s\t%s\n' \
        "$(i18n_t TUI_BACKEND_I18N menu_run_label)" \
        "$(i18n_t TUI_BACKEND_I18N menu_run_desc)"
}

# #203 Help-screen body text (design §3). The whiptail Fallback tier gets the
# Tab-centric reference. The argument is the backend FAMILY (only "whiptail"
# today, ADR-0024); it is accepted for call-site symmetry but the body is always
# the whiptail reference. \n escapes are expanded so the msgbox renders real
# lines.
tui_help_text() {
    printf '%b\n' "$(i18n_t TUI_BACKEND_I18N help_whiptail)"
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

# ── Backend rendering wrappers (dispatcher → _tui_<widget>_whiptail) ──────────
# The 4 contract widgets (menu / checklist / msgbox / yesno) keep a stable
# argv contract (frontend passes `tag item [status]`, reads back the TAG).
# gum is dropped (ADR-0024); whiptail is the only dialog backend family (a
# dialog-named binary shares the same --menu/--msgbox/--yesno shape). The
# tui_render_* dispatchers are kept as thin indirection so the call sites stay
# backend-agnostic. Live-widget behavior is covered by the AC-10 whiptail smoke
# harness; argv-level + tag/index mapping by the unit bats.
_tui_backend_family() {
    printf 'whiptail\n'
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
    # #203 inline-hint gating: whiptail has no key footer, so when hints are ON
    # the multi-select hint is appended to the prompt text (checklist only — the
    # --menu widget is never rewritten). TUI_HINTS=0 renders the prompt clean.
    if [[ "${TUI_HINTS:-1}" != "0" ]]; then
        _text+=$'\n'"$(i18n_t TUI_BACKEND_I18N hint_checklist_whiptail)"
    fi
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

# _tui_input_whiptail <title> <prompt> [default] → typed value on stdout.
# whiptail writes the edited value to stderr; the 3>&1 1>&2 2>&3 swap (same as
# --menu/--checklist) brings it to stdout. rc 1/255 on Cancel/Esc propagates.
# The empty=cancel contract lives in the tui_render_input dispatcher — this
# adapter is purely the backend invocation.
_tui_input_whiptail() {
    "${TUI_BACKEND:?TUI_BACKEND not set}" --title "$1" \
        --inputbox "$2" "${TUI_HEIGHT}" "${TUI_WIDTH}" "${3:-}" 3>&1 1>&2 2>&3
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

# ── Public dispatchers (stable contract) ─────────────────────────────────────
tui_render_menu()      { "_tui_menu_$(_tui_backend_family)" "$@"; }
tui_render_checklist() { "_tui_checklist_$(_tui_backend_family)" "$@"; }
tui_render_msgbox()    { "_tui_msgbox_$(_tui_backend_family)" "$@"; }
tui_render_yesno()     { "_tui_yesno_$(_tui_backend_family)" "$@"; }

# tui_render_input <title> <prompt> [default] → typed value on stdout, rc 0.
# §5 contract enforced HERE: a cancel (nonzero rc
# from the adapter) propagates as nonzero; a successful-but-EMPTY result is
# treated as cancel → rc 1, no value printed. Success → value + rc 0. There is
# deliberately NO no-echo variant — secret values never pass through this widget
# (AC-20); the tool prompts for those on its own no-echo tty.
tui_render_input() {
    local _value
    _value="$("_tui_input_$(_tui_backend_family)" "$@")" || return $?
    [[ -n "${_value}" ]] || return 1
    printf '%s\n' "${_value}"
}
