#!/usr/bin/env bash
# setup_ubuntu_tui.sh — init_ubuntu TUI entry point (PRD §8, G4)
#
# TUI = a frontend of the CLI (PRD §8 / G4): this script renders screens
# and collects selections ONLY.
#   - Menu data comes exclusively from forked `setup_ubuntu list --json` /
#     `setup_ubuntu detect --json` subprocesses (ADR-0019 schema).
#   - Every action forks a `setup_ubuntu <subcommand>` subprocess.
#   - It never sources engine libs (registry / resolver / runner / state)
#     and never writes state — enforced by the G4 grep gate in
#     test/unit/tui_backend_spec.bats.
#
# Issue #69 scope: skeleton + main-menu rendering. Follow-ups (all landed):
#   #70  checkbox accumulator + Run / Review & Install
#   #71  Quick Setup multi-step wizard (§8.2.1)
#   #72  Manage Installed (update / remove / purge) + Manage Secrets
#
# `set -uo pipefail` (not -e): dialog/whiptail return rc 1/255 for the
# Cancel button and ESC, which is normal control flow here, not an error
# (same spirit as ADR-0007 — nonzero rcs carry contract meaning).

set -uo pipefail

# ── Path resolution ──────────────────────────────────────────────────────────
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="${SCRIPT_PATH}"
# Env-overridable so the bats e2e harness can substitute a recording mock
# CLI; real sessions never set it and fork the sibling setup_ubuntu.sh.
TUI_CLI="${TUI_CLI:-${REPO_ROOT}/setup_ubuntu.sh}"
export TUI_CLI
# Same override seam for the Manage Secrets fork target (§8.1 item 6).
TUI_SECRETS="${TUI_SECRETS:-${REPO_ROOT}/setup_secrets.sh}"
export TUI_SECRETS

: "${INIT_UBUNTU_VERSION:=0.1.0-draft}"

# G4: the ONLY library the TUI sources is its own presentation helper.
# (tui_backend.sh sources lib/i18n.sh itself, so i18n_t is available here too.)
# shellcheck source=lib/tui_backend.sh
source "${REPO_ROOT}/lib/tui_backend.sh"

# Resolve the UI language once (env > config ui.lang > $LANG, sanitized). The
# TUI never sources the engine, so config_get is absent here and resolution
# lands on INIT_UBUNTU_LANG / $LANG — exactly the entrypoint contract (#185).
i18n_resolve_init_ubuntu_lang

