# shellcheck shell=bash
# Custom segment: memory usage percentage. Split from the old combined
# tmux_mem_cpu_load so mem and cpu are two independent pills. Values come
# from the shared non-blocking /proc sampler (lib_stat.sh), not the
# tmux-mem-cpu-load binary (which blocked ~2s per read).

# shellcheck source=../lib_stat.sh
source "${XDG_CONFIG_HOME:-$HOME/.config}/tmux-powerline/lib_stat.sh"

MEM_ICON=""

# Drop the decimal at/above 10%, keep one decimal place below it.
__format_pct() {
	awk -v n="$1" 'BEGIN { if (n + 0 >= 10) printf "%d", n + 0.5; else printf "%.1f", n }'
}

run_segment() {
	stat_sample
	[ -n "$STAT_MEM_PCT" ] || return 0
	echo "${MEM_ICON} $(__format_pct "$STAT_MEM_PCT")%"
	return 0
}
