#!/usr/bin/env bats
# test/unit/completion_spec.bats — shell completion for setup_ubuntu (issue #166)
#
# Two shipped completion scripts are exercised here:
#   - module/config/bash/setup_ubuntu.bash   (bash `complete -F _setup_ubuntu`)
#   - module/config/fish/completions/setup_ubuntu.fish  (`complete -c setup_ubuntu`)
#
# Both derive module NAMES live from `setup_ubuntu list` so completion tracks
# the registry. The tests stub `setup_ubuntu` (a shell/fish function) with a
# fake catalog so the assertions never depend on the real engine or network.
#
# Acceptance criteria (issue #166):
#   - Level 1 completes subcommands (and global flags for a dashed word).
#   - install / remove / purge / upgrade / verify / show complete module names.
#   - Names come from `setup_ubuntu list` (dynamic), so a changed catalog
#     changes the completions.

load "${BATS_TEST_DIRNAME}/../helper/common"

FISH_COMPLETION="${REPO_ROOT}/module/config/fish/completions/setup_ubuntu.fish"

# Source the bash completion at file scope so `_setup_ubuntu` + its helpers are
# defined once (the directive keeps shellcheck happy and reachable — same
# pattern as tui_render_fzf_spec.bats). The script only DEFINES functions and
# runs `complete -F`, so sourcing is side-effect-free for the tests.
# shellcheck source=../../module/config/bash/setup_ubuntu.bash
source "${REPO_ROOT}/module/config/bash/setup_ubuntu.bash"

# COMPREPLY membership check (COMPREPLY is a side effect of _setup_ubuntu, so
# the completion function is called directly — `run` would lose the array).
# Defined at file scope AFTER the source, and called from the @tests below, so
# it stays reachable (no SC2317).
_comp_has() {
    local want="$1" item
    for item in ${COMPREPLY[@]+"${COMPREPLY[@]}"}; do
        [[ "${item}" == "${want}" ]] && return 0
    done
    return 1
}

# Stub the CLI so the completion helpers read a fake catalog, not the real
# engine. Defined at file scope so it shadows the `setup_ubuntu` command that
# the sourced completion's `_setup_ubuntu_modules` invokes (reachable → no
# SC2317). Each @test runs in its own subshell, so the "dynamic" test can
# redefine it locally without leaking. The table mirrors real `setup_ubuntu
# list`: a NAME/CATEGORY/TAGS header then one row per module (column 1 = name).
setup_ubuntu() {
    [[ "${1:-}" == "list" ]] || return 0
    printf '%-30s  %-13s  %s\n' NAME CATEGORY TAGS
    printf '%-30s  %-13s  %s\n' neovim base editor
    printf '%-30s  %-13s  %s\n' tmux recommended mux
    printf '%-30s  %-13s  %s\n' docker optional container
}

# ── Bash: file + registration ────────────────────────────────────────────────

@test "bash: completion script exists and registers _setup_ubuntu" {
    local script="${REPO_ROOT}/module/config/bash/setup_ubuntu.bash"
    [[ -f "${script}" ]]
    run grep -q 'complete -F _setup_ubuntu setup_ubuntu' "${script}"
    [ "${status}" -eq 0 ]
}

# ── Bash: level-1 subcommands + flags ────────────────────────────────────────

@test "bash: level 1 completes subcommands" {
    COMP_WORDS=(setup_ubuntu ins); COMP_CWORD=1
    _setup_ubuntu
    _comp_has install
}

@test "bash: level 1 offers all documented subcommands" {
    COMP_WORDS=(setup_ubuntu ''); COMP_CWORD=1
    _setup_ubuntu
    local sub
    for sub in install remove purge upgrade verify list show; do
        _comp_has "${sub}" || { echo "missing subcommand: ${sub}"; return 1; }
    done
}

@test "bash: a dashed level-1 word completes global flags" {
    COMP_WORDS=(setup_ubuntu --dr); COMP_CWORD=1
    _setup_ubuntu
    _comp_has --dry-run
}

# ── Bash: module-name completion (the core ask) ──────────────────────────────

@test "bash: install completes module names from the live catalog" {
    COMP_WORDS=(setup_ubuntu install ''); COMP_CWORD=2
    _setup_ubuntu
    _comp_has neovim
    _comp_has tmux
    _comp_has docker
}

@test "bash: install filters module names by the current prefix" {
    COMP_WORDS=(setup_ubuntu install ne); COMP_CWORD=2
    _setup_ubuntu
    _comp_has neovim
    if _comp_has tmux; then echo "tmux should not match prefix 'ne'"; return 1; fi
}

@test "bash: remove / purge / upgrade / verify / show all complete modules" {
    local sub
    for sub in remove purge upgrade verify show; do
        COMP_WORDS=(setup_ubuntu "${sub}" ''); COMP_CWORD=2
        COMPREPLY=()
        _setup_ubuntu
        _comp_has neovim || { echo "no module completion after: ${sub}"; return 1; }
    done
}

@test "bash: a non-module subcommand does not complete module names" {
    COMP_WORDS=(setup_ubuntu list ''); COMP_CWORD=2
    COMPREPLY=()
    _setup_ubuntu
    if _comp_has neovim; then echo "list must not complete module names"; return 1; fi
}

@test "bash: module completion is dynamic (tracks whatever list prints)" {
    # Redefine the stub to a different catalog; completion must follow it.
    setup_ubuntu() {
        [[ "${1:-}" == "list" ]] || return 0
        printf '%-30s  %-13s  %s\n' NAME CATEGORY TAGS
        printf '%-30s  %-13s  %s\n' brandnewmod optional demo
    }
    COMP_WORDS=(setup_ubuntu install ''); COMP_CWORD=2
    COMPREPLY=()
    _setup_ubuntu
    _comp_has brandnewmod
    if _comp_has neovim; then echo "stale module should not appear"; return 1; fi
}

@test "bash: a dashed word after a subcommand completes global flags" {
    COMP_WORDS=(setup_ubuntu install --no); COMP_CWORD=2
    _setup_ubuntu
    _comp_has --no-deps
}

# ── Fish: file + structure ───────────────────────────────────────────────────

@test "fish: completion file exists under module/config/fish/completions" {
    [[ -f "${FISH_COMPLETION}" ]]
    run grep -q 'complete -c setup_ubuntu' "${FISH_COMPLETION}"
    [ "${status}" -eq 0 ]
    # Module names must be sourced dynamically, not hardcoded.
    run grep -q 'setup_ubuntu list' "${FISH_COMPLETION}"
    [ "${status}" -eq 0 ]
}

# ── Fish: real completion (only when fish is installed) ──────────────────────

@test "fish: install completes module names from the live catalog" {
    command -v fish >/dev/null 2>&1 || skip "fish not installed"
    run fish -c "
        function setup_ubuntu
            printf '%s\n' 'NAME CATEGORY TAGS' 'neovim base editor' 'tmux recommended mux'
        end
        source '${FISH_COMPLETION}'
        complete -C 'setup_ubuntu install '
    "
    [ "${status}" -eq 0 ]
    # fish appends a tab + description to each candidate ("neovim\tModule").
    echo "${output}" | grep -q '^neovim'
    echo "${output}" | grep -q '^tmux'
}

@test "fish: level 1 completes subcommands" {
    command -v fish >/dev/null 2>&1 || skip "fish not installed"
    run fish -c "
        source '${FISH_COMPLETION}'
        complete -C 'setup_ubuntu '
    "
    [ "${status}" -eq 0 ]
    echo "${output}" | grep -q '^install'
}