# ── i18n table (#185): strings setup_ubuntu_tui.sh ITSELF authors ────────────
# Screen titles, prompts, confirmations, status text the TUI frontend writes.
# Module descriptions / detect output / plan bullets are CLI pass-through and
# are NOT translated. `en.<key>` is byte-identical to the prior literal; zh-TW
# uses full-width punctuation. {0}{1} are i18n_t positional args.
# kcov-exclude-start (i18n data table; excluded from coverage — kcov counts each entry line as uncoverable, issue #185)
declare -gA TUI_I18N=(
    # System Info screen (_tui_screen_system_info).
    [en.title_system_info]="System Info"
    [zh-TW.title_system_info]="系統資訊"
    [en.sysinfo_detect_failed]="ERROR: 'setup_ubuntu detect' failed."
    [zh-TW.sysinfo_detect_failed]="錯誤:'setup_ubuntu detect' 執行失敗。"
    [en.sysinfo_override_line]="platform override:  {0} (this session)"
    [zh-TW.sysinfo_override_line]="平台覆寫:  {0} (本工作階段)"
    [en.title_platform_override]="Platform Override"
    [zh-TW.title_platform_override]="平台覆寫"
    [en.override_question]="Override the detected platform (form factor) for this session?"
    [zh-TW.override_question]="是否在本工作階段覆寫偵測到的平台 (硬體型態)?"
    [en.override_clear]="Clear override (use auto-detection)"
    [zh-TW.override_clear]="清除覆寫 (改用自動偵測)"
    [en.select_form_factor]="Select a form factor (PRD §7.5 --profile):"
    [zh-TW.select_form_factor]="選擇硬體型態 (PRD §7.5 --profile):"

    # Category checklist screen (_tui_screen_category).
    [en.title_modules]="Modules"
    [zh-TW.title_modules]="模組"
    [en.no_modules_in_cat]="No modules in category '{0}'."
    [zh-TW.no_modules_in_cat]="類別 '{0}' 中沒有模組。"
    [en.cat_modules_title]="{0} Modules"
    [zh-TW.cat_modules_title]="{0} 模組"
    [en.check_modules_help]="Check modules to install. < OK > keeps this page, < Back > discards it."
    [zh-TW.check_modules_help]="勾選要安裝的模組。< OK > 保留此頁,< Back > 捨棄此頁。"

    # Review & Install screen (_tui_screen_review).
    [en.title_review]="Review & Install"
    [zh-TW.title_review]="檢閱並安裝"
    [en.review_plan_failed]="ERROR: 'setup_ubuntu install --dry-run' failed — cannot build the plan."
    [zh-TW.review_plan_failed]="錯誤:'setup_ubuntu install --dry-run' 執行失敗 — 無法產生安裝計畫。"
    [en.review_will_install]="Will install {0} module(s):"
    [zh-TW.review_will_install]="將安裝 {0} 個模組:"
    [en.review_will_pull]="will pull {0} deps"
    [zh-TW.review_will_pull]="將連帶安裝 {0} 個相依套件"
    [en.review_proceed]="Install now (forks setup_ubuntu)"
    [zh-TW.review_proceed]="立即安裝 (fork setup_ubuntu)"
    [en.review_show_deps]="Show dependency details ({0})"
    [zh-TW.review_show_deps]="顯示相依詳細資訊 ({0})"
    [en.title_dep_details]="Dependency details"
    [zh-TW.title_dep_details]="相依詳細資訊"
    [en.nothing_selected]="nothing selected"
    [zh-TW.nothing_selected]="未選擇任何項目"

    # Quick Setup wizard (_tui_qs_* / _tui_screen_quick_setup).
    [en.title_qs_platform]="Quick Setup — Platform Override"
    [zh-TW.title_qs_platform]="快速安裝 — 平台覆寫"
    [en.title_qs_step2]="Quick Setup — Step 2/4: Recommended modules"
    [zh-TW.title_qs_step2]="快速安裝 — 步驟 2/4:推薦模組"
    [en.qs_step2_help]="{0} / {1} will be installed — adjust and press OK."
    [zh-TW.qs_step2_help]="將安裝 {0} / {1} 個 — 調整後按 OK。"
    [en.title_qs_step3_suite]="Quick Setup — Step 3/4: CLI Essentials suite? ({0} tools)"
    [zh-TW.title_qs_step3_suite]="快速安裝 — 步驟 3/4:CLI 必備套件? ({0} 項工具)"
    [en.qs_step3_all]="Yes, install all"
    [zh-TW.qs_step3_all]="是,全部安裝"
    [en.qs_step3_pick]="Pick individually"
    [zh-TW.qs_step3_pick]="逐項挑選"
    [en.qs_step3_skip]="Skip"
    [zh-TW.qs_step3_skip]="略過"
    [en.title_qs_step3_pick]="Quick Setup — Step 3/4: CLI Essentials"
    [zh-TW.title_qs_step3_pick]="快速安裝 — 步驟 3/4:CLI 必備套件"
    [en.qs_step3_pick_help]="Check the tools to install."
    [zh-TW.qs_step3_pick_help]="勾選要安裝的工具。"
    [en.title_qs_step4]="Quick Setup — Step 4/4: AI agent CLI? (multi-select)"
    [zh-TW.title_qs_step4]="快速安裝 — 步驟 4/4:AI agent CLI? (可多選)"
    [en.qs_step4_help]="Check the agent CLIs to install."
    [zh-TW.qs_step4_help]="勾選要安裝的 agent CLI。"
    [en.title_qs_step1]="Quick Setup — Step 1/4: Confirm platform"
    [zh-TW.title_qs_step1]="快速安裝 — 步驟 1/4:確認平台"
    [en.qs_step1_detected]="Detected: {0}"
    [zh-TW.qs_step1_detected]="偵測結果:{0}"
    [en.qs_step1_form_factor]="Form factor: {0}"
    [zh-TW.qs_step1_form_factor]="硬體型態:{0}"
    [en.qs_step1_continue]="Yes, continue"
    [zh-TW.qs_step1_continue]="是,繼續"
    [en.qs_step1_override]="Override platform"
    [zh-TW.qs_step1_override]="覆寫平台"
    [en.title_quick_setup]="Quick Setup"
    [zh-TW.title_quick_setup]="快速安裝"
    [en.qs_persist_failed]="ERROR: failed to persist the platform override — nothing was installed."
    [zh-TW.qs_persist_failed]="錯誤:無法儲存平台覆寫 — 未安裝任何項目。"

    # Manage Installed (#72, §8.3 / §8.4).
    [en.confirm_action_title]="Confirm {0}"
    [zh-TW.confirm_action_title]="確認{0}"
    [en.confirm_plan_failed]="ERROR: 'setup_ubuntu {0} --dry-run' failed — cannot enumerate the plan."
    [zh-TW.confirm_plan_failed]="錯誤:'setup_ubuntu {0} --dry-run' 執行失敗 — 無法列出計畫。"
    [en.btn_proceed]="Proceed"
    [zh-TW.btn_proceed]="繼續"
    [en.btn_cancel]="Cancel"
    [zh-TW.btn_cancel]="取消"
    [en.btn_back]="Back"
    [zh-TW.btn_back]="返回"
    [en.btn_exit]="Exit"
    [zh-TW.btn_exit]="離開"
    [en.manage_title]="Manage '{0}'"
    [zh-TW.manage_title]="管理 '{0}'"
    [en.manage_action_help]="Pick an action (forks the setup_ubuntu CLI — G4):"
    [zh-TW.manage_action_help]="選擇動作 (fork setup_ubuntu CLI — G4):"
    [en.manage_update]="Upgrade to the latest version"
    [zh-TW.manage_update]="升級到最新版本"
    [en.manage_remove]="Remove (config retained)"
    [zh-TW.manage_remove]="移除 (保留設定)"
    [en.manage_purge]="Remove + delete config (destructive)"
    [zh-TW.manage_purge]="移除 + 刪除設定 (具破壞性)"
    [en.title_manage_installed]="Manage Installed"
    [zh-TW.title_manage_installed]="管理已安裝項目"
    [en.manage_list_failed]="ERROR: 'setup_ubuntu list --installed --json' failed."
    [zh-TW.manage_list_failed]="錯誤:'setup_ubuntu list --installed --json' 執行失敗。"
    [en.manage_none_installed]="(no modules recorded as installed)"
    [zh-TW.manage_none_installed]="(沒有已安裝的模組紀錄)"
    [en.manage_toggle_group]="Switch view: group by tag"
    [zh-TW.manage_toggle_group]="切換檢視:依標籤分組"
    [en.manage_toggle_flat]="Switch view: flat list"
    [zh-TW.manage_toggle_flat]="切換檢視:平面清單"
    [en.manage_list_help]="Module / Version / Installed at — pick one to manage:"
    [zh-TW.manage_list_help]="模組 / 版本 / 安裝時間 — 選一項進行管理:"

    # Manage Secrets (_tui_screen_secrets).
    [en.secrets_return]=$'\n[setup_secrets exited {0}] Press Enter to return to the menu...'
    [zh-TW.secrets_return]=$'\n[setup_secrets 結束,代碼 {0}] 按 Enter 返回選單...'

    # Main menu loop (_tui_main_loop).
    [en.main_title]="init_ubuntu v{0}"
    [zh-TW.main_title]="init_ubuntu v{0}"
    [en.main_system]="System: {0}"
    [zh-TW.main_system]="系統:{0}"
)
# kcov-exclude-end
# TUI_I18N is consumed by i18n_t via a nameref on the table NAME passed as a
# bareword argument — static analysis cannot follow that indirection, so make
# the read explicit here to keep shellcheck honest (no disable directive).
: "${TUI_I18N[@]+x}"

