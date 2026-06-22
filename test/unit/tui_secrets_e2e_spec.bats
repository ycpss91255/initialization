#!/usr/bin/env bats
# test/unit/tui_secrets_e2e_spec.bats — in-process body coverage for the
# Manage Secrets screens (lib/tui_secrets.sh, ADR-0025 / PRD stories 10-13).
#
# WHY a second secrets spec: tui_secrets_menu_spec.bats drives the screens by
# FORKING setup_ubuntu_tui.sh through the scripted-widget harness — great for
# the argv-level / dual-backend assertions, but the screen-body lines run in
# command-substitution grandchild subshells of the forked entrypoint, which the
# coverage tracer does not always attribute back to lib/tui_secrets.sh.
#
# This spec sources lib/tui_secrets.sh DIRECTLY and replaces the backend render
# wrappers (tui_render_menu / input / msgbox / yesno) + i18n_t + the registry
# dispatcher with in-process shell stubs. Every screen/flow body therefore runs
# in the SAME process as bats, so each menu-open, list-render branch, and
# CLI-fork dispatch line is exercised in-process. The forked subprocess here is
# ONLY the recording mock setup_secrets (TUI_SECRETS) — no real secrets tool,
# widget, or CLI is touched; all inputs are inline.
#
# Stub contract (mirrors the live wrappers' rc semantics):
#   tui_render_menu  : pops one line from STUB_RESPONSES; "RC|tag" — prints tag
#                      on stdout when rc 0, returns rc (nonzero = cancel/Back).
#   tui_render_input : same popper; "RC|text" — prints text, returns rc.
#   tui_render_yesno : same popper; "RC|" — rc 0 = Yes, nonzero = No.
#   tui_render_msgbox: records its (title,text) to STUB_MSGBOX_LOG, rc 0.
#   i18n_t           : echoes "<key> <args...>" so help/title text is non-empty
#                      and deterministic (the screens only need NON-empty here).

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    setup_test_env
    export LC_ALL=C.UTF-8

    STUB_RESPONSES="${INIT_UBUNTU_TEST_SCRATCH}/responses"
    STUB_MSGBOX_LOG="${INIT_UBUNTU_TEST_SCRATCH}/msgbox.log"
    SECRETS_LOG="${INIT_UBUNTU_TEST_SCRATCH}/secrets.log"
    mkdir -p "${INIT_UBUNTU_TEST_SCRATCH}"
    : >"${STUB_RESPONSES}"
    : >"${STUB_MSGBOX_LOG}"
    : >"${SECRETS_LOG}"
    # SECRETS_LOG is read by the forked mock setup_secrets; STUB_* are read by
    # the in-process stubs (which `run` inherits) — export so both layers see
    # the same paths regardless of subshell depth.
    export STUB_RESPONSES STUB_MSGBOX_LOG SECRETS_LOG

    # Recording mock setup_secrets: logs full argv, replays a per-key rc/output
    # map (SECRETS_OUT_<key> / SECRETS_RC_<key>) so both result-msgbox legs and
    # the list-render branches can be driven from a test.
    _make_secrets_mock
    TUI_SECRETS="${INIT_UBUNTU_TEST_SCRATCH}/setup_secrets"
    export TUI_SECRETS

    # The in-process render stubs (i18n_t / tui_render_* / _tui_invoke_screen)
    # are file-scope functions, already defined before this lib is sourced — so
    # the `declare -F tui_render_menu` guard (tui_secrets.sh) is satisfied and
    # the standalone tui_backend.sh source is skipped.
    # shellcheck source=../../lib/tui_secrets.sh
    source "${LIB_DIR}/tui_secrets.sh"
}

teardown() {
    teardown_test_env
}

_make_secrets_mock() {
    cat >"${INIT_UBUNTU_TEST_SCRATCH}/setup_secrets" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SECRETS_LOG}"
_key="$1"
case "$1" in
    ssh-key|token|gpg) _key="$1_$2" ;;
esac
_key="${_key//[^A-Za-z0-9]/_}"
_outvar="SECRETS_OUT_${_key}"
_rcvar="SECRETS_RC_${_key}"
[[ -n "${!_outvar:-}" ]] && printf '%b' "${!_outvar}"
exit "${!_rcvar:-0}"
EOF
    chmod +x "${INIT_UBUNTU_TEST_SCRATCH}/setup_secrets"
}

