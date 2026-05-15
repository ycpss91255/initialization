#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit &>/dev/null || true
shopt -s nullglob

candidates=("${HOME}/.claude/plugins/cache/cc-statusline/cc-statusline/"*/)
[[ ${#candidates[@]} -eq 0 ]] && exit 0

PLUGIN_ROOT="${candidates[-1]%/}"
exec node "${PLUGIN_ROOT}/statusline.js"