# ── In-memory session selections (Q43: never persisted by the TUI) ──────────
# Platform override chosen on the System Info screen. Consumed as
# `--profile=<value>` on action forks; it is NOT written to config.ini by
# the TUI (G4 / §8.2.1 cancel table).
TUI_PLATFORM_OVERRIDE=""
# The Quick Setup Step-1 override (§8.2.1) is deliberately NOT a global:
# it lives in _tui_screen_quick_setup's locals during prepare and reaches
# config.ini only on the Proceed leg, via a forked
# `setup_ubuntu config set platform.override <v>` (the TUI itself never
# writes the file).
# Manage Installed view mode (§8.3 "group by TAGS[0]" toggle). Session-only,
# like every other piece of TUI state.
TUI_MANAGE_GROUPED="false"

# ── Usage ────────────────────────────────────────────────────────────────────

_tui_usage() {
    cat <<'EOF'
Usage: setup_ubuntu_tui.sh [flags]

Interactive TUI frontend for setup_ubuntu. Renders menus with gum
(preferred, modern) or whiptail (Ubuntu default fallback) and forks
`setup_ubuntu` subprocesses for all data and actions.

Flags:
  -h / --help            Show this help
  --version              Show tool version
  --backend gum|whiptail Force the rendering backend (skips detection and
                         the install prompt). Invalid value → exit 2.
  --lang <code>          Force the UI language for this session
                         (en|zh-TW|zh-CN|ja); overrides $LANG / config.
                         Invalid value → falls back to en with a warning.

Requirements:
  - `gum` or `whiptail` on PATH. gum absent + interactive → you are offered
    `setup_ubuntu install gum`; otherwise whiptail (no auto-install — the
    TUI forks the CLI; see PRD §8.5).
  - sudo available (otherwise exit 4 — use the CLI instead:
    `setup_ubuntu install <module>`)

See PRD §8 for the full TUI specification.
EOF
}

# ── Screens ──────────────────────────────────────────────────────────────────