# ── In-process backend stubs (file scope; invoked indirectly by the lib) ──────
# These replace the real tui_backend.sh wrappers + i18n_t + the entrypoint's
# registry dispatcher so the screen bodies run in THIS process. They are called
# only through lib/tui_secrets.sh (indirect), hence defined at file scope so the
# linter's reachability analysis does not flag them as dead code.

# i18n_t stub: $1 = table name (ignored), $2 = key, rest = args. Echoes
# "<key> <args...>" so titles/help are deterministic and non-empty.
i18n_t() { shift; printf '%s' "$*"; }

# Shared response popper: reads one "RC|payload" line, prints the payload, and
# returns RC (nonzero = cancel/Back), mirroring the live widget rc contract.
_stub_pop() {
    local _line _rc _out
    _line="$(head -n1 "${STUB_RESPONSES}")"
    sed -i 1d "${STUB_RESPONSES}"
    _rc="${_line%%|*}"
    _out="${_line#*|}"
    [[ -n "${_out}" ]] && printf '%s' "${_out}"
    return "${_rc}"
}

# Menu/input/yesno share the popper; trailing rows/prompt args are ignored
# (the response file drives the interaction).
tui_render_menu() { _stub_pop; }
tui_render_input() { _stub_pop; }
tui_render_yesno() { _stub_pop; }
tui_render_msgbox() { printf '%s\t%s\n' "$1" "$2" >>"${STUB_MSGBOX_LOG}"; }

# Registry dispatcher: route the three sub-screen tokens to their handlers
# exactly like the entrypoint's _tui_invoke_screen, so the picker drives the
# real sub-screen bodies in-process.
_tui_invoke_screen() {
    case "$1" in
        secrets-token) _tui_screen_secrets_token "" ;;
        secrets-gpg)   _tui_screen_secrets_gpg "" ;;
        secrets-ssh)   _tui_screen_secrets_ssh "" ;;
    esac
}

_queue() { printf '%s\n' "$@" >"${STUB_RESPONSES}"; }
_last_action() { grep -vxE 'list|gpg list|ssh-key list' "${SECRETS_LOG}" | tail -n1; }

# ── Three-way picker dispatch (lib lines 282-294) ────────────────────────────

@test "in-proc picker: token kind opens the token sub-screen then Back to main" {
    # picker:token -> token-screen:Back -> picker:Back
    _queue "0|token" "1|" "1|"
    run _tui_screen_secrets
    assert_success
    # The token sub-screen forked `list` once to render its inline current list.
    run grep -c '^list$' "${SECRETS_LOG}"
    assert_output "1"
}

@test "in-proc picker: gpg kind opens the gpg sub-screen then Back to main" {
    _queue "0|gpg" "1|" "1|"
    run _tui_screen_secrets
    assert_success
    run grep -c '^gpg list$' "${SECRETS_LOG}"
    assert_output "1"
}

@test "in-proc picker: ssh kind opens the ssh sub-screen then Back to main" {
    _queue "0|ssh" "1|" "1|"
    run _tui_screen_secrets
    assert_success
    run grep -c '^ssh-key list$' "${SECRETS_LOG}"
    assert_output "1"
}

@test "in-proc picker: Back on the kind picker forks nothing" {
    _queue "1|"
    run _tui_screen_secrets
    assert_success
    run grep -c . "${SECRETS_LOG}"
    assert_output "0"
}

# ── Token sub-screen bodies (lib lines 219-228, 100-105, 137-153) ────────────

@test "in-proc token: list action forks the read-only overview" {
    SECRETS_OUT_list=$'gh-token\n'
    SECRETS_OUT_gpg_list=$'pub rsa\n'
    SECRETS_OUT_ssh_key_list=$'id_ed25519.pub: x\n'
    export SECRETS_OUT_list SECRETS_OUT_gpg_list SECRETS_OUT_ssh_key_list
    _queue "0|list" "1|"
    run _tui_screen_secrets_token ""
    assert_success
    run grep -c '^gpg list$' "${SECRETS_LOG}"
    assert_output "1"
    run grep -c '^ssh-key list$' "${SECRETS_LOG}"
    assert_output "1"
}

