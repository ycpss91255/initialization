#!/usr/bin/env bash
# Dynamically size the tmux status bar and publish the terminal width for the
# theme. Run from client-resized / client-attached / session-created hooks
# (which have a client context) so the split tracks the real terminal width.
#
# - status-left-length / status-right-length: ratio ~1/3 : 2/3 of the width, so
#   the long right side is not truncated on wide terminals.
# - @cw (a global user option): the current width, which the powerline theme
#   reads for responsive segment hiding. The theme cannot get the width itself
#   because a status-line "#()" shell command has NO client context (so
#   display-message there returns nothing); a global option, however, is
#   readable from any context.
#
# Width is taken from the current client, falling back to the narrowest
# attached client (works even when this runs without a client context, e.g. the
# one-shot run at config load).
w=$(tmux display-message -p '#{client_width}' 2>/dev/null)
case "$w" in '' | *[!0-9]*) w="" ;; esac
if [ -z "$w" ]; then
	w=$(tmux list-clients -F '#{client_width}' 2>/dev/null | sort -n | head -1)
fi
case "$w" in '' | *[!0-9]*) exit 0 ;; esac
[ "$w" -ge 1 ] || exit 0

left=$((w / 3))
right=$((w - left))   # the remaining ~2/3

tmux set -g status-left-length "$left"
tmux set -g status-right-length "$right"
tmux set -g @cw "$w"
