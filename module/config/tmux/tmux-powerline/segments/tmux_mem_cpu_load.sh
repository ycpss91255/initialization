# shellcheck shell=bash
# Override of tmux-powerline's bundled tmux_mem_cpu_load segment.
# Reasons:
# 1. Upstream binary right-aligns the percentage in a width-6 field
#    (hardcoded in tmux-mem-cpu-load main.cc, oss.width(6)), producing extra
#    spaces between the graph and the percent. Squeeze them with `tr -s ' '`
#    so the segment width is stable and matches the old vertical-graph layout.
# 2. Upstream only switches the mem token from MB→GB when both used and total
#    exceed 10000 MB (common/memory.cc), so a 4 GB working set on a 32 GB box
#    renders as "4096MB/30GB". We re-render the leading mem token from
#    /proc/meminfo and switch to GB whenever a value exceeds 1024 MB.

TMUX_POWERLINE_SEG_TMUX_MEM_CPU_LOAD_ARGS="${TMUX_POWERLINE_SEG_TMUX_MEM_CPU_LOAD_ARGS:--v}"

generate_segmentrc() {
	read -r -d '' rccontents <<EORC
# Arguments passed to tmux-mem-cpu-load.
# See https://github.com/thewtex/tmux-mem-cpu-load for all available options.
# export TMUX_POWERLINE_SEG_TMUX_MEM_CPU_LOAD_ARGS="${TMUX_POWERLINE_SEG_TMUX_MEM_CPU_LOAD_ARGS}"
EORC
	echo "$rccontents"
}

# Build a fresh "used/total" mem string from /proc/meminfo using the same
# accounting the upstream binary uses (linux/memory.cc): used = total + shmem
# - free - buffers - cached - sreclaimable. Each side renders as GB with one
# decimal when above 1024 MB, otherwise as integer MB.
__mem_token() {
	local total=0 free=0 shmem=0 buffers=0 cached=0 sreclaimable=0 used key val
	while IFS=': ' read -r key val _; do
		case "$key" in
			MemTotal) total=$val ;;
			MemFree) free=$val ;;
			Shmem) shmem=$val ;;
			Buffers) buffers=$val ;;
			Cached) cached=$val ;;
			SReclaimable) sreclaimable=$val ;;
		esac
	done </proc/meminfo
	used=$(( total + shmem - free - buffers - cached - sreclaimable ))
	awk -v u="$used" -v t="$total" 'BEGIN {
		thresh = 1024 * 1024
		if (u >= thresh) printf "%.1fGB", u / 1024 / 1024; else printf "%dMB", u / 1024
		printf "/"
		if (t >= thresh) printf "%.1fGB", t / 1024 / 1024; else printf "%dMB", t / 1024
	}'
}

run_segment() {
	read -r -a args <<<"$TMUX_POWERLINE_SEG_TMUX_MEM_CPU_LOAD_ARGS"
	stats=""
	if type "$TMUX_PLUGIN_MANAGER_PATH/tmux-mem-cpu-load/tmux-mem-cpu-load" >/dev/null 2>&1; then
		stats=$("$TMUX_PLUGIN_MANAGER_PATH/tmux-mem-cpu-load/tmux-mem-cpu-load" "${args[@]}")
	elif type tmux-mem-cpu-load >/dev/null 2>&1; then
		stats=$(tmux-mem-cpu-load "${args[@]}")
	else
		return
	fi

	if [ -n "$stats" ]; then
		# Replace the binary's mem token (one of "X/YMB", "XMB/YGB",
		# "X/YGB") wherever it appears in the output. Not anchored: when
		# -c is enabled, the binary prefixes the token with #[fg=...]
		# color escapes. Color escapes don't contain "/", load averages
		# don't contain "MB|GB" and CPU% has no slash, so this pattern
		# uniquely identifies the mem token.
		if [[ "$stats" =~ [0-9]+(MB)?/[0-9]+(MB|GB) ]]; then
			stats="${stats/${BASH_REMATCH[0]}/$(__mem_token)}"
		fi
		echo "$stats" | tr -s ' '
	fi
	return 0
}