@test "in-proc token set: only the NAME reaches argv (AC-20), result OK msgbox" {
    _queue "0|set" "0|gh-token" "1|"
    run _tui_screen_secrets_token ""
    assert_success
    run _last_action
    assert_output "token set gh-token"
    run cat "${STUB_MSGBOX_LOG}"
    assert_output --partial "secrets_result_ok"
}

@test "in-proc token set: cancelling the name input forks nothing destructive" {
    _queue "0|set" "1|" "1|"
    run _tui_screen_secrets_token ""
    assert_success
    run grep -c '^token set' "${SECRETS_LOG}"
    assert_output "0"
}

@test "in-proc token remove: pick + yesno Yes -> remove <name> (lib 144-153)" {
    SECRETS_OUT_list=$'gh-token\nnpm-token\n'
    export SECRETS_OUT_list
    _queue "0|remove" "0|gh-token" "0|" "1|"
    run _tui_screen_secrets_token ""
    assert_success
    run _last_action
    assert_output "remove gh-token"
}

@test "in-proc token remove: yesno No aborts the deletion fork" {
    SECRETS_OUT_list=$'gh-token\n'
    export SECRETS_OUT_list
    _queue "0|remove" "0|gh-token" "1|" "1|"
    run _tui_screen_secrets_token ""
    assert_success
    run grep -c '^remove ' "${SECRETS_LOG}"
    assert_output "0"
}

@test "in-proc token remove: empty list shows the 'none' msgbox (lib 146-149)" {
    # list returns nothing -> pick rc1 with empty names -> none-msgbox branch.
    _queue "0|remove" "1|"
    run _tui_screen_secrets_token ""
    assert_success
    run cat "${STUB_MSGBOX_LOG}"
    assert_output --partial "secrets_none_tokens"
    run grep -c '^remove ' "${SECRETS_LOG}"
    assert_output "0"
}

@test "in-proc token remove: list fork failure shows the list-failed msgbox (lib 139-142)" {
    SECRETS_RC_list=4
    export SECRETS_RC_list
    _queue "0|remove" "1|"
    run _tui_screen_secrets_token ""
    assert_success
    run cat "${STUB_MSGBOX_LOG}"
    assert_output --partial "secrets_list_failed"
}

# ── GPG sub-screen bodies (lib lines 238-247, 109-114) ───────────────────────

@test "in-proc gpg generate: forks gpg generate + result msgbox (lib 246)" {
    _queue "0|generate" "1|"
    run _tui_screen_secrets_gpg ""
    assert_success
    run _last_action
    assert_output "gpg generate"
}

@test "in-proc gpg import: input(path) -> gpg import <path> (lib 109-114)" {
    _queue "0|import" "0|/tmp/key.asc" "1|"
    run _tui_screen_secrets_gpg ""
    assert_success
    run _last_action
    assert_output "gpg import /tmp/key.asc"
}

@test "in-proc gpg import: cancelling the path input forks nothing" {
    _queue "0|import" "1|" "1|"
    run _tui_screen_secrets_gpg ""
    assert_success
    run grep -c '^gpg import' "${SECRETS_LOG}"
    assert_output "0"
}

@test "in-proc gpg: list action forks the overview" {
    _queue "0|list" "1|"
    run _tui_screen_secrets_gpg ""
    assert_success
    run grep -c '^gpg list$' "${SECRETS_LOG}"
    # one inline-list refresh per loop pass (2) + one overview fork = 3.
    assert_output "3"
}

# ── SSH sub-screen bodies (lib lines 256-269, 76-96, 159-187) ────────────────

@test "in-proc ssh generate: default ed25519 -> ssh-key generate --type ed25519" {
    _queue "0|generate" "0|ed25519" "1|"
    run _tui_screen_secrets_ssh ""
    assert_success
    run _last_action
    assert_output "ssh-key generate --type ed25519"
}

@test "in-proc ssh generate: cancelling the type menu forks nothing (lib 83)" {
    _queue "0|generate" "1|" "1|"
    run _tui_screen_secrets_ssh ""
    assert_success
    run grep -c '^ssh-key generate' "${SECRETS_LOG}"
    assert_output "0"
}

