# shellcheck shell=bash
# Custom segment: ONE network interface's IP, addressed like the GPU pills.
# This single script backs several pills via symlinks net_if0.sh, net_if1.sh,
# ...: each pill's index comes from its own filename, so net_if1 shows the 2nd
# active interface. A pill whose index exceeds the active-interface count
# prints nothing and is dropped, so a machine with one interface shows one
# pill, a laptop on wifi+ethernet+vpn shows three, etc. Virtual/bridge/docker
# interfaces are filtered out by the shared sampler.
#
# The icon reflects the interface type (wifi / ethernet / vpn); the theme sets
# each pill's colour by that same type.

# shellcheck source=../lib_stat.sh
source "${XDG_CONFIG_HOME:-$HOME/.config}/tmux-powerline/lib_stat.sh"

declare -A NET_TYPE_ICON=(
	[wifi]="󰖩"
	[eth]="󰈀"
	[vpn]="󰖂"
)
NET_ICON_DEFAULT="󰛳"
THROUGHPUT_ICON="󰓅"   # md-speedometer, marks the up/down rates

# Human-compact bytes/sec, always a value (no floor): "1.2M" at/above 1 MiB/s,
# else "<n>k" (so an idle link reads "0k" rather than vanishing). The rate is
# whatever the shared 5s sampler already computed; printing it always adds no
# extra polling.
__fmt_rate() {
	awk -v b="$1" 'BEGIN {
		if (b + 0 >= 1048576) printf "%dM", b / 1048576 + 0.5
		else printf "%dk", b / 1024
	}'
}

run_segment() {
	# Index from this pill's (sym)link name: net_ifN.sh -> N.
	local name="${TMUX_POWERLINE_CUR_SEGMENT_NAME:-net_if0.sh}"
	local idx="${name#net_if}"; idx="${idx%.sh}"
	case "$idx" in '' | *[!0-9]*) idx=0 ;; esac

	stat_nets
	local ip typ icon
	ip=$(stat_net_ip "$idx")
	[ -n "$ip" ] || return 0   # no interface at this index
	typ=$(stat_net_type "$idx")
	icon="${NET_TYPE_ICON[$typ]:-$NET_ICON_DEFAULT}"

	# When more than one interface shares this type (e.g. two wifi), append a
	# 1-based index badge so they are distinguishable; a lone interface of a
	# type needs none (the icon already says which kind it is). Rank is this
	# interface's position among the same-type interfaces in priority order.
	local j same=0 rank=0 num=""
	for ((j = 0; j < STAT_NET_N; j++)); do
		if [ "${STAT_NET_TYPE[j]}" = "$typ" ]; then
			same=$((same + 1))
			[ "$j" -le "$idx" ] && rank=$((rank + 1))
		fi
	done
	[ "$same" -gt 1 ] && num=" $(stat_num_badge "$rank")"

	# Throughput since the last sample -- always shown, upload then download.
	local down up
	up="↑$(__fmt_rate "$(stat_net_tx "$idx")")"
	down="↓$(__fmt_rate "$(stat_net_rx "$idx")")"

	echo "#[fg=${TMUX_POWERLINE_CUR_SEGMENT_FG}]${icon}${num} ${ip} ${THROUGHPUT_ICON} ${up}/${down}"
	return 0
}