# System Info (§8.1 item 7): show forked `setup_ubuntu detect` output and
# offer a platform override (kept in TUI memory only).
_tui_screen_system_info() {
    local _detect_text _title_si
    _title_si="$(i18n_t TUI_I18N title_system_info)"
    _detect_text="$("${TUI_CLI}" detect 2>/dev/null)" || {
        tui_render_msgbox "${_title_si}" "$(i18n_t TUI_I18N sysinfo_detect_failed)"
        return 0
    }
    if [[ -n "${TUI_PLATFORM_OVERRIDE}" ]]; then
        _detect_text+=$'\n'"$(i18n_t TUI_I18N sysinfo_override_line "${TUI_PLATFORM_OVERRIDE}")"
    fi
    tui_render_msgbox "${_title_si}" "${_detect_text}"

    local _title_po
    _title_po="$(i18n_t TUI_I18N title_platform_override)"
    if ! tui_render_yesno "${_title_po}" \
        "$(i18n_t TUI_I18N override_question)"; then
        return 0
    fi

    local -a _choices=()
    local _tag _desc
    while IFS=$'\t' read -r _tag _desc; do
        _choices+=("${_tag}" "${_desc}")
    done < <(tui_platform_choices)
    _choices+=("detected" "$(i18n_t TUI_I18N override_clear)")

    local _choice
    _choice="$(tui_render_menu "${_title_po}" \
        "$(i18n_t TUI_I18N select_form_factor)" \
        "${_choices[@]}")" || return 0

    if [[ "${_choice}" == "detected" ]]; then
        TUI_PLATFORM_OVERRIDE=""
    else
        TUI_PLATFORM_OVERRIDE="${_choice}"
    fi
}

# ── Checkbox accumulator screens (#70, Q43 / §8.2) ───────────────────────────

# One category page as a pure check-list. < OK > stores the page in the
# in-memory accumulator (tui_selection_replace_page), < Back > / ESC
# discards the page. Nothing is executed and nothing touches disk here —
# `< Run >` on the main menu is the only batch execution point.
_tui_screen_category() {
    local _cat="$1" _json="$2"
    local -a _rows=()
    local _name _label _status
    while IFS=$'\t' read -r _name _label _status; do
        _rows+=("${_name}" "${_label}" "${_status}")
    done < <(tui_checklist_entries "${_json}" "${_cat}" \
        "$(tui_selection_list | tr '\n' ' ')")

    if [[ "${#_rows[@]}" -eq 0 ]]; then
        tui_render_msgbox "$(i18n_t TUI_I18N title_modules)" \
            "$(i18n_t TUI_I18N no_modules_in_cat "${_cat}")"
        return 0
    fi

    local _picked
    if ! _picked="$(TUI_CANCEL_LABEL="$(i18n_t TUI_I18N btn_back)" tui_render_checklist \
        "$(i18n_t TUI_I18N cat_modules_title "${_cat^}")" \
        "$(i18n_t TUI_I18N check_modules_help)" \
        "${_rows[@]}")"; then
        return 0  # Back / ESC: discard this page's changes (Q43)
    fi

    local -a _names=()
    local _line
    while IFS= read -r _line; do
        [[ -n "${_line}" ]] && _names+=("${_line}")
    done <<<"${_picked}"
    tui_selection_replace_page "${_json}" "${_cat}" "${_names[@]}"
}

