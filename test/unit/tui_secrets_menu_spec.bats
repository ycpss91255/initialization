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

# Last logged setup_secrets argv line.
_last_secrets() { tail -n1 "${E2E_SECRETS_LOG}"; }

# ── Sub-menu structure ───────────────────────────────────────────────────────

@test "secrets sub-menu: opening Manage Secrets renders a menu (not a bare fork)" {
    _make_secrets_harness dialog
    # secrets → (sub-menu) Back → (main) Exit
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    # The sub-menu is a --menu render; bare setup_secrets is NEVER forked.
    run grep -c -- "--menu" "${E2E_WIDGET_LOG}"
    # main menu (1) + secrets sub-menu (1) + main menu again (1) = 3 menus
    assert_output "3"
    run test -f "${E2E_SECRETS_LOG}"
    assert_failure
}

@test "secrets sub-menu: Back returns to the main menu, forks nothing" {
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

# ── 1. List existing secrets (read-only overview) ────────────────────────────

@test "list overview: forks list + gpg list + ssh-key list into a read-only msgbox" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|list
0|
1|
1|
EOF
    _run_secrets_e2e \
        "SECRETS_OUT_list=gh-token\n" \
        "SECRETS_OUT_gpg_list=pub rsa4096/ABCD\n" \
        "SECRETS_OUT_ssh_key_list=id_ed25519.pub\n"
    assert_success
    run cat "${E2E_SECRETS_LOG}"
    assert_line --index 0 "list"
    assert_line --index 1 "gpg list"
    assert_line --index 2 "ssh-key list"
    # The combined output reached a --msgbox (read-only).
    run grep -c -- "--msgbox" "${E2E_WIDGET_LOG}"
    assert_success
}

# ── 2. Generate SSH key (type menu) ──────────────────────────────────────────

@test "ssh generate: type menu default ed25519 → ssh-key generate --type ed25519" {
    _make_secrets_harness dialog
    # secrets → generate-ssh → type menu pick ed25519 → result OK → back → exit
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|ssh-gen
0|ed25519
0|
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
0|ssh-gen
0|rsa
0|
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
0|ssh-gen
1|
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    run test -f "${E2E_SECRETS_LOG}"
    assert_failure
}

# ── 3. Load SSH key to agent ─────────────────────────────────────────────────

@test "ssh load: forks ssh-key load and shows a result msgbox" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|ssh-load
0|
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    run _last_secrets
    assert_output "ssh-key load"
}

# ── 4. Copy SSH public key to remote (input user@host) ───────────────────────

@test "ssh copy: input(user@host) → ssh-key copy <user@host>" {
    _make_secrets_harness dialog
    # secrets → copy-ssh → input box returns "git@example.com" → result → back → exit
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|ssh-copy
0|git@example.com
0|
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    run _last_secrets
    assert_output "ssh-key copy git@example.com"
    # The non-secret arg was collected via an --inputbox.
    run grep -c -- "--inputbox" "${E2E_WIDGET_LOG}"
    assert_success
}

@test "ssh copy: cancelling the input forks nothing (zero side effects)" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|ssh-copy
1|
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    run test -f "${E2E_SECRETS_LOG}"
    assert_failure
}

# ── 5. Set token (input name only; value via no-echo tty) ────────────────────

@test "token set: input(name) → token set <name>; the VALUE is never in argv" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|token-set
0|gh-token
0|
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    run _last_secrets
    # Exactly `token set gh-token` — no value token follows (AC-20).
    assert_output "token set gh-token"
}

@test "token set: empty name (empty submit = cancel) forks nothing" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|token-set
0|
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    run test -f "${E2E_SECRETS_LOG}"
    assert_failure
}

# ── 6. Generate GPG key ──────────────────────────────────────────────────────

@test "gpg generate: forks gpg generate and shows a result msgbox" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|gpg-gen
0|
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    run _last_secrets
    assert_output "gpg generate"
}

# ── 7. Import GPG (input file path) ──────────────────────────────────────────

