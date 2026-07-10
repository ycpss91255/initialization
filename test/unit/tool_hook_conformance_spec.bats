#!/usr/bin/env bats
# test/unit/tool_hook_conformance_spec.bats — template-first conformance meta-test.
#
# WHY THIS EXISTS
# ---------------
# ADR-0029 + lib/tool_bootstrap.sh + lib/hook_bootstrap.sh established a single
# template-first shape: every one-off tool sources lib/tool_bootstrap.sh and
# exposes the outward contract (usage()/--help -> exit 0; unknown arg -> exit 2),
# and every Claude hook sources lib/hook_bootstrap.sh and honours the exit-code
# contract (0 allow / 2 block; allow on an empty command). This meta-test
# DISCOVERS every managed tool + hook DYNAMICALLY and asserts each conforms, so
# a newly-added or migrated file cannot silently drift.
#
# THE ALLOWLIST (and why it SHRINKS)
# ----------------------------------
# Most existing tools/hooks predate the bootstraps and are NOT migrated yet.
# Enforcing conformance on all of them today would be red. So the currently-
# unmigrated files are quarantined in ALLOWLIST_TOOLS / ALLOWLIST_HOOKS below —
# an explicit, documented ledger of the remaining migration debt. Conformance is
# enforced on every file NOT in the allowlist.
#
# The allowlist is SELF-CLEANING and can only SHRINK:
#   * "conformance" tests enforce that every NON-allowlisted file sources its
#     bootstrap and satisfies the outward contract.
#   * "self-cleaning" tests enforce that every ALLOWLISTED file still EXISTS and
#     still does NOT source its bootstrap (i.e. is genuinely unmigrated).
# So when you migrate a file you MUST also remove it from the allowlist: once it
# sources the bootstrap, the self-cleaning test flags the stale entry red until
# it is dropped, and the conformance test then holds it to the full contract.
# Removing the entry is the natural, forced next step of any migration.
#
# SCOPE
# -----
# Tools: the top-level one-off scripts tool/*.sh that ADR-0029 governs. The
# self-contained subdir bundles (tool/battery, tool/davinci_resolve,
# tool/f5-split-dns, tool/ros1) are vendored/multi-file packages, not one-off
# tools, and are deliberately out of scope here.
# Hooks: every .agents/hook/*.sh (the real files; .claude/hook is a symlink).

load "${BATS_TEST_DIRNAME}/../helper/common"

# ── Migration debt ledger (SHRINKS as files migrate) ─────────────────────────
# Newline-delimited basenames of files NOT yet migrated onto their bootstrap.
ALLOWLIST_TOOLS="
copy_neovim_local_config.sh
dual_system_time_sync.sh
setup_terminal_font_size.sh
setup_wayland.sh
sync_config.sh
"

# Empty: all hooks are migrated onto lib/hook_bootstrap.sh and enforced.
ALLOWLIST_HOOKS=""

setup() {
    setup_test_env
    export LIB_DIR REPO_ROOT
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    # Scratch HOME so nothing a tool might touch escapes the sandbox (the
    # contract cases exercised here never reach do_work anyway).
    export HOME="${INIT_UBUNTU_TEST_SCRATCH}/home"
    mkdir -p "${HOME}"
    TOOL_DIR="${REPO_ROOT}/tool"
    HOOK_DIR="${REPO_ROOT}/.agents/hook"
}

teardown() { teardown_test_env; }

# _in_allowlist <basename> <allowlist-string> — 0 when listed.
_in_allowlist() { grep -qxF "${1}" <<< "${2}"; }

# _sources_bootstrap <file> <bootstrap-basename> — 0 when the file sources it.
_sources_bootstrap() { grep -q "${2}" "${1}"; }

