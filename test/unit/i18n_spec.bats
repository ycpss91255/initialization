#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031  # bats `run` spawns a subshell; test setups `export LANG=...` before `run` to stage the env for i18n_detect_lang — https://www.shellcheck.net/wiki/SC2030
# test/unit/i18n_spec.bats — lib/i18n.sh

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    unset LANG INIT_UBUNTU_LANG
    # shellcheck source=../../lib/i18n.sh
    source "${LIB_DIR}/i18n.sh"
}

teardown() {
    teardown_test_env
}

# ─── i18n_detect_lang ────────────────────────────────────────────────────────

@test "i18n_detect_lang returns 'zh-TW' when LANG=zh_TW.UTF-8" {
    export LANG="zh_TW.UTF-8"
    run i18n_detect_lang
    [[ "${status}" -eq 0 ]]
    [[ "${output}" == "zh-TW" ]]
}

# 0.1.0 supports en + zh-TW only (#205): unsupported locales auto-detect to en
# silently (zh-CN / ja translations deferred to #208).
@test "i18n_detect_lang returns 'en' for zh_CN (unsupported in 0.1.0)" {
    export LANG="zh_CN.UTF-8"
    run i18n_detect_lang
    [[ "${status}" -eq 0 ]]
    [[ "${output}" == "en" ]]
}

@test "i18n_detect_lang returns 'en' for ja (unsupported in 0.1.0)" {
    export LANG="ja_JP.UTF-8"
    run i18n_detect_lang
    [[ "${status}" -eq 0 ]]
    [[ "${output}" == "en" ]]
}

@test "i18n_detect_lang returns 'en' for unrecognized LANG" {
    export LANG="fr_FR.UTF-8"
    run i18n_detect_lang
    [[ "${status}" -eq 0 ]]
    [[ "${output}" == "en" ]]
}

@test "i18n_detect_lang returns 'en' when LANG is unset" {
    unset LANG
    run i18n_detect_lang
    [[ "${status}" -eq 0 ]]
    [[ "${output}" == "en" ]]
}

# ─── i18n_sanitize_lang ──────────────────────────────────────────────────────

@test "i18n_sanitize_lang keeps valid 'en' unchanged" {
    local _lang="en"
    i18n_sanitize_lang _lang
    [[ "${_lang}" == "en" ]]
}

@test "i18n_sanitize_lang keeps valid 'zh-TW' unchanged" {
    local _lang="zh-TW"
    i18n_sanitize_lang _lang
    [[ "${_lang}" == "zh-TW" ]]
}

@test "i18n_sanitize_lang downgrades zh-CN to 'en' (unsupported in 0.1.0)" {
    local _lang="zh-CN"
    i18n_sanitize_lang _lang 2>/dev/null
    [[ "${_lang}" == "en" ]]
}

@test "i18n_sanitize_lang downgrades ja to 'en' (unsupported in 0.1.0)" {
    local _lang="ja"
    i18n_sanitize_lang _lang 2>/dev/null
    [[ "${_lang}" == "en" ]]
}

@test "i18n_sanitize_lang warns and falls back when given zh-CN" {
    local _lang="zh-CN"
    run i18n_sanitize_lang _lang
    [[ "${output}" == *"en | zh-TW"* ]]
}

@test "i18n_sanitize_lang replaces invalid value with 'en'" {
    local _lang="fr"
    i18n_sanitize_lang _lang 2>/dev/null
    [[ "${_lang}" == "en" ]]
}

@test "i18n_sanitize_lang prints warning to stderr on invalid value" {
    local _lang="bogus"
    run --separate-stderr bash -c '
        source "'"${LIB_DIR}"'/i18n.sh"
        _l="bogus"
        i18n_sanitize_lang _l
    '
    [[ "${status}" -eq 0 ]]
    [[ -n "${stderr}" ]]
    [[ "${stderr}" == *"bogus"* ]]
}

@test "i18n_sanitize_lang warning uses zh-TW phrasing when system LANG=zh_TW.UTF-8" {
    run --separate-stderr bash -c '
        export LANG="zh_TW.UTF-8"
        source "'"${LIB_DIR}"'/i18n.sh"
        _l="bogus"
        i18n_sanitize_lang _l
    '
    [[ "${status}" -eq 0 ]]
    [[ "${stderr}" == *"警告"* ]]
}

# ─── i18n_resolve_init_ubuntu_lang ───────────────────────────────────────────

@test "i18n_resolve_init_ubuntu_lang honors explicit INIT_UBUNTU_LANG" {
    export INIT_UBUNTU_LANG="zh-TW"
    export LANG="en_US.UTF-8"   # would auto-detect to en if env didn't win
    i18n_resolve_init_ubuntu_lang
    [[ "${INIT_UBUNTU_LANG}" == "zh-TW" ]]
}

@test "i18n_resolve_init_ubuntu_lang auto-detects from \$LANG when env unset" {
    unset INIT_UBUNTU_LANG
    export LANG="zh_TW.UTF-8"
    i18n_resolve_init_ubuntu_lang
    [[ "${INIT_UBUNTU_LANG}" == "zh-TW" ]]
}

@test "i18n_resolve_init_ubuntu_lang uses config_get when env unset (beats auto)" {
    unset INIT_UBUNTU_LANG
    export LANG="en_US.UTF-8"   # auto would say en
    config_get() {
        [[ "$1" == "ui.lang" ]] && { printf 'zh-TW'; return 0; }
        return 1
    }
    i18n_resolve_init_ubuntu_lang
    [[ "${INIT_UBUNTU_LANG}" == "zh-TW" ]]
}

# ─── i18n_t (engine-string lookup, issue #185) ───────────────────────────────

@test "i18n_t returns the zh-TW value when INIT_UBUNTU_LANG=zh-TW" {
    declare -gA _T_MSG=([en.hi]="Hello" [zh-TW.hi]="你好")
    INIT_UBUNTU_LANG=zh-TW run i18n_t _T_MSG hi
    [[ "${status}" -eq 0 ]]
    [[ "${output}" == "你好" ]]
}

@test "i18n_t returns the en value by default" {
    declare -gA _T_MSG=([en.hi]="Hello" [zh-TW.hi]="你好")
    INIT_UBUNTU_LANG=en run i18n_t _T_MSG hi
    [[ "${output}" == "Hello" ]]
}

@test "i18n_t falls back to en when the lang has no translation" {
    declare -gA _T_MSG=([en.only]="EnglishOnly")
    INIT_UBUNTU_LANG=zh-TW run i18n_t _T_MSG only
    [[ "${output}" == "EnglishOnly" ]]
}

@test "i18n_t falls back to the literal key when no translation exists at all" {
    declare -gA _T_MSG=([en.hi]="Hello")
    INIT_UBUNTU_LANG=zh-TW run i18n_t _T_MSG missingkey
    [[ "${output}" == "missingkey" ]]
}

@test "i18n_t substitutes positional placeholders {0} {1}" {
    declare -gA _T_MSG=([en.inst]="installed {0} in {1}s" [zh-TW.inst]="已安裝 {0},耗時 {1} 秒")
    INIT_UBUNTU_LANG=zh-TW run i18n_t _T_MSG inst neovim 9
    [[ "${output}" == "已安裝 neovim,耗時 9 秒" ]]
}

@test "i18n_t prints no trailing newline" {
    declare -gA _T_MSG=([en.hi]="Hello")
    run i18n_t _T_MSG hi
    [[ "${#output}" -eq 5 ]]
}
