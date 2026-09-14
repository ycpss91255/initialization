# shellcheck shell=bash
# Custom segment: usage of ONE discrete GPU. This single script backs several
# pills via symlinks gpu_pct0.sh, gpu_pct1.sh, ...: each pill's index comes
# from its own filename (TMUX_POWERLINE_CUR_SEGMENT_NAME), so gpu_pct2 shows
# the 3rd discrete GPU. A pill whose index exceeds the discrete-GPU count
# prints nothing and is dropped, so a machine with fewer (or zero) discrete
# GPUs simply shows fewer (or no) GPU pills. Integrated GPUs are never shown
# (the shared sampler filters them out by PCI bus).
#
# Like cpu_pct, this emits only the icon + number; the theme sets each pill's
# declared bg to stat_gradient(usage) from the SAME cached sample, so body
# and separator share the blue->red gradient.

# shellcheck source=../lib_stat.sh
source "${XDG_CONFIG_HOME:-$HOME/.config}/tmux-powerline/lib_stat.sh"

# A generic "this is a GPU" marker shown in front of every GPU pill, then a
# per-vendor letter-in-box glyph. Unknown vendors fall back to GPU_ICON (a
# "?" marker) -- e.g. a discrete GPU whose PCI vendor id is none of the big
# three, which in practice is rare on x86.
GPU_PREFIX_ICON="󰢮"
GPU_ICON="󱄶"
declare -A GPU_VENDOR_ICON=(
	[NVIDIA]="󰰒"
	[AMD]="󰯫"
	[Intel]="󰰃"
)
THERMO_ICON="󰔏"   # md-thermometer, prefixes the integer temperature
VRAM_ICON=""     # fa-memory, prefixes the VRAM-used percent

# The per-GPU index badge (shown when there is more than one discrete GPU so
# same-vendor cards are distinguishable) uses the shared stat_num_badge helper
# from lib_stat.sh (md-numeric_N_box_outline).

# Drop the decimal at/above 10%, keep one decimal place below it.
__format_pct() {
	awk -v n="$1" 'BEGIN { if (n + 0 >= 10) printf "%d", n + 0.5; else printf "%.1f", n }'
}

run_segment() {
	# Index from this pill's (sym)link name: gpu_pctN.sh -> N.
	local name="${TMUX_POWERLINE_CUR_SEGMENT_NAME:-gpu_pct0.sh}"
	local idx="${name#gpu_pct}"; idx="${idx%.sh}"
	case "$idx" in '' | *[!0-9]*) idx=0 ;; esac

	stat_sample
	local usage vendor icon num=""
	usage=$(stat_gpu_usage "$idx")
	case "$usage" in '' | *[!0-9.]*) return 0 ;; esac   # no GPU at this index
	vendor=$(stat_gpu_vendor "$idx")
	icon="${GPU_VENDOR_ICON[$vendor]:-$GPU_ICON}"

	# With more than one discrete GPU, tag each pill with its 1-based index
	# badge so same-vendor cards are distinguishable. A single GPU needs none.
	if [ "${STAT_GPU_N:-0}" -gt 1 ]; then
		num=" $(stat_num_badge "$((idx + 1))")"
	fi

	# Order: usage%, VRAM%, then temperature LAST.
	local out temp vused vtotal
	out="${GPU_PREFIX_ICON} ${icon}${num} $(__format_pct "$usage")%"

	# VRAM as used/total percent, when a total is known.
	vused=$(stat_gpu_vused "$idx"); vtotal=$(stat_gpu_vtotal "$idx")
	case "$vused" in '' | *[!0-9]*) vused=0 ;; esac
	case "$vtotal" in
		'' | 0 | *[!0-9]*) ;;
		*) out="${out} ${VRAM_ICON}$((vused * 100 / vtotal))%" ;;
	esac

	# Temperature last (integer, no decimal); 0 means asleep/unknown -> skip.
	temp=$(stat_gpu_temp "$idx")
	case "$temp" in '' | 0 | *[!0-9]*) ;; *) out="${out} ${THERMO_ICON}${temp}°" ;; esac

	echo "$out"
	return 0
}
