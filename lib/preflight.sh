#!/usr/bin/env bash
# lib/preflight.sh — self-deps preflight (PRD §3.4, AC-34)
#
# The tool's own machinery (state / config / detect) shells out to `jq`,
# and later phases need `curl` / `git` — but those packages ship inside
# the `apt-essentials` module. Chicken-and-egg: the entrypoint must check
# its own dependencies BEFORE dispatching anything that needs them.
#
# Behavior (PRD §3.4):
#   - missing + sudo available  → print an apt-style plan and ask ONCE
#     whether to `apt install` (automatic with -y / INIT_UBUNTU_YES=true)
#   - missing + no sudo         → fail fast, exit 4, print explicit
#     install guidance
#   - help / version            → never gated (they don't need jq)
#
# NOTE: installing the tool's own deps via apt here is allowed — this is
# NOT a module Action Phase (the "no host package installs" hard rule
# targets module install/upgrade/remove/purge).
#
# Public API:
#   preflight_self_deps <argv...>
#     argv is the untouched CLI argv (subcommand + flags). Returns:
#       0  deps satisfied / installed / not needed for this subcommand
#       1  user declined, no interactive answer, or apt install failed
#       4  deps missing and sudo unavailable (PRD §7.4)
#
# Internal probes `_preflight_has_cmd` / `_preflight_has_sudo` /
# `_preflight_apt_install` are deliberately small named functions so bats
# can override them with mocks (test/unit/preflight_spec.bats).

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# i18n_t (issue #185) lives in lib/i18n.sh. The entrypoint sources it before
# dispatching, but make this lib self-sufficient (unit specs source preflight.sh
# directly) by loading it on demand when the helper is not yet defined.
if ! declare -F i18n_t >/dev/null 2>&1; then
    # shellcheck source=lib/i18n.sh
    source "${BASH_SOURCE[0]%/*}/i18n.sh"
fi

# File-local message catalog (issue #185, Phase 2). `en.<key>` MUST stay
# byte-identical to the previous English literal (including leading spaces /
# trailing spaces). Only human-facing prompts/status go through i18n_t.
declare -gA PREFLIGHT_I18N=(
    [en.missing_deps]="[preflight] missing tool dependencies: {0}"
    [zh-TW.missing_deps]="[preflight] 缺少工具相依套件：{0}"

    [en.no_sudo_err]="[preflight] ERROR: sudo is not available; cannot install them automatically."
    [zh-TW.no_sudo_err]="[preflight] 錯誤：無法使用 sudo，因此無法自動安裝這些套件。"

    [en.no_sudo_ask]="[preflight] ask an administrator to run, then re-run this tool:"
    [zh-TW.no_sudo_ask]="[preflight] 請管理員執行下列指令後，再重新執行本工具："

    [en.no_sudo_cmd]="[preflight]   sudo apt-get install -y {0}"
    [zh-TW.no_sudo_cmd]="[preflight]   sudo apt-get install -y {0}"

    [en.apt_plan]="[preflight] the following packages will be installed via apt:"
    [zh-TW.apt_plan]="[preflight] 將透過 apt 安裝下列套件："

    [en.plan_item]="  - {0}"
    [zh-TW.plan_item]="  - {0}"

    [en.proceed]="Proceed? [Y/n] "
    [zh-TW.proceed]="是否繼續？[Y/n] "

    [en.no_answer]="[preflight] ERROR: no interactive answer; re-run with -y to auto-install"
    [zh-TW.no_answer]="[preflight] 錯誤：沒有互動式回答；請加上 -y 重新執行以自動安裝"

    [en.aborted]="[preflight] aborted by user; install manually or re-run with -y"
    [zh-TW.aborted]="[preflight] 已由使用者中止；請手動安裝或加上 -y 重新執行"

    [en.apt_failed]="[preflight] ERROR: apt install failed for: {0}"
    [zh-TW.apt_failed]="[preflight] 錯誤：apt 安裝失敗：{0}"

    [en.installed]="[preflight] installed: {0}"
    [zh-TW.installed]="[preflight] 已安裝：{0}"
)

: "${INIT_UBUNTU_YES:=false}"

# The tool's own dependencies (PRD §3.4).
PREFLIGHT_SELF_DEPS=(jq curl git)

# ── Probes (overridable in tests) ────────────────────────────────────────────

