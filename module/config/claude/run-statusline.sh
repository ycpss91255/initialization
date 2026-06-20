#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit &>/dev/null || true
shopt -s nullglob

candidates=("${HOME}/.claude/plugins/cache/cc-statusline/cc-statusline/"*/)
[[ ${#candidates[@]} -eq 0 ]] && exit 0

PLUGIN_ROOT="${candidates[-1]%/}"

# Claude Code invokes the status line with a piped (non-TTY) stdout, so the
# cc-statusline renderer cannot auto-detect the terminal width and falls back
# to a narrow default, clipping content with `...` even when there is room.
# Feed it the real width from tmux, reserving a tiny margin to avoid wrapping
# (cc-statusline reads CCSTATUSLINE_WIDTH). (#228)
WIDTH_MARGIN=2
pane_width=$(tmux display-message -p '#{pane_width}' 2>/dev/null) || true
if [[ "${pane_width}" =~ ^[0-9]+$ ]] && (( pane_width > WIDTH_MARGIN )); then
  export CCSTATUSLINE_WIDTH=$(( pane_width - WIDTH_MARGIN ))
fi

exec node "${PLUGIN_ROOT}/statusline.js"
