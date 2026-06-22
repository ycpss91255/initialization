#!/usr/bin/env bats
# test/unit/tui_secrets_menu_spec.bats — Secrets sub-menu + flows (#202)
#
# Issue #202 (doc/design/tui-uiux.md §4 / §5, G4): `Manage Secrets` opens a
# sub-menu instead of forking bare `setup_secrets` (which printed usage +
# rc2). Each flow forks a `setup_secrets <subcommand>` (the TUI is a CLI
# frontend — ADR-0019; it never sources engine libs). Non-secret args
# (name / user@host / file path) are collected via tui_render_input; secret
# VALUES + passphrases are ALWAYS prompted by setup_secrets on its own
# no-echo tty (AC-20) — never via the input widget, never in argv. Every op
# shows a plain-text result msgbox (OK / FAILED (rc=N) — NO emoji). Deletion
# danger tiers: token = single yesno; SSH key = type-to-confirm.
#
# HOST-SAFETY: every fork target is a recording mock (TUI_CLI / TUI_SECRETS /
# scripted dialog binary) — no real CLI, widget, or secrets tool is touched;
# fixtures are inline, never live state.

load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/tui_harness"

# shellcheck source=../../lib/tui_backend.sh
source "${LIB_DIR}/tui_backend.sh"

setup() {
    setup_test_env
    export LC_ALL=C.UTF-8
    unset TUI_BACKEND 2>/dev/null || true
}

teardown() {
    teardown_test_env
}

# ── e2e harness (scripted dialog + recording setup_secrets) ──────────────────
# A scripted `dialog` pops one "rc|output" response per widget invocation;
# the recording `setup_secrets` logs its argv and replays a per-subcommand
# rc/output map (SECRETS_RC_<key> / SECRETS_OUT_<key>) so the result-msgbox
# (OK / FAILED) can be exercised on both legs.

_make_secrets_harness() {
    local _widget="${1:-dialog}"
    local _dir="${INIT_UBUNTU_TEST_SCRATCH}/e2e-sec"
    rm -rf "${_dir}"
    mkdir -p "${_dir}/bin" "${_dir}/home"
    E2E_BIN="${_dir}/bin"
    E2E_HOME="${_dir}/home"
    E2E_RESPONSES="${_dir}/responses"
    E2E_WIDGET_LOG="${_dir}/widget.log"
    E2E_CLI_LOG="${_dir}/cli.log"
    E2E_SECRETS_LOG="${_dir}/secrets.log"
    E2E_WIDGET_PATH="${E2E_BIN}/${_widget}"
    export E2E_BIN E2E_HOME E2E_RESPONSES E2E_WIDGET_LOG E2E_CLI_LOG \
           E2E_SECRETS_LOG E2E_WIDGET_PATH

    tui_harness_farm "${E2E_BIN}"
    printf '%s\n' "${FIXTURE_LIST_JSON}"   >"${_dir}/list.json"
    printf '%s\n' "${FIXTURE_DETECT_JSON}" >"${_dir}/detect.json"

    cat >"${E2E_BIN}/setup_ubuntu" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${E2E_CLI_LOG}"
case "\$*" in
    "list --json")   cat "${_dir}/list.json" ;;
    "detect --json") cat "${_dir}/detect.json" ;;
esac
EOF

    # Recording setup_secrets: each invocation logs its full argv, prints any
    # canned output, and exits a canned rc. The key is the first one/two argv
    # tokens (e.g. "list", "ssh-key generate"), uppercased with non-alnum → _.
    cat >"${E2E_BIN}/setup_secrets" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${E2E_SECRETS_LOG}"
_key="\$1"
case "\$1" in
    ssh-key|token|gpg) _key="\$1_\$2" ;;
