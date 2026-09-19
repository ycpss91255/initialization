# shellcheck shell=bash
# Override of tmux-powerline's bundled battery segment, aligned with the cpu/
# mem/gpu telemetry pills:
# - Charge % uses the same decimal rule (integer at/above 10%, one decimal
#   below) via __format_pct.
# - The pill emits ONLY icon + number (no #[bg=...]); the theme sets this
#   segment's declared bg to a gradient of the charge level (low = red, high =
#   blue -- the reverse of cpu, since a LOW battery is the alarming end) and
#   draws the black-line divider, exactly like the other telemetry pills.
# - On AC power (any Mains supply online) it shows just the adapter icon; on
#   battery it shows a charge-level icon (high >= 66, med >= 33, low) + the %.
# Battery/AC state comes from the shared sampler helper stat_battery so the
# displayed % matches the colour the theme computed from the same reading.

# shellcheck source=../lib_stat.sh
source "${XDG_CONFIG_HOME:-$HOME/.config}/tmux-powerline/lib_stat.sh"

ADAPTER_ICON="󱐥"
BATTERY_ICON_LOW="󱊡"
BATTERY_ICON_MED="󱊢"
BATTERY_ICON_HIGH="󱊣"
MED_ICON_THRESHOLD=33
HIGH_ICON_THRESHOLD=66

# Drop the decimal at/above 10%, keep one decimal place below it.
__format_pct() {
	awk -v n="$1" 'BEGIN { if (n + 0 >= 10) printf "%d", n + 0.5; else printf "%.1f", n }'
}

# Charge-level icon for a given integer percent.
__battery_icon() {
	local pct="$1"
	if [ "$pct" -ge "$HIGH_ICON_THRESHOLD" ]; then
		echo "$BATTERY_ICON_HIGH"
	elif [ "$pct" -ge "$MED_ICON_THRESHOLD" ]; then
		echo "$BATTERY_ICON_MED"
	else
		echo "$BATTERY_ICON_LOW"
	fi
}

run_segment() {
	local level ac
	read -r level ac < <(stat_battery)

	# No battery (e.g. desktop): render nothing so the pill drops.
	case "$level" in '' | *[!0-9]*) return 0 ;; esac

	if [ "$ac" = 1 ]; then
		echo "$ADAPTER_ICON"
		return 0
	fi
	echo "$(__battery_icon "$level") $(__format_pct "$level")%"
	return 0
}