# Review & Install screen shared by < Run > (#70) and Quick Setup (#71):
#   _tui_screen_review <module...>
# Full selection list + collapsed "will pull N deps" summary (arch Q-A3;
# expandable via a details row). Pure decision screen: rc 0 = the user
# chose Proceed (the caller forks the ONE CLI install pipeline — G4 /
# AC-11: same path as the CLI), rc 1 = Back / Cancel / plan failure; the
# caller decides what selection memory survives (Run: the Q43 accumulator
# stays; Quick Setup: the wizard locals die with the caller → pure cancel).
_tui_screen_review() {
    local -a _sel=("$@")

    local _title_rv
    _title_rv="$(i18n_t TUI_I18N title_review)"
    local _plan
    if ! _plan="$(tui_cli_install_plan "${_sel[@]}")"; then
        tui_render_msgbox "${_title_rv}" \
            "$(i18n_t TUI_I18N review_plan_failed)"
        return 1
    fi
    local -a _deps=()
    mapfile -t _deps < <(tui_plan_deps "${_plan}" "${_sel[@]}")

    local _text
    _text="$(i18n_t TUI_I18N review_will_install "${#_sel[@]}")"$'\n'
    _text+="$(printf '  %s\n' "${_sel[@]}")"
    if [[ "${#_deps[@]}" -gt 0 ]]; then
        _text+=$'\n'"$(i18n_t TUI_I18N review_will_pull "${#_deps[@]}")"
    fi

    local -a _entries=("proceed" "$(i18n_t TUI_I18N review_proceed)")
    if [[ "${#_deps[@]}" -gt 0 ]]; then
        _entries+=("deps" "$(i18n_t TUI_I18N review_show_deps "${#_deps[@]}")")
    fi

    local _choice
    while :; do
        if ! _choice="$(TUI_CANCEL_LABEL="$(i18n_t TUI_I18N btn_back)" tui_render_menu \
            "${_title_rv}" "${_text}" "${_entries[@]}")"; then
            return 1  # Back / Cancel: the caller owns what survives
        fi
        case "${_choice}" in
            deps)
                tui_render_msgbox "$(i18n_t TUI_I18N title_dep_details)" \
                    "$(printf '%s\n' "${_deps[@]}")"
                ;;
            proceed)
                return 0
                ;;
        esac
    done
}

# < Run > (§8.1): Review & Install over the Q43 accumulator. Back keeps
# the selections and returns to the main menu.
_tui_screen_run() {
    if [[ "$(tui_selection_count)" -eq 0 ]]; then
        tui_render_msgbox "$(i18n_t TUI_I18N title_review)" \
            "$(i18n_t TUI_I18N nothing_selected)"
        return 0
    fi

    local -a _sel=()
    mapfile -t _sel < <(tui_selection_list)
    _tui_screen_review "${_sel[@]}" || return 0
    _tui_exec_install "${_sel[@]}"  # never returns
}

# Shared Proceed leg (§8.2.1 execution model): clear the screen, fork ONE
# CLI pipeline in the foreground (exec_cmd stream + Action-required
# aggregation render on the plain terminal — no --gauge/--prgbox), then
# exit the TUI with its rc. Used by Run/Proceed (#70), Quick Setup (#71)
# and the Manage Installed actions (#72) — G4 single execution path.
_tui_exec_cli() {
    clear 2>/dev/null || printf '\033c'
    "${TUI_CLI}" "$@"
    exit $?
}

_tui_exec_install() {
    local -a _argv=()
    mapfile -t _argv < <(tui_install_args "${TUI_PLATFORM_OVERRIDE}" "$@")
    _tui_exec_cli "${_argv[@]}"
}

# ── Quick Setup wizard (#71, §8.2.1) ─────────────────────────────────────────
# Four prepare steps accumulate picks into FUNCTION-LOCAL memory, then the
# shared Review screen executes via _tui_qs_proceed. Prepare is pure
# memory (§8.2.1 cancel table): Cancel / ESC at any step returns to the
# main menu having forked nothing that writes — no config.ini write, no
# state write. SIGINT during prepare kills the TUI process outright with
# the same zero-side-effect guarantee; SIGINT after Proceed lands in the
# foreground CLI pipeline, which finishes the current step, prints the
# partial summary and exits 6 (ADR-0015 partial-install policy) — the
# exec in _tui_exec_install propagates that rc as the TUI's own.

# Step 1 submenu: pick an override form factor. Prints the choice;
# rc != 0 = Cancel (keep the current value).
_tui_qs_platform_menu() {
    local -a _choices=()
    local _tag _desc
    while IFS=$'\t' read -r _tag _desc; do
        _choices+=("${_tag}" "${_desc}")
    done < <(tui_platform_choices)
    tui_render_menu "$(i18n_t TUI_I18N title_qs_platform)" \
        "$(i18n_t TUI_I18N select_form_factor)" "${_choices[@]}"
}

# Steps 2-4 below print the picked module names (one per line) on stdout;
# rc != 0 = Cancel / ESC → the wizard aborts (pure cancel). A step with no
# offerable modules prints nothing and succeeds (skipped transparently).

# Step 2/4: recommended modules, is_recommended-preselected (Q36-filtered).
_tui_qs_step2() {
    local -a _rows=()
    local _name _label _status _on=0
    while IFS=$'\t' read -r _name _label _status; do
        _rows+=("${_name}" "${_label}" "${_status}")
        [[ "${_status}" == "on" ]] && _on=$((_on + 1))
    done < <(tui_qs_recommended_entries "$1" "$2")
    [[ "${#_rows[@]}" -eq 0 ]] && return 0

    tui_render_checklist "$(i18n_t TUI_I18N title_qs_step2)" \
        "$(i18n_t TUI_I18N qs_step2_help "${_on}" "$(( ${#_rows[@]} / 3 ))")" \
        "${_rows[@]}"
}

# Step 3/4: the CLI-essentials suite — whole suite / pick / skip (§8.2.1).
_tui_qs_step3() {
    local -a _rows=() _names=()
    local _name _label _status
    while IFS=$'\t' read -r _name _label _status; do
        _rows+=("${_name}" "${_label}" "${_status}")
        _names+=("${_name}")
    done < <(tui_qs_tag_entries "$1" cli-essentials "$2")
    [[ "${#_rows[@]}" -eq 0 ]] && return 0

    local _joined
    _joined="$(printf '%s / ' "${_names[@]}")"
    _joined="${_joined% / }"

    local _choice
    _choice="$(tui_render_menu \
        "$(i18n_t TUI_I18N title_qs_step3_suite "${#_names[@]}")" \
        "${_joined}" \
        "all"  "$(i18n_t TUI_I18N qs_step3_all)" \
        "pick" "$(i18n_t TUI_I18N qs_step3_pick)" \
        "skip" "$(i18n_t TUI_I18N qs_step3_skip)")" || return 1
    case "${_choice}" in
        all)  printf '%s\n' "${_names[@]}" ;;
        pick) tui_render_checklist "$(i18n_t TUI_I18N title_qs_step3_pick)" \
                  "$(i18n_t TUI_I18N qs_step3_pick_help)" "${_rows[@]}" || return 1 ;;
        skip) : ;;
    esac
}

# Step 4/4: AI agent CLI multi-select (recommended ones preselected).
_tui_qs_step4() {
    local -a _rows=()
    local _name _label _status
    while IFS=$'\t' read -r _name _label _status; do
        _rows+=("${_name}" "${_label}" "${_status}")
    done < <(tui_qs_tag_entries "$1" agent "$2")
    [[ "${#_rows[@]}" -eq 0 ]] && return 0

    tui_render_checklist "$(i18n_t TUI_I18N title_qs_step4)" \
        "$(i18n_t TUI_I18N qs_step4_help)" "${_rows[@]}"
}

# §8.2.1 wizard driver: Step 1 platform confirm → Steps 2-4 accumulate →
# Review & Install (shared screen) → Proceed leg.
_tui_screen_quick_setup() {
    local _list_json="$1" _detect_json="$2"
    local _override="" _form _summary _choice _picked
    _summary="$(tui_system_summary "${_detect_json}")"

    # Step 1/4: confirm platform. An override only updates wizard memory;
    # re-render the confirmation so the user approves the final value.
    while :; do
        _form="$(tui_effective_form_factor "${_detect_json}" "${_override}")"
        _choice="$(tui_render_menu \
            "$(i18n_t TUI_I18N title_qs_step1)" \
            "$(i18n_t TUI_I18N qs_step1_detected "${_summary}")"$'\n'"$(i18n_t TUI_I18N qs_step1_form_factor "${_form}")" \
            "continue" "$(i18n_t TUI_I18N qs_step1_continue)" \
            "override" "$(i18n_t TUI_I18N qs_step1_override)")" || return 0
        [[ "${_choice}" == "continue" ]] && break
        if _picked="$(_tui_qs_platform_menu)"; then
            _override="${_picked}"
        fi
    done

    local -a _sel=()
    local _out _line
    _out="$(_tui_qs_step2 "${_list_json}" "${_form}")" || return 0
    while IFS= read -r _line; do
        [[ -n "${_line}" ]] && _sel+=("${_line}")
    done <<<"${_out}"
    _out="$(_tui_qs_step3 "${_list_json}" "${_form}")" || return 0
    while IFS= read -r _line; do
        [[ -n "${_line}" ]] && _sel+=("${_line}")
    done <<<"${_out}"
    _out="$(_tui_qs_step4 "${_list_json}" "${_form}")" || return 0
    while IFS= read -r _line; do
        [[ -n "${_line}" ]] && _sel+=("${_line}")
    done <<<"${_out}"

    if [[ "${#_sel[@]}" -eq 0 ]]; then
        tui_render_msgbox "$(i18n_t TUI_I18N title_quick_setup)" \
            "$(i18n_t TUI_I18N nothing_selected)"
        return 0
    fi

    # Review backing out before Proceed = pure cancel: the override and
    # the picks die with this function's locals (§8.2.1 cancel table).
    _tui_screen_review "${_sel[@]}" || return 0

    # Proceed leg: the ONE point where the Step-1 override leaves TUI
    # memory (§8.2.1 "not written to config.ini until Review"). Persisting
    # goes through a `setup_ubuntu config set` fork (G4: the TUI never
    # writes config itself), then the shared exec leg forks the install
    # pipeline with `--profile=<override>` and the user-picked names only —
    # which is what makes the ADR-0010 manual-flag matrix structural:
    # named modules get manual=true via the CLI's requested-modules path,
    # engine-pulled deps stay manual=false (they never appear on this argv).
    if [[ -n "${_override}" ]]; then
        if ! "${TUI_CLI}" config set platform.override "${_override}"; then
            tui_render_msgbox "$(i18n_t TUI_I18N title_quick_setup)" \
                "$(i18n_t TUI_I18N qs_persist_failed)"
            return 0
        fi
        TUI_PLATFORM_OVERRIDE="${_override}"
    fi
    _tui_exec_install "${_sel[@]}"  # never returns
}

# ── Manage Installed (#72, §8.3 / §8.4) ──────────────────────────────────────

# §8.4 destructive confirm: enumerate the concrete actions (exact forked
# command, dry-run-derived module plan, state.json change), then
# Proceed / Cancel. Cancel forks nothing and returns to the module list.
_tui_screen_confirm_destructive() {
    local _action="$1" _module="$2"
    local _confirm_title
    _confirm_title="$(i18n_t TUI_I18N confirm_action_title "${_action^}")"
    local _plan
    if ! _plan="$(tui_cli_manage_plan "${_action}" "${_module}")"; then
        tui_render_msgbox "${_confirm_title}" \
            "$(i18n_t TUI_I18N confirm_plan_failed "${_action}")"
        return 0
    fi
    local _text
    _text="$(tui_manage_confirm_text "${_action}" "${_module}" "${_plan}")"
    if ! TUI_YES_LABEL="$(i18n_t TUI_I18N btn_proceed)" \
         TUI_NO_LABEL="$(i18n_t TUI_I18N btn_cancel)" tui_render_yesno \
        "${_confirm_title}" "${_text}"; then
        return 0  # Cancel / ESC: nothing was forked
    fi
    local -a _argv=()
    mapfile -t _argv < <(tui_manage_args "${_action}" "${_module}")
    _tui_exec_cli "${_argv[@]}"  # never returns
}

# Per-module action menu: Update forks straight away (non-destructive —
# §8.4 only gates Remove / Purge); Remove / Purge route through the
# confirm dialog. < Back > returns to the module list.
_tui_screen_manage_action() {
    local _module="$1" _action
    _action="$(TUI_CANCEL_LABEL="$(i18n_t TUI_I18N btn_back)" tui_render_menu \
        "$(i18n_t TUI_I18N manage_title "${_module}")" \
        "$(i18n_t TUI_I18N manage_action_help)" \
        "update" "$(i18n_t TUI_I18N manage_update)" \
        "remove" "$(i18n_t TUI_I18N manage_remove)" \
        "purge"  "$(i18n_t TUI_I18N manage_purge)")" || return 0
    case "${_action}" in
        update)
            local -a _argv=()
            mapfile -t _argv < <(tui_manage_args update "${_module}")
            _tui_exec_cli "${_argv[@]}"  # never returns
            ;;
        remove | purge)
            _tui_screen_confirm_destructive "${_action}" "${_module}"
            ;;
    esac
}