esac
_key="\${_key//[^A-Za-z0-9]/_}"
_outvar="SECRETS_OUT_\${_key}"
_rcvar="SECRETS_RC_\${_key}"
[[ -n "\${!_outvar:-}" ]] && printf '%b' "\${!_outvar}"
exit "\${!_rcvar:-0}"
EOF

    cat >"${E2E_BIN}/${_widget}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${E2E_WIDGET_LOG}"
_line="\$(head -n1 "${E2E_RESPONSES}")"
sed -i 1d "${E2E_RESPONSES}"
_rc="\${_line%%|*}"
_out="\${_line#*|}"
[[ -n "\${_out}" ]] && printf '%b' "\${_out}" >&2
exit "\${_rc}"
EOF
    chmod +x "${E2E_BIN}/setup_ubuntu" "${E2E_BIN}/setup_secrets" \
        "${E2E_BIN}/${_widget}"
}

_run_secrets_e2e() {
    run env "PATH=${E2E_BIN}" "HOME=${E2E_HOME}" \
        "TUI_CLI=${E2E_BIN}/setup_ubuntu" \
        "TUI_SECRETS=${E2E_BIN}/setup_secrets" \
        "TUI_BACKEND=${E2E_WIDGET_PATH}" \
        "$@" \
        "${REPO_ROOT}/setup_ubuntu_tui.sh" </dev/null
}

# Last logged setup_secrets ACTION argv line, skipping the read-only list
# refreshes the sub-screens fork on every loop pass to show the kind's current
# entries (PRD story 11). Those `list` / `gpg list` / `ssh-key list` lines are
# not the action under test, so they are filtered out here.
_last_secrets() {
    grep -vxE 'list|gpg list|ssh-key list' "${E2E_SECRETS_LOG}" | tail -n1
}

# ── Sub-menu structure ───────────────────────────────────────────────────────

# ADR-0025 / PRD story 10: Manage Secrets is a THREE-WAY picker (Token / GPG /
# SSH); each kind opens its own sub-screen (registry-dispatched) with that
# kind's list + actions. The flows below drill: secrets → <kind> → <action>.

@test "secrets picker: opening Manage Secrets renders the Token/GPG/SSH picker" {
    _make_secrets_harness dialog
    # secrets → (kind picker) Back → (main) Exit
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    # The picker is a --menu render carrying the three kind tags; bare
    # setup_secrets is NEVER forked.
    run cat "${E2E_WIDGET_LOG}"
    assert_output --partial "token"
    assert_output --partial "gpg"
    assert_output --partial "ssh"
    run test -f "${E2E_SECRETS_LOG}"
    assert_failure
}

@test "secrets picker: Back returns to the main menu, forks nothing" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    run test -f "${E2E_SECRETS_LOG}"
    assert_failure
}

@test "secrets picker: the three kinds dispatch through the screen registry" {
    # The three sub-screens are registered so both tiers dispatch identically.
    # Assert the registry entries are declared in the entrypoint (grep the
    # source rather than sourcing it, which would reassign REPO_ROOT in this
    # subshell and trip SC2031 on later REPO_ROOT reads).
    run grep -E '\[secrets-(token|gpg|ssh)\]=_tui_screen_secrets_(token|gpg|ssh)' \
        "${REPO_ROOT}/setup_ubuntu_tui.sh"
    assert_success
    assert_line --partial "[secrets-token]=_tui_screen_secrets_token"
    assert_line --partial "[secrets-gpg]=_tui_screen_secrets_gpg"
    assert_line --partial "[secrets-ssh]=_tui_screen_secrets_ssh"
}

# ── Token sub-screen: list / set / remove ────────────────────────────────────

@test "token sub-screen: shows the current token list inline, then actions" {
    _make_secrets_harness dialog
    # secrets → token → (action menu) Back → picker Back → exit
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|token
1|
1|
1|
EOF
    _run_secrets_e2e "SECRETS_OUT_list=gh-token\n"
    assert_success
    # Entering the token sub-screen forks `list` to show the current entries.
    run grep -c "^list$" "${E2E_SECRETS_LOG}"
    assert_output "1"
}

