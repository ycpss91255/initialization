#!/usr/bin/env bash
# lib/i18n.sh — locale detection + validation.
#
# Provides:
#   i18n_detect_lang             # reads $LANG, prints one of {en, zh-TW, zh-CN, ja}
#   i18n_sanitize_lang <outvar>  # validates outvar value; if invalid, set to "en" + bilingual warn

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf "Warn: %s is a library, not an executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

i18n_detect_lang() {
    case "${LANG:-}" in
        zh_TW*)         printf 'zh-TW' ;;
        zh_CN*|zh_SG*)  printf 'zh-CN' ;;
        ja*)            printf 'ja' ;;
        *)              printf 'en' ;;
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

i18n_sanitize_lang() {
    local -n _sl_ref="${1:?i18n_sanitize_lang requires <outvar>}"
    local _who="${2:-i18n}"
    case "${_sl_ref}" in
        en|zh-TW|zh-CN|ja) return 0 ;;
    esac
    # Detect sys locale fresh (cannot trust the invalid _sl_ref value).
    local _sys_lang; _sys_lang="$(i18n_detect_lang)"
    case "${_sys_lang}" in
        zh-TW)
            printf '[%s] 警告:不支援的 lang 值 %q,改用 "en"\n' "${_who}" "${_sl_ref}" >&2
            printf '[%s]       可用值:en | zh-TW | zh-CN | ja\n' "${_who}" >&2
            ;;
        zh-CN)
            printf '[%s] 警告:不支持的 lang 值 %q,改用 "en"\n' "${_who}" "${_sl_ref}" >&2
            printf '[%s]       可用值:en | zh-TW | zh-CN | ja\n' "${_who}" >&2
            ;;
        ja)
            printf '[%s] 警告: サポート外の lang 値 %q, "en" にフォールバックします\n' "${_who}" "${_sl_ref}" >&2
            printf '[%s]       利用可能: en | zh-TW | zh-CN | ja\n' "${_who}" >&2
            ;;
        *)
            printf '[%s] WARNING: unsupported lang %q, falling back to "en"\n' "${_who}" "${_sl_ref}" >&2
            printf '[%s]          allowed: en | zh-TW | zh-CN | ja\n' "${_who}" >&2
            ;;
    esac
    _sl_ref="en"
}