# §8.3 Manage Installed: list installed modules (version + installed_at,
# data source: forked `setup_ubuntu list --installed --json`), with a
# flat ↔ group-by-TAGS[0] view toggle. State is re-forked on every loop
# pass so the list never goes stale behind an action.
_tui_screen_manage() {
    local _list_json="$1"
    while :; do
        local _state_json
        if ! _state_json="$(tui_cli_installed_json)"; then
            tui_render_msgbox "$(i18n_t TUI_I18N title_manage_installed)" \
                "$(i18n_t TUI_I18N manage_list_failed)"
            return 0
        fi

        local _mode="flat"
        [[ "${TUI_MANAGE_GROUPED}" == "true" ]] && _mode="grouped"
        local -a _rows=()
        local _name _disp
        while IFS=$'\t' read -r _name _disp; do
            _rows+=("${_name}" "${_disp}")
        done < <(tui_installed_entries "${_state_json}" "${_list_json}" "${_mode}")

        if [[ "${#_rows[@]}" -eq 0 ]]; then
            tui_render_msgbox "$(i18n_t TUI_I18N title_manage_installed)" \
                "$(i18n_t TUI_I18N manage_none_installed)"
            return 0
        fi

        local _toggle
        _toggle="$(i18n_t TUI_I18N manage_toggle_group)"
        [[ "${_mode}" == "grouped" ]] && _toggle="$(i18n_t TUI_I18N manage_toggle_flat)"
        _rows+=("view" "<< ${_toggle} >>")

        local _choice
        if ! _choice="$(TUI_CANCEL_LABEL="$(i18n_t TUI_I18N btn_back)" tui_render_menu \
            "$(i18n_t TUI_I18N title_manage_installed)" \
            "$(i18n_t TUI_I18N manage_list_help)" \
            "${_rows[@]}")"; then
            return 0  # Back / ESC → main menu
        fi
        if [[ "${_choice}" == "view" ]]; then
            if [[ "${TUI_MANAGE_GROUPED}" == "true" ]]; then
                TUI_MANAGE_GROUPED="false"
            else
                TUI_MANAGE_GROUPED="true"
            fi
            continue
        fi
        _tui_screen_manage_action "${_choice}"
    done
}