@test "token sub-screen: empty list renders 'none' (PRD story 11)" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|token
1|
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    # The action-menu help text carries the localized "none" placeholder.
    run cat "${E2E_WIDGET_LOG}"
    assert_output --partial "none"
}

@test "token set: input(name) → token set <name>; the VALUE is never in argv" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|token
0|set
0|gh-token
0|
1|
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    run _last_secrets
    # Exactly `token set gh-token` — no value token follows (AC-20).
    assert_output "token set gh-token"
}

@test "token set: empty name (empty submit = cancel) forks nothing destructive" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|token
0|set
0|
1|
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    run grep -c "^token set" "${E2E_SECRETS_LOG}"
    assert_failure
}

@test "token remove: pick from list → single yesno confirm → remove <name>" {
    _make_secrets_harness dialog
    # secrets → token → remove → pick name → yesno Yes → result → back → exit
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|token
0|remove
0|gh-token
0|
0|
1|
1|
1|
EOF
    _run_secrets_e2e "SECRETS_OUT_list=gh-token\nnpm-token\n"
    assert_success
    run _last_secrets
    # Token deletion forks the top-level `remove <name>` (setup_secrets has no
    # `token remove`; the canonical token delete is `remove <name>`).
    assert_output "remove gh-token"
    # A yesno (not type-to-confirm) gated the token deletion.
    run grep -c -- "--yesno" "${E2E_WIDGET_LOG}"
    assert_success
}

@test "token remove: yesno No forks nothing destructive" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|token
0|remove
0|gh-token
1|
1|
1|
1|
EOF
    _run_secrets_e2e "SECRETS_OUT_list=gh-token\n"
    assert_success
    run grep -c "^remove " "${E2E_SECRETS_LOG}"
    assert_failure
}

# ── GPG sub-screen: list / generate / import (no remove — deferred) ──────────

@test "gpg sub-screen: offers list / generate / import but NO remove (deferred)" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|gpg
1|
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    run cat "${E2E_WIDGET_LOG}"
    assert_output --partial "generate"
    assert_output --partial "import"
    # GPG deletion is deferred (setup_secrets has no gpg-delete) — no remove tag.
    refute_output --regexp $'gpg .*\tremove'
}

@test "gpg generate: forks gpg generate and shows a result msgbox" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|gpg
0|generate
0|
1|
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    run _last_secrets
    assert_output "gpg generate"
}

@test "gpg import: input(path) → gpg import <path>" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|gpg
0|import
0|/tmp/key.asc
0|
1|
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    run _last_secrets
    assert_output "gpg import /tmp/key.asc"
}

# ── SSH sub-screen: list / generate / load / copy / remove ───────────────────

@test "ssh generate: type menu default ed25519 → ssh-key generate --type ed25519" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|ssh
0|generate
0|ed25519
0|
1|
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    run _last_secrets
    assert_output "ssh-key generate --type ed25519"
}

@test "ssh generate: type menu pick rsa → ssh-key generate --type rsa" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|ssh
0|generate
0|rsa
0|
1|
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    run _last_secrets
    assert_output "ssh-key generate --type rsa"
}

@test "ssh generate: cancelling the type menu forks nothing" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|ssh
0|generate
1|
1|
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    run grep -c "^ssh-key generate" "${E2E_SECRETS_LOG}"
    assert_failure
}

@test "ssh load: forks ssh-key load and shows a result msgbox" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|ssh
0|load
0|
1|
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    run _last_secrets
    assert_output "ssh-key load"
}

@test "ssh copy: input(user@host) → ssh-key copy <user@host>" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|ssh
0|copy
0|git@example.com
0|
1|
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    run _last_secrets
    assert_output "ssh-key copy git@example.com"
    run grep -c -- "--inputbox" "${E2E_WIDGET_LOG}"
    assert_success
}

