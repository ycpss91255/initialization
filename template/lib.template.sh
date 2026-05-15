#!/usr/bin/env bash
# lib/<name>.sh — <one-line summary of what this library provides>
#
# Authoring guide (doc/architecture.md §4):
#   1. cp template/lib.template.sh lib/<your-name>.sh
#   2. Replace the header above + define your functions.
#   3. NO top-level `set -euo pipefail` — callers (lib/runner.sh sub-shell,
#      tests under bats, setup_ubuntu.sh) already declare strict mode and
#      relying on theirs avoids leaking it into other sourced libs.
#   4. NO side effects at source time. Functions only.
#   5. Public function names use the file's stem as prefix:
#         lib/state.sh        -> state_record_install / state_load
#         lib/sync.sh         -> sync_push / sync_pull
#         lib/module_helper  -> module_default_apt_install / ...
#   6. Private helpers start with a single underscore: _foo_internal.
#
# Standard library guard: refuse to run as an executable script.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf "Warn: %s is a library, not an executable script.\n" "${BASH_SOURCE[0]##*/}"
    printf "Source it from a script or test, e.g.:\n"
    printf "    source \"%s\"\n" "${BASH_SOURCE[0]}"
    return 0 2>/dev/null
fi

# ── Public functions ────────────────────────────────────────────────────────

# foo_bar <arg>
#   <what it does>. Returns 0 on success.
foo_bar() {
    local _arg="${1:?foo_bar needs <arg>}"
    # TODO
    printf 'foo_bar: %s\n' "${_arg}"
}

# ── Private helpers ─────────────────────────────────────────────────────────

# _foo_internal <arg>
#   Internal helper. Do not call from other libs.
_foo_internal() {
    :
}