# ── Manage Secrets (#72, §8.1 item 6) ────────────────────────────────────────

# Fork setup_secrets (a standalone interactive sub-tool — it owns the
# terminal and all sensitive prompts, AC-20) and come back to the main
# menu afterwards. Unlike install/manage actions the TUI does NOT exit:
# secrets management is a side trip, not a pipeline handoff.
_tui_screen_secrets() {
    clear 2>/dev/null || printf '\033c'
    "${TUI_SECRETS}"
    local _rc=$?
    i18n_t TUI_I18N secrets_return "${_rc}"
    read -r REPLY || true
    return 0
}

# ── Menu action dispatch ─────────────────────────────────────────────────────

_tui_dispatch() {
    case "$1" in
        quick-setup)
            _tui_screen_quick_setup "$2" "$3"
            ;;
        base | recommended | optional | experimental)
            _tui_screen_category "$1" "$2"
            ;;
        run)
            _tui_screen_run
            ;;
        manage)
            _tui_screen_manage "$2"
            ;;
        secrets)
            _tui_screen_secrets
            ;;
        sysinfo)
            _tui_screen_system_info
            ;;
    esac
}

# ── Main menu loop (§8.1) ────────────────────────────────────────────────────

_tui_main_loop() {
    local _list_json _detect_json _summary
    _detect_json="$(tui_cli_detect_json)" || return 1
    _list_json="$(tui_cli_list_json)" || return 1
    _summary="$(tui_system_summary "${_detect_json}")"

    local _choice _tag _label _desc
    while :; do
        local -a _menu_args=()
        while IFS=$'\t' read -r _tag _label _desc; do
            _menu_args+=("${_tag}" "$(printf '%-22s %s' "${_label}" "${_desc}")")
        done < <(tui_main_menu_entries "${_list_json}")

        # < Exit > (relabeled Cancel) / ESC: drop the process and with it
        # every in-memory selection — zero side effects (Q43).
        _choice="$(TUI_CANCEL_LABEL="$(i18n_t TUI_I18N btn_exit)" tui_render_menu \
            "$(i18n_t TUI_I18N main_title "${INIT_UBUNTU_VERSION}")" \
            "$(i18n_t TUI_I18N main_system "${_summary}")" "${_menu_args[@]}")" || return 0
        # #169: landing on a non-selectable section separator is a no-op —
        # re-loop without dispatching any action.
        [[ "${_choice}" == "${TUI_MENU_SEPARATOR:--}" ]] && continue
        _tui_dispatch "${_choice}" "${_list_json}" "${_detect_json}"
    done
}