@test "ssh copy: cancelling the input forks nothing (zero side effects)" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|ssh
0|copy
1|
1|
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    run grep -c "^ssh-key copy" "${E2E_SECRETS_LOG}"
    assert_failure
}

@test "ssh remove: type-to-confirm matching the name → ssh-key remove <name> --yes" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|ssh
0|remove
0|id_ed25519
0|id_ed25519
0|
1|
1|
1|
EOF
    _run_secrets_e2e \
        "SECRETS_OUT_ssh_key_list=id_ed25519.pub: ssh-ed25519 AAAA\n"
    assert_success
    run _last_secrets
    assert_output "ssh-key remove id_ed25519 --yes"
    # Type-to-confirm uses an --inputbox (NOT a yesno) — the danger tier.
    run grep -c -- "--inputbox" "${E2E_WIDGET_LOG}"
    assert_success
}

@test "ssh remove: a non-matching type-to-confirm aborts (no remove fork)" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|ssh
0|remove
0|id_ed25519
0|WRONG-NAME
1|
1|
1|
1|
EOF
    _run_secrets_e2e \
        "SECRETS_OUT_ssh_key_list=id_ed25519.pub: ssh-ed25519 AAAA\n"
    assert_success
    run grep -c "^ssh-key remove" "${E2E_SECRETS_LOG}"
    assert_failure
}

# ── List overview (reachable from each sub-screen's "list" action) ───────────

@test "list overview: forks list + gpg list + ssh-key list into a read-only msgbox" {
    _make_secrets_harness dialog
    # secrets → token → list → msgbox → back → picker Back → exit
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|token
0|list
0|
1|
1|
1|
EOF
    _run_secrets_e2e \
        "SECRETS_OUT_list=gh-token\n" \
        "SECRETS_OUT_gpg_list=pub rsa4096/ABCD\n" \
        "SECRETS_OUT_ssh_key_list=id_ed25519.pub\n"
    assert_success
    run cat "${E2E_SECRETS_LOG}"
    assert_output --partial "gpg list"
    assert_output --partial "ssh-key list"
    run grep -c -- "--msgbox" "${E2E_WIDGET_LOG}"
    assert_success
}

# ── Result feedback (OK / FAILED) ────────────────────────────────────────────

@test "result msgbox: a failing op surfaces FAILED with the rc (plain text, no emoji)" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|ssh
0|load
0|
1|
1|
1|
EOF
    _run_secrets_e2e "SECRETS_RC_ssh_key_load=3"
    assert_success
    run cat "${E2E_WIDGET_LOG}"
    assert_output --partial "FAILED"
    assert_output --partial "3"
}

@test "result msgbox: a successful op surfaces OK (plain text)" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|ssh
0|load
0|
1|
1|
1|
EOF
    _run_secrets_e2e "SECRETS_RC_ssh_key_load=0"
    assert_success
    run cat "${E2E_WIDGET_LOG}"
    assert_output --partial "OK"
}

# ── No-emoji guarantee across the whole secrets surface ──────────────────────

@test "no-emoji: the secrets surface carries no emoji / check-cross glyphs" {
    # Repo-wide hard rule: plain text only. Grep the screen + secrets lib for the
    # common offenders (checkmark / cross / sparkles) — none allowed.
    run grep -nP '[\x{2705}\x{274C}\x{2714}\x{2716}\x{2728}\x{1F500}-\x{1FAFF}]' \
        "${REPO_ROOT}/setup_ubuntu_tui.sh" "${REPO_ROOT}/lib/tui_secrets.sh"
    assert_failure
}

# ── token get is excluded from the TUI surface ───────────────────────────────

@test "token get: never appears as a secrets sub-menu action (shoulder-surfing)" {
    # `token get` would print the secret value on screen — it must not be a
    # forkable action anywhere in the TUI.
    run grep -rn "token get" \
        "${REPO_ROOT}/setup_ubuntu_tui.sh" "${REPO_ROOT}/lib/tui_secrets.sh"
    assert_failure
}