_preflight_has_cmd() {
    command -v -- "$1" >/dev/null 2>&1
}

# 0 = we can escalate (root, passwordless sudo, or interactive sudo).
_preflight_has_sudo() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        return 0
    fi
    _preflight_has_cmd sudo || return 1
    if sudo -n true 2>/dev/null; then
        return 0
    fi
    # sudo exists but wants a password — only viable when a tty can prompt.
    [[ -t 0 ]]
}

_preflight_apt_install() {
    local -a _sudo=()
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        _sudo=(sudo)
    fi
    "${_sudo[@]}" apt-get update -qq \
        && "${_sudo[@]}" apt-get install -y --no-install-recommends -- "$@"
}

# ── Gating ───────────────────────────────────────────────────────────────────

# 0 = this argv needs jq/curl/git; 1 = it doesn't (help / version paths).
# Mirrors dispatcher_dispatch's pre-subcommand handling.
_preflight_subcommand_needs_deps() {
    case "${1:-}" in
        ""|help|version|-h|--help|--version) return 1 ;;
        *) return 0 ;;
    esac
}

# Print the missing self-deps, one per line (empty output = all present).
_preflight_missing_deps() {
    local _dep
    for _dep in "${PREFLIGHT_SELF_DEPS[@]}"; do
        _preflight_has_cmd "${_dep}" || printf '%s\n' "${_dep}"
    done
    return 0
}

# ── Main entry ───────────────────────────────────────────────────────────────

preflight_self_deps() {
    # At most once per run (exported so sub-shells inherit the guard).
    if [[ "${INIT_UBUNTU_PREFLIGHT_DONE:-false}" == "true" ]]; then
        return 0
    fi

    if ! _preflight_subcommand_needs_deps "${1:-}"; then
        return 0
    fi

    local -a _missing=()
    local _line
    while IFS= read -r _line; do
        [[ -n "${_line}" ]] && _missing+=("${_line}")
    done < <(_preflight_missing_deps)

    if [[ "${#_missing[@]}" -eq 0 ]]; then
        export INIT_UBUNTU_PREFLIGHT_DONE=true
        return 0
    fi

    printf '%s\n' "$(i18n_t PREFLIGHT_I18N missing_deps "${_missing[*]}")" >&2

    if ! _preflight_has_sudo; then
        printf '%s\n' "$(i18n_t PREFLIGHT_I18N no_sudo_err)" >&2
        printf '%s\n' "$(i18n_t PREFLIGHT_I18N no_sudo_ask)" >&2
        printf '%s\n' "$(i18n_t PREFLIGHT_I18N no_sudo_cmd "${_missing[*]}")" >&2
        return 4
    fi

    # Yes-mode: env override or -y / --yes anywhere in argv.
    local _yes="${INIT_UBUNTU_YES}"
    local _arg
    for _arg in "$@"; do
        case "${_arg}" in
            -y|--yes) _yes=true ;;
        esac
    done

    if [[ "${_yes}" != "true" ]]; then
        printf '%s\n' "$(i18n_t PREFLIGHT_I18N apt_plan)"
        local _dep
        for _dep in "${_missing[@]}"; do
            printf '%s\n' "$(i18n_t PREFLIGHT_I18N plan_item "${_dep}")"
        done
        # printf the prompt ourselves: `read -p` only writes to a tty, and
        # the answer must be readable from plain stdin (pipes included).
        printf '%s' "$(i18n_t PREFLIGHT_I18N proceed)"
        local _answer=""
        if ! read -r _answer; then
            printf '\n%s\n' "$(i18n_t PREFLIGHT_I18N no_answer)" >&2
            return 1
        fi
        case "${_answer}" in
            ""|y|Y|yes|YES|Yes) ;;
            *)
                printf '%s\n' "$(i18n_t PREFLIGHT_I18N aborted)" >&2
                return 1
                ;;
        esac
    fi

    if ! _preflight_apt_install "${_missing[@]}"; then
        printf '%s\n' "$(i18n_t PREFLIGHT_I18N apt_failed "${_missing[*]}")" >&2
        return 1
    fi

    export INIT_UBUNTU_PREFLIGHT_DONE=true
    printf '%s\n' "$(i18n_t PREFLIGHT_I18N installed "${_missing[*]}")"
    return 0
}
