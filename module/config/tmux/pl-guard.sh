#!/usr/bin/env bash
# Guarded tmux-powerline invocation -- the fundamental fix for the runaway
# pile-up that once ate all RAM. tmux re-runs the status command every
# status-interval WITHOUT waiting for the previous one to finish, so a single
# hung segment (a blocked network call, a wedged nvidia-smi, a stalled NFS
# path, a bad edit) would let invocations stack up until memory is gone.
#
# Two independent safety nets make that impossible regardless of what any
# segment does:
#   flock -n : if the previous invocation for THIS side is still running, this
#              one acquires nothing and exits immediately -- invocations can
#              never pile up (at most one per side at a time).
#   timeout  : any single run that exceeds the cap is killed (-k forces
#              SIGKILL a bit later if it ignores SIGTERM) -- no process can
#              linger for 49 minutes and balloon to gigabytes.
#
# A skipped or timed-out cycle just prints nothing, leaving the bar briefly
# stale until the next tick -- harmless.

side="$1"
dir="${TMUX_TMPDIR:-/tmp}"
lock="${dir}/tmux-pl-guard-$(id -u)-${side}.lock"
pl="${HOME}/.config/tmux/plugins/tmux-powerline/powerline.sh"

flock -n "$lock" timeout -k 2 8 "$pl" "$side" 2>/dev/null || true