@test "gpg import: input(path) → gpg import <path>" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|gpg-import
0|/tmp/key.asc
0|
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    run _last_secrets
    assert_output "gpg import /tmp/key.asc"
}

# ── 8. Delete… (category menu + danger tiers) ────────────────────────────────

@test "delete: category menu offers only Token and SSH key (GPG deletion deferred)" {
    _make_secrets_harness dialog
    # secrets → delete → (category menu) Back → secrets Back → exit
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|delete
1|
1|
1|
EOF
    _run_secrets_e2e
    assert_success
    run cat "${E2E_WIDGET_LOG}"
    # The category menu carries del-token / del-ssh tags but no gpg-delete.
    assert_output --partial "del-token"
    assert_output --partial "del-ssh"
    refute_output --partial "gpg-delete"
}

@test "delete token: pick from list → single yesno confirm → remove <name>" {
    _make_secrets_harness dialog
    # secrets → delete → del-token → pick name → yesno Yes → result → back → exit
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|delete
0|del-token
0|gh-token
0|
0|
1|
1|
EOF
    _run_secrets_e2e \
        "SECRETS_OUT_list=gh-token\nnpm-token\n"
    assert_success
    run _last_secrets
    # Token deletion forks the top-level `remove <name>` (setup_secrets has no
    # `token remove`; the canonical token delete is `remove <name>`).
    assert_output "remove gh-token"
    # A yesno (not type-to-confirm) gated the token deletion.
    run grep -c -- "--yesno" "${E2E_WIDGET_LOG}"
    assert_success
}

@test "delete token: yesno No forks nothing destructive" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|delete
0|del-token
0|gh-token
1|
1|
1|
EOF
    _run_secrets_e2e \
        "SECRETS_OUT_list=gh-token\n"
    assert_success
    # `list` was forked to build the pick list, but `remove` never ran.
    run grep -c "^remove " "${E2E_SECRETS_LOG}"
    assert_failure
}

@test "delete ssh key: type-to-confirm matching the name → ssh-key remove <name> --yes" {
    _make_secrets_harness dialog
    # secrets → delete → del-ssh → pick key → type-to-confirm input "id_ed25519"
    #   → result → back → exit
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|delete
0|del-ssh
0|id_ed25519
0|id_ed25519
0|
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

@test "delete ssh key: a non-matching type-to-confirm aborts (no remove fork)" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|delete
0|del-ssh
0|id_ed25519
0|WRONG-NAME
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

# ── Result feedback (OK / FAILED) ────────────────────────────────────────────

@test "result msgbox: a failing op surfaces FAILED with the rc (plain text, no emoji)" {
    _make_secrets_harness dialog
    cat >"${E2E_RESPONSES}" <<'EOF'
0|secrets
0|ssh-load
0|
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
0|ssh-load
0|
1|
1|
EOF
    _run_secrets_e2e "SECRETS_RC_ssh_key_load=0"
    assert_success
    run cat "${E2E_WIDGET_LOG}"
    assert_output --partial "OK"
}

# ── No-emoji guarantee across the whole secrets surface ──────────────────────

@test "no-emoji: the secrets sub-menu source carries no emoji / check-cross glyphs" {
    # Repo-wide hard rule: plain text only. Grep the screen + lib for the
    # common offenders (checkmark / cross / sparkles) — none allowed.
    run grep -nP '[\x{2705}\x{274C}\x{2714}\x{2716}\x{2728}\x{1F500}-\x{1FAFF}]' \
        "${REPO_ROOT}/setup_ubuntu_tui.sh"
    assert_failure
}

# ── token get is excluded from the TUI surface ───────────────────────────────

@test "token get: never appears as a secrets sub-menu action (shoulder-surfing)" {
    # `token get` would print the secret value on screen — it must not be a
    # forkable action anywhere in the TUI.
    run grep -n "token get" "${REPO_ROOT}/setup_ubuntu_tui.sh"
    assert_failure
}
