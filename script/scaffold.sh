#!/usr/bin/env bash
# script/scaffold.sh — dev-side scaffold generator for one-off tools + hooks.
#
# AUTHORING-TIME TOOLING, NOT a shipped feature. This script is NOT a
# setup_ubuntu subcommand, NOT a tool/ one-off, and NOT a Claude hook. It is a
# maintainer convenience (sibling of script/gen-module-index.sh) that stamps a
# new tool/ or .agents/hook/ script — plus its matching bats spec — from the
# canonical templates, so authors start from the template-first shape instead
# of hand-rolling (or copy-pasting) it.
#
# What it stamps:
#   new-tool <name>   tool/<name>.sh                    (from template/tool.template.sh)
#                     test/unit/tool/<name>_spec.bats   (from template/test-tool.template.bats)
#   new-hook <name>   .agents/hook/<name>.sh            (from template/hook.template.sh)
#                     test/unit/hook/<name>_spec.bats   (from template/test-hook.template.bats)
#
# The stamped script already sources the correct bootstrap
# (lib/tool_bootstrap.sh or lib/hook_bootstrap.sh) and the stamped spec already
# passes as a stub — the author then replaces the reference do_work()/decision
# with the real logic and fills the <TODO> markers.
#
# Usage:
#   script/scaffold.sh new-tool <name>
#   script/scaffold.sh new-hook <name>
#   script/scaffold.sh --help
#
# Exit codes (mirrors the tool/hook 0=ok / 2=usage-error contract):
#   0  success (or --help)
#   2  usage error (bad subcommand, missing/invalid name, target exists)
#
# Always-act family (ADR-0007): this script performs side effects (creates
# files); any intermediate failure must abort the whole run.

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# ── Paths ────────────────────────────────────────────────────────────────────
# SCRIPT_REPO: the repo this script ships in — templates are read from here.
# OUT_ROOT:    where stamped files are written — defaults to SCRIPT_REPO, but
#              --root <dir> (or SCAFFOLD_ROOT env) redirects it so the unit test
#              can stamp into a scratch tree instead of the live repo.
SCRIPT_REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUT_ROOT="${SCAFFOLD_ROOT:-${SCRIPT_REPO}}"
TEMPLATE_DIR="${SCRIPT_REPO}/template"

# ── Messaging (no logger dependency — this is a standalone dev script) ────────
_err()  { printf 'scaffold: error: %s\n' "$*" >&2; }
_info() { printf 'scaffold: %s\n' "$*"; }

usage() {
    cat <<'EOF'
scaffold.sh — stamp a new one-off tool or Claude hook (+ its bats spec) from
the canonical templates.

Usage:
  scaffold.sh new-tool <name>     stamp tool/<name>.sh + test/unit/tool/<name>_spec.bats
  scaffold.sh new-hook <name>     stamp .agents/hook/<name>.sh + test/unit/hook/<name>_spec.bats
  scaffold.sh -h | --help         show this help and exit

Options:
  --root <dir>                    write stamped files under <dir> instead of the
                                  repo (also honoured via SCAFFOLD_ROOT); used by
                                  the generator's own tests.

Name rules:
  lowercase, starts with a letter, words joined by '-' or '_'
  (e.g. remind-no-emoji, copy_gnome_terminal_config).

Exit codes:
  0  success (or --help)
  2  usage error (bad subcommand, missing/invalid name, or target already exists)

The stamped script sources the matching bootstrap (lib/tool_bootstrap.sh or
lib/hook_bootstrap.sh); the stamped spec passes as a stub. Replace the reference
do_work()/decision with the real logic, then:
  just -f justfile.ci test-unit
EOF
}

# _valid_name <name> — kebab/snake, lowercase, letter-initial. 0 when valid.
_valid_name() {
    [[ "${1}" =~ ^[a-z][a-z0-9]*([_-][a-z0-9]+)*$ ]]
}

