#!/usr/bin/env bash
# .agents/hook/worktree_create.sh — Claude Code WorktreeCreate hook.
#
# Replaces Claude Code's default worktree location (.claude/worktrees/<name>)
# with a dedicated, gitignored repo-root dir: <repo>/.worktree/<name>. Keeping
# the worktrees inside the repo (not out-of-tree) makes them easy to find and
# manage; .worktree/ is gitignored and is pruned from the lint/coverage `find`
# (script/ci/ci.sh) so the per-worktree full repo copies are never scanned
# (that scan once wedged a lint run for ~54 min).
#
# Contract (Claude Code WorktreeCreate hook): reads a JSON object on stdin with
# a `.name` field; creates the git worktree wherever it likes; prints the
# resulting absolute path on stdout (nothing else). Non-zero exit / empty
# stdout => Claude falls back to its default behavior.
#
# Template-first (ADR-0029): sources lib/hook_bootstrap.sh for set -uo pipefail
# (ADR-0007 exit-code-contract) + input reading (hook_read_input / hook_field).
# The path-safety checks, repo-root resolution, and `git worktree add` (printing
# only the absolute path on stdout) are this hook's unique logic and are unchanged.

# shellcheck source=../../lib/hook_bootstrap.sh
source "${LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib" && pwd -P)}/hook_bootstrap.sh"
hook_bootstrap "worktree-create"

hook_read_input

# This is a WorktreeCreate hook: the real payload carries `.name` and never a
# tool-use `.tool_name`. When a tool-use payload is misrouted here (a Bash
# PreToolUse call, or the conformance meta-test's empty-command probe), this hook
# does not apply — no-op / allow (exit 0) instead of erroring on the absent name.
[[ -n "$(hook_field '.tool_name')" ]] && exit 0

_name="$(hook_field '.name')"
[[ -n "${_name}" ]] || { printf 'worktree_create: missing .name in payload\n' >&2; exit 1; }

# Reject path-trickery in the name (it becomes a directory + branch component).
case "${_name}" in
    */*|*..*|"") printf 'worktree_create: unsafe name %q\n' "${_name}" >&2; exit 1 ;;
esac

_root="${CLAUDE_PROJECT_DIR:-}"
[[ -n "${_root}" ]] || _root="$(git rev-parse --show-toplevel 2>/dev/null)"
# main repo has .git as a dir; a linked worktree has it as a file — accept either.
[[ -n "${_root}" && -e "${_root}/.git" ]] \
    || { printf 'worktree_create: no repo root\n' >&2; exit 1; }

_base="${_root}/.worktree"
_dir="${_base}/${_name}"
_branch="worktree-${_name}"

mkdir -p "${_base}" || { printf 'worktree_create: mkdir %q failed\n' "${_base}" >&2; exit 1; }

# Already present (idempotent) — just hand the path back.
if [[ -d "${_dir}" ]]; then
    printf '%s' "${_dir}"
    exit 0
fi

# Prefer a fresh branch (matches Claude's default `worktree-<name>`); fall back
# to an existing branch of that name, then to a detached worktree. All git
# chatter goes to stderr so stdout carries only the path.
if git -C "${_root}" worktree add "${_dir}" -b "${_branch}" >&2 2>&1 \
   || git -C "${_root}" worktree add "${_dir}" "${_branch}" >&2 2>&1 \
   || git -C "${_root}" worktree add "${_dir}" >&2 2>&1; then
    printf '%s' "${_dir}"
else
    printf 'worktree_create: git worktree add failed for %q\n' "${_dir}" >&2
    exit 1
fi
