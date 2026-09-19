# shellcheck shell=bash
# Custom segment: root filesystem usage percent, from the shared non-blocking
# sampler (lib_stat.sh). Emits only icon + number; the theme sets this pill's
# declared bg to a blue->red gradient of the same percent (high usage = red).

# shellcheck source=../lib_stat.sh
source "${XDG_CONFIG_HOME:-$HOME/.config}/tmux-powerline/lib_stat.sh"

DISK_ICON="󰋊"

run_segment() {
	stat_sample
	case "$STAT_DISK_PCT" in '' | *[!0-9]*) return 0 ;; esac
	echo "${DISK_ICON} ${STAT_DISK_PCT}%"
	return 0
}