# _stamp <template-file> <dest-file> <sed-expr> — copy a template to dest,
# applying the placeholder substitution. Refuses to clobber an existing dest.
_stamp() {
    local _tpl="${1}" _dest="${2}" _sed="${3}"

    [[ -r "${_tpl}" ]] || { _err "template not found: ${_tpl}"; return 1; }
    if [[ -e "${_dest}" ]]; then
        _err "target already exists (refusing to overwrite): ${_dest}"
        return 2
    fi

    mkdir -p -- "$(dirname -- "${_dest}")"
    sed "${_sed}" -- "${_tpl}" >"${_dest}"
    _info "created ${_dest#"${OUT_ROOT}"/}"
}

# new_tool <name> — stamp tool/<name>.sh + its spec.
new_tool() {
    local _name="${1}"
    local _script="${OUT_ROOT}/tool/${_name}.sh"
    local _spec="${OUT_ROOT}/test/unit/tool/${_name}_spec.bats"

    _stamp "${TEMPLATE_DIR}/tool.template.sh" "${_script}" \
        "s/TOOL_NAME=\"tool-template\"/TOOL_NAME=\"${_name}\"/"
    chmod +x -- "${_script}"

    _stamp "${TEMPLATE_DIR}/test-tool.template.bats" "${_spec}" \
        "s/<TOOL-NAME>/${_name}/g"

    _info "next: fill do_work() in ${_script#"${OUT_ROOT}"/} and run 'just -f justfile.ci test-unit'"
}

# new_hook <name> — stamp .agents/hook/<name>.sh + its spec.
new_hook() {
    local _name="${1}"
    local _script="${OUT_ROOT}/.agents/hook/${_name}.sh"
    local _spec="${OUT_ROOT}/test/unit/hook/${_name}_spec.bats"

    # Fill the hook name AND fix the `shellcheck source=` directive: the
    # template lives at template/ (so `../lib`), but a stamped hook lives at
    # .agents/hook/ (so `../../lib`) — otherwise shellcheck -x cannot follow it
    # (SC1091) and lint fails.
    _stamp "${TEMPLATE_DIR}/hook.template.sh" "${_script}" \
        "s/hook_bootstrap \"hook-template\"/hook_bootstrap \"${_name}\"/;
         s|shellcheck source=../lib/hook_bootstrap.sh|shellcheck source=../../lib/hook_bootstrap.sh|"
    chmod +x -- "${_script}"

    _stamp "${TEMPLATE_DIR}/test-hook.template.bats" "${_spec}" \
        "s/<HOOK-NAME>/${_name}/g"

    _info "next: replace the decision in ${_script#"${OUT_ROOT}"/}, wire it in .claude/settings.local.json, and run 'just -f justfile.ci test-unit'"
}

main() {
    # Option pre-scan: pull out --root/--help before the positional subcommand.
    local -a _pos=()
    while (($#)); do
        case "${1}" in
            -h | --help)
                usage
                return 0
                ;;
            --root)
                [[ $# -ge 2 ]] || { _err "--root needs a directory argument"; usage >&2; return 2; }
                OUT_ROOT="${2}"
                shift 2
                ;;
            --root=*)
                OUT_ROOT="${1#--root=}"
                shift
                ;;
            --)
                shift
                while (($#)); do _pos+=("${1}"); shift; done
                ;;
            -*)
                _err "unknown option: ${1}"
                usage >&2
                return 2
                ;;
            *)
                _pos+=("${1}")
                shift
                ;;
        esac
    done

    local _sub="${_pos[0]:-}"
    local _name="${_pos[1]:-}"

    case "${_sub}" in
        new-tool | new-hook) ;;
        "")
            _err "missing subcommand"
            usage >&2
            return 2
            ;;
        *)
            _err "unknown subcommand: ${_sub}"
            usage >&2
            return 2
            ;;
    esac

    if [[ -z "${_name}" ]]; then
        _err "${_sub} needs a <name> argument"
        usage >&2
        return 2
    fi
    if ! _valid_name "${_name}"; then
        _err "invalid name '${_name}' — use lowercase kebab/snake (letter-initial), e.g. my-tool or my_tool"
        return 2
    fi
    if [[ "${#_pos[@]}" -gt 2 ]]; then
        _err "too many arguments: expected '${_sub} <name>'"
        usage >&2
        return 2
    fi

    case "${_sub}" in
        new-tool) new_tool "${_name}" ;;
        new-hook) new_hook "${_name}" ;;
    esac
}

main "$@"
