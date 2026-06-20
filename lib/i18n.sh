#!/usr/bin/env bash
# lib/i18n.sh — locale detection + validation.
#
# Provides:
#   i18n_detect_lang             # reads $LANG, prints one of {en, zh-TW}
#   i18n_sanitize_lang <outvar>  # validates outvar value; if invalid, set to "en" + bilingual warn

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not an executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

i18n_detect_lang() {
    # 0.1.0 ships en + zh-TW only (#205). Unsupported locales (zh-CN, ja, ...)
    # resolve to en silently on auto-detect — the warning is reserved for an
    # explicit `--lang` of an unsupported value (see i18n_sanitize_lang). zh-CN
    # / ja translations are deferred to 0.2.0 (#208).
    case "${LANG:-}" in
        zh_TW*) printf 'zh-TW' ;;
        *)      printf 'en' ;;
    esac
}

# i18n_sanitize_lang <outvar>
#   Validate the value in <outvar> against the supported-lang whitelist.
#   On invalid value, set <outvar> to "en" and print a bilingual warning to stderr.
# i18n_resolve_init_ubuntu_lang
#   Set/export INIT_UBUNTU_LANG using priority:
#     1. If INIT_UBUNTU_LANG is already non-empty -> keep (honor explicit env).
#     2. If `config_get` is available + 'ui.lang' is set -> use that.
#     3. Fall back to i18n_detect_lang($LANG).
#   Sanitize the final value (typo => "en" with bilingual warning).
i18n_resolve_init_ubuntu_lang() {
    if [[ -z "${INIT_UBUNTU_LANG:-}" ]]; then
        if declare -F config_get >/dev/null 2>&1; then
            INIT_UBUNTU_LANG="$(config_get ui.lang 2>/dev/null)"
        fi
    fi
    if [[ -z "${INIT_UBUNTU_LANG:-}" ]]; then
        INIT_UBUNTU_LANG="$(i18n_detect_lang)"
    fi
    export INIT_UBUNTU_LANG
    i18n_sanitize_lang INIT_UBUNTU_LANG
}

# i18n_t <table-name> <key> [arg0 arg1 ...]
#   Generic engine-string lookup (issue #185). <table-name> is a `declare -gA`
#   keyed "<lang>.<msgkey>" (e.g. [en.proceed]="Proceed? [Y/n] "
#   [zh-TW.proceed]="是否繼續? [Y/n] "). Resolution order:
#     ${INIT_UBUNTU_LANG}.<key>  ->  en.<key>  ->  the literal <key>.
#   Positional placeholders {0} {1} ... are substituted from the trailing args
#   via parameter expansion (NOT printf) — the format never comes from a
#   variable, so no SC2059 / no shellcheck-disable. Prints to stdout with no
#   trailing newline (callers add their own). Logs (log_*) stay English; only
#   user-facing stdout/TUI strings use this.
i18n_t() {
    local _tbl="${1:?i18n_t requires <table-name>}"
    local _key="${2:?i18n_t requires <key>}"
    shift 2
    local -n _t_ref="${_tbl}"
    local _lang="${INIT_UBUNTU_LANG:-en}"
    local _s="${_t_ref["${_lang}.${_key}"]:-${_t_ref["en.${_key}"]:-${_key}}}"
    local _i=0 _arg
    for _arg in "$@"; do
        _s="${_s//\{${_i}\}/${_arg}}"
        _i=$((_i + 1))
    done
    printf '%s' "${_s}"
}

i18n_sanitize_lang() {
    local -n _sl_ref="${1:?i18n_sanitize_lang requires <outvar>}"
    local _who="${2:-i18n}"
    # 0.1.0 supported set: en + zh-TW only (#205). zh-CN / ja are deferred
    # (#208) — an explicit unsupported --lang falls back to en with a warning.
    case "${_sl_ref}" in
        en|zh-TW) return 0 ;;
    esac
    # Detect sys locale fresh (cannot trust the invalid _sl_ref value) to pick
    # the warning's language. Only en / zh-TW are possible now.
    local _sys_lang; _sys_lang="$(i18n_detect_lang)"
    case "${_sys_lang}" in
        zh-TW)
            printf '[%s] 警告:不支援的 lang 值 %q,改用 "en"\n' "${_who}" "${_sl_ref}" >&2
            printf '[%s]       可用值:en | zh-TW\n' "${_who}" >&2
            ;;
        *)
            printf '[%s] WARNING: unsupported lang %q, falling back to "en"\n' "${_who}" "${_sl_ref}" >&2
            printf '[%s]          allowed: en | zh-TW\n' "${_who}" >&2
            ;;
    esac
    _sl_ref="en"
}