@test "in-proc ssh: list action forks the overview (lib 265)" {
    _queue "0|list" "1|"
    run _tui_screen_secrets_ssh ""
    assert_success
    # The overview forks `list` + `gpg list` + `ssh-key list`; assert the
    # token + gpg legs (the ssh-key list line also fires for the inline list).
    run grep -c '^gpg list$' "${SECRETS_LOG}"
    assert_output "1"
}

@test "in-proc ssh load: forks ssh-key load (lib 267)" {
    _queue "0|load" "1|"
    run _tui_screen_secrets_ssh ""
    assert_success
    run _last_action
    assert_output "ssh-key load"
}

@test "in-proc ssh load: a failing op surfaces FAILED + rc (lib 54-56)" {
    SECRETS_RC_ssh_key_load=3
    export SECRETS_RC_ssh_key_load
    _queue "0|load" "1|"
    run _tui_screen_secrets_ssh ""
    assert_success
    run cat "${STUB_MSGBOX_LOG}"
    assert_output --partial "secrets_result_fail"
    assert_output --partial "3"
}

@test "in-proc ssh copy: input(user@host) -> ssh-key copy <target> (lib 90-96)" {
    _queue "0|copy" "0|git@example.com" "1|"
    run _tui_screen_secrets_ssh ""
    assert_success
    run _last_action
    assert_output "ssh-key copy git@example.com"
}

@test "in-proc ssh copy: cancelling the input forks nothing" {
    _queue "0|copy" "1|" "1|"
    run _tui_screen_secrets_ssh ""
    assert_success
    run grep -c '^ssh-key copy' "${SECRETS_LOG}"
    assert_output "0"
}

@test "in-proc ssh remove: type-to-confirm match -> ssh-key remove <name> --yes (lib 159-174)" {
    # ssh-key list emits "<path>.pub: <key>"; _tui_secrets_ssh_names awk-parses
    # the basename (lib 181-186). Two distinct keys exercise the row loop.
    SECRETS_OUT_ssh_key_list=$'/home/u/.ssh/id_ed25519.pub: ssh-ed25519 AAAA\n/home/u/.ssh/id_rsa.pub: ssh-rsa BBBB\nagent identities:\nskip-me\n'
    export SECRETS_OUT_ssh_key_list
    _queue "0|remove" "0|id_ed25519" "0|id_ed25519" "1|"
    run _tui_screen_secrets_ssh ""
    assert_success
    run _last_action
    assert_output "ssh-key remove id_ed25519 --yes"
}

@test "in-proc ssh remove: a non-matching type-to-confirm aborts (lib 172)" {
    SECRETS_OUT_ssh_key_list=$'/home/u/.ssh/id_ed25519.pub: ssh-ed25519 AAAA\n'
    export SECRETS_OUT_ssh_key_list
    _queue "0|remove" "0|id_ed25519" "0|WRONG" "1|"
    run _tui_screen_secrets_ssh ""
    assert_success
    run grep -c '^ssh-key remove' "${SECRETS_LOG}"
    assert_output "0"
}

@test "in-proc ssh remove: empty key list shows the 'none' msgbox (lib 162-167)" {
    _queue "0|remove" "1|"
    run _tui_screen_secrets_ssh ""
    assert_success
    run cat "${STUB_MSGBOX_LOG}"
    assert_output --partial "secrets_none_ssh"
}

# ── Inline kind-list render: populated vs "none" (lib 195-207) ────────────────

@test "in-proc kind-list: populated token list renders the names verbatim" {
    SECRETS_OUT_list=$'gh-token\nnpm-token\n'
    export SECRETS_OUT_list
    run _tui_secrets_kind_list token
    assert_success
    assert_output --partial "gh-token"
    assert_output --partial "npm-token"
}

@test "in-proc kind-list: empty token list renders the localized 'none'" {
    run _tui_secrets_kind_list token
    assert_success
    assert_output "secrets_none"
}

@test "in-proc kind-list: empty ssh list renders 'none' (awk path, lib 200)" {
    run _tui_secrets_kind_list ssh
    assert_success
    assert_output "secrets_none"
}