# ── Entry ────────────────────────────────────────────────────────────────────

main() {
    # --backend is parsed BEFORE detection (#171): a valid value forces
    # TUI_BACKEND and skips BOTH detection and the gum install prompt; an
    # invalid value is a usage error (exit 2).
    local _forced_backend=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                _tui_usage
                return 0
                ;;
            --version)
                printf 'init_ubuntu %s\n' "${INIT_UBUNTU_VERSION}"
                return 0
                ;;
            --backend)
                case "${2:-}" in
                    gum | whiptail)
                        _forced_backend="$2"
                        shift 2
                        ;;
                    *)
                        printf 'ERROR: --backend requires gum|whiptail (got %s)\n\n' \
                            "${2:-<missing>}" >&2
                        _tui_usage >&2
                        return 2
                        ;;
                esac
                ;;
            --backend=*)
                case "${1#--backend=}" in
                    gum | whiptail)
                        _forced_backend="${1#--backend=}"
                        shift
                        ;;
                    *)
                        printf 'ERROR: --backend requires gum|whiptail (got %s)\n\n' \
                            "${1#--backend=}" >&2
                        _tui_usage >&2
                        return 2
                        ;;
                esac
                ;;
            # --lang forces the UI language for this session, overriding the
            # source-time resolution (env > config > $LANG, line ~45). i18n_t
            # reads INIT_UBUNTU_LANG at render time, so setting it here (before
            # any screen draws) is enough. An invalid value is NOT a usage
            # error: i18n_sanitize_lang downgrades it to "en" with a bilingual
            # warning — same contract as the engine entrypoint (#185).
            --lang)
                shift
                export INIT_UBUNTU_LANG="${1:-en}"
                i18n_sanitize_lang INIT_UBUNTU_LANG setup_ubuntu_tui
                shift || true
                ;;
            --lang=*)
                export INIT_UBUNTU_LANG="${1#--lang=}"
                i18n_sanitize_lang INIT_UBUNTU_LANG setup_ubuntu_tui
                shift
                ;;
            *)
                printf 'ERROR: unknown flag %s\n\n' "$1" >&2
                _tui_usage >&2
                return 2
                ;;
        esac
    done

    tui_require_sudo || return $?

    # Backend resolution (#171). Precedence:
    #   1. --backend flag      → force + skip detection AND the install prompt
    #   2. pre-set TUI_BACKEND  → honor the env override (CI / harness lever)
    #   3. otherwise            → pre-launch flow (gum present, interactive
    #                             gum-install offer, or whiptail fallback)
    if [[ -n "${_forced_backend}" ]]; then
        TUI_BACKEND="${_forced_backend}"
    elif [[ -z "${TUI_BACKEND:-}" ]]; then
        TUI_BACKEND="$(_tui_prelaunch_backend)" || return $?
    fi
    export TUI_BACKEND

    # The TUI parses ADR-0019 JSON with jq. jq is a CLI self-dep
    # (lib/preflight.sh installs it on the first `setup_ubuntu` run), so
    # only a never-ran-the-CLI box hits this.
    if ! _tui_has_cmd jq; then
        printf 'ERROR: jq not found. Run any setup_ubuntu command once\n' >&2
        printf '       (its preflight offers to install jq), e.g.: setup_ubuntu list\n' >&2
        return 1
    fi

    _tui_main_loop
}

main "$@"
exit $?
