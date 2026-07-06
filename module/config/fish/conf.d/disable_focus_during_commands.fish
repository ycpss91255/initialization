# Workaround for fish injecting focus-event sequences (ESC[I / ESC[O, shown as
# ^[[I) into external commands under tmux (focus-events on) + fish 4.x.
#
# fish enables focus reporting unconditionally and emits a focus-in sequence
# around prompt exit / command launch. A plain shell script does not consume
# these sequences, so they leak in as literal input (e.g. an interactive
# `read` captures `\e[Itest` instead of `test`).
#
# Disabling focus reporting before each command (DECSET 1004 low, ESC[?1004l)
# stops the leak. fish re-enables focus reporting on its next prompt and nvim
# enables its own when it starts, so tmux `focus-events on` can stay on and
# nvim's FocusGained autoread keeps working.
#
# See: https://github.com/fish-shell/fish-shell/issues/12232
function __disable_focus_reporting_preexec --on-event fish_preexec
    printf '\e[?1004l'
end
