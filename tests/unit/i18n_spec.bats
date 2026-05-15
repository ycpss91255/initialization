#!/usr/bin/env bats
# tests/unit/i18n_spec.bats — lib/i18n.sh

load "${BATS_TEST_DIRNAME}/../helpers/common"

setup() {
    setup_test_env
    unset LANG INIT_UBUNTU_LANG
    # shellcheck disable=SC1091
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

@test "i18n_detect_lang returns 'zh-CN' when LANG=zh_CN.UTF-8" {
    export LANG="zh_CN.UTF-8"
    run i18n_detect_lang
    [[ "${status}" -eq 0 ]]
    [[ "${output}" == "zh-CN" ]]
}

@test "i18n_detect_lang returns 'ja' when LANG=ja_JP.UTF-8" {
    export LANG="ja_JP.UTF-8"
    run i18n_detect_lang
    [[ "${status}" -eq 0 ]]
    [[ "${output}" == "ja" ]]
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

@test "i18n_sanitize_lang keeps valid 'zh-CN' unchanged" {
    local _lang="zh-CN"
    i18n_sanitize_lang _lang
    [[ "${_lang}" == "zh-CN" ]]
}

@test "i18n_sanitize_lang keeps valid 'ja' unchanged" {
    local _lang="ja"
    i18n_sanitize_lang _lang
    [[ "${_lang}" == "ja" ]]
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
    export INIT_UBUNTU_LANG="ja"
    export LANG="zh_TW.UTF-8"   # would auto-detect to zh-TW if env didn't win
    i18n_resolve_init_ubuntu_lang
    [[ "${INIT_UBUNTU_LANG}" == "ja" ]]
}

@test "i18n_resolve_init_ubuntu_lang auto-detects from \$LANG when env unset" {
    unset INIT_UBUNTU_LANG
    export LANG="zh_TW.UTF-8"
    i18n_resolve_init_ubuntu_lang
    [[ "${INIT_UBUNTU_LANG}" == "zh-TW" ]]
}

@test "i18n_resolve_init_ubuntu_lang uses config_get when env unset (beats auto)" {
    unset INIT_UBUNTU_LANG
    export LANG="zh_TW.UTF-8"   # auto would say zh-TW
    config_get() {
        [[ "$1" == "ui.lang" ]] && { printf 'zh-CN'; return 0; }
        return 1
    }
    i18n_resolve_init_ubuntu_lang
    [[ "${INIT_UBUNTU_LANG}" == "zh-CN" ]]
}