# _discover_tools — top-level tool/*.sh into the TOOLS array.
_discover_tools() {
    shopt -s nullglob
    TOOLS=("${TOOL_DIR}"/*.sh)
    shopt -u nullglob
}

# _discover_hooks — .agents/hook/*.sh into the HOOKS array.
_discover_hooks() {
    shopt -s nullglob
    HOOKS=("${HOOK_DIR}"/*.sh)
    shopt -u nullglob
}

# Build a PreToolUse Bash payload with the given command string.
_json() { jq -n --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }

# ── Discovery guards (catch a silently-empty sweep) ──────────────────────────

@test "discovery finds the managed top-level tools" {
    _discover_tools
    [[ "${#TOOLS[@]}" -ge 5 ]] || {
        printf 'discovered only %d tool(s) under %s — expected >= 5\n' \
            "${#TOOLS[@]}" "${TOOL_DIR}" >&2
        return 1
    }
}

@test "discovery finds the Claude hooks" {
    _discover_hooks
    [[ "${#HOOKS[@]}" -ge 13 ]] || {
        printf 'discovered only %d hook(s) under %s — expected >= 13\n' \
            "${#HOOKS[@]}" "${HOOK_DIR}" >&2
        return 1
    }
}

# ── Conformance: every NON-allowlisted tool ──────────────────────────────────

@test "every managed (non-allowlisted) tool sources lib/tool_bootstrap.sh" {
    _discover_tools
    local _f _base _violations=""
    for _f in "${TOOLS[@]}"; do
        _base="$(basename "${_f}")"
        _in_allowlist "${_base}" "${ALLOWLIST_TOOLS}" && continue
        _sources_bootstrap "${_f}" "tool_bootstrap.sh" || \
            _violations+="  ${_base}: does not source lib/tool_bootstrap.sh"$'\n'
    done
    [[ -z "${_violations}" ]] || {
        printf 'non-conforming tools (migrate or allowlist):\n%s' "${_violations}" >&2
        return 1
    }
}

@test "every managed (non-allowlisted) tool honours the --help/unknown-arg contract" {
    _discover_tools
    local _f _base _violations=""
    for _f in "${TOOLS[@]}"; do
        _base="$(basename "${_f}")"
        _in_allowlist "${_base}" "${ALLOWLIST_TOOLS}" && continue

        # --help -> exit 0 + prints Usage:
        run bash "${_f}" --help
        [[ "${status}" -eq 0 && "${output}" == *"Usage:"* ]] || \
            _violations+="  ${_base}: --help did not exit 0 with Usage: (status=${status})"$'\n'

        # unknown arg -> exit 2
        run bash "${_f}" --scaffold-conformance-bogus
        [[ "${status}" -eq 2 ]] || \
            _violations+="  ${_base}: unknown arg did not exit 2 (status=${status})"$'\n'
    done
    [[ -z "${_violations}" ]] || {
        printf 'tools violating the outward CLI contract:\n%s' "${_violations}" >&2
        return 1
    }
}

# ── Conformance: every NON-allowlisted hook ──────────────────────────────────

@test "every managed (non-allowlisted) hook sources lib/hook_bootstrap.sh" {
    _discover_hooks
    local _f _base _violations=""
    for _f in "${HOOKS[@]}"; do
        _base="$(basename "${_f}")"
        _in_allowlist "${_base}" "${ALLOWLIST_HOOKS}" && continue
        _sources_bootstrap "${_f}" "hook_bootstrap.sh" || \
            _violations+="  ${_base}: does not source lib/hook_bootstrap.sh"$'\n'
    done
    [[ -z "${_violations}" ]] || {
        printf 'non-conforming hooks (migrate or allowlist):\n%s' "${_violations}" >&2
        return 1
    }
}

@test "every managed (non-allowlisted) hook allows an empty command (exit-code contract)" {
    _discover_hooks
    local _f _base _payload _violations=""
    _payload="$(_json "")"
    for _f in "${HOOKS[@]}"; do
        _base="$(basename "${_f}")"
        _in_allowlist "${_base}" "${ALLOWLIST_HOOKS}" && continue
        run bash -c 'printf "%s" "$1" | "$2"' _ "${_payload}" "${_f}"
        [[ "${status}" -eq 0 ]] || \
            _violations+="  ${_base}: empty-command payload did not exit 0 (status=${status})"$'\n'
    done
    [[ -z "${_violations}" ]] || {
        printf 'hooks violating the allow-on-empty exit-code contract:\n%s' "${_violations}" >&2
        return 1
    }
}

# ── Self-cleaning allowlists (force the ledger to shrink) ─────────────────────

@test "every allowlisted tool still exists and is still unmigrated" {
    local _base _file _stale=""
    while IFS= read -r _base; do
        [[ -n "${_base}" ]] || continue
        _file="${TOOL_DIR}/${_base}"
        if [[ ! -f "${_file}" ]]; then
            _stale+="  ${_base}: file no longer exists — drop the allowlist entry"$'\n'
        elif _sources_bootstrap "${_file}" "tool_bootstrap.sh"; then
            _stale+="  ${_base}: now sources lib/tool_bootstrap.sh (migrated) — remove this stale allowlist entry"$'\n'
        fi
    done <<< "${ALLOWLIST_TOOLS}"
    [[ -z "${_stale}" ]] || {
        printf 'stale ALLOWLIST_TOOLS entries:\n%s' "${_stale}" >&2
        return 1
    }
}

@test "every allowlisted hook still exists and is still unmigrated" {
    local _base _file _stale=""
    while IFS= read -r _base; do
        [[ -n "${_base}" ]] || continue
        _file="${HOOK_DIR}/${_base}"
        if [[ ! -f "${_file}" ]]; then
            _stale+="  ${_base}: file no longer exists — drop the allowlist entry"$'\n'
        elif _sources_bootstrap "${_file}" "hook_bootstrap.sh"; then
            _stale+="  ${_base}: now sources lib/hook_bootstrap.sh (migrated) — remove this stale allowlist entry"$'\n'
        fi
    done <<< "${ALLOWLIST_HOOKS}"
    [[ -z "${_stale}" ]] || {
        printf 'stale ALLOWLIST_HOOKS entries:\n%s' "${_stale}" >&2
        return 1
    }
}
