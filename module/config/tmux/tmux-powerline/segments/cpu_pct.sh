# shellcheck shell=bash
# Custom segment: CPU usage percentage. Split from the old combined
# tmux_mem_cpu_load so mem and cpu are two independent pills. Values come
# from the shared non-blocking /proc sampler (lib_stat.sh).
#
# This segment emits ONLY the icon + number (no #[bg=...]). The blue->red
# gradient background is applied by the theme, which sets this segment's
# declared bg color to stat_gradient(cpu%) using the SAME cached sample --
# that way the round separator to the left of the pill (drawn by the plugin
# from the declared bg) blends with the pill body instead of staying a fixed
# color. If sourced standalone (no theme), it still prints a readable value.

# shellcheck source=../lib_stat.sh
source "${XDG_CONFIG_HOME:-$HOME/.config}/tmux-powerline/lib_stat.sh"

CHIP_ICON=""

# Drop the decimal at/above 10%, keep one decimal place below it.
__format_pct() {
	awk -v n="$1" 'BEGIN { if (n + 0 >= 10) printf "%d", n + 0.5; else printf "%.1f", n }'
}

run_segment() {
	stat_sample
	[ -n "$STAT_CPU_PCT" ] || return 0
	local out
	out="${CHIP_ICON} $(__format_pct "$STAT_CPU_PCT")%"
	# Append the CPU package temperature (integer, no decimal) when available.
	case "$STAT_CPU_TEMP" in
		'' | *[!0-9]*) ;;
		*) out="${out} ${THERMO_ICON}${STAT_CPU_TEMP}°" ;;
	esac
	echo "$out"
	return 0
}
