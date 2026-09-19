# shellcheck shell=bash
# Default Theme
# Catppuccin Frappe palette (bubble-style separators, see erikw/tmux-powerline#344).
thm_sky="#99d1db"
thm_rosewater="#f2d5cf"
thm_mauve="#ca9ee6"
thm_red="#e78284"
thm_peach="#ef9f76"
thm_yellow="#e5c890"
thm_green="#a6d189"
thm_teal="#81c8be"
thm_blue="#8caaee"
thm_lavender="#babbf1"
thm_sapphire="#85c1dc"
thm_pink="#f4b8e4"
thm_text="#c6d0f5"
thm_base="#303446"

# If changes made here does not take effect, then try to re-create the tmux session to force reload.

if patched_font_in_use; then
	TMUX_POWERLINE_SEPARATOR_LEFT_BOLD=""
	TMUX_POWERLINE_SEPARATOR_LEFT_THIN=""
	TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD=""
	TMUX_POWERLINE_SEPARATOR_RIGHT_THIN=""
else
	TMUX_POWERLINE_SEPARATOR_LEFT_BOLD="◀"
	TMUX_POWERLINE_SEPARATOR_LEFT_THIN="❮"
	TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD="▶"
	TMUX_POWERLINE_SEPARATOR_RIGHT_THIN="❯"
fi

# See Color formatting section below for details on what colors can be used here.
TMUX_POWERLINE_DEFAULT_BACKGROUND_COLOR=${TMUX_POWERLINE_DEFAULT_BACKGROUND_COLOR:-"${thm_base}"}
TMUX_POWERLINE_DEFAULT_FOREGROUND_COLOR=${TMUX_POWERLINE_DEFAULT_FOREGROUND_COLOR:-"${thm_text}"}
# shellcheck disable=SC2034
TMUX_POWERLINE_SEG_AIR_COLOR=$(air_color)

TMUX_POWERLINE_DEFAULT_LEFTSIDE_SEPARATOR=${TMUX_POWERLINE_DEFAULT_LEFTSIDE_SEPARATOR:-$TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD}
TMUX_POWERLINE_DEFAULT_RIGHTSIDE_SEPARATOR=${TMUX_POWERLINE_DEFAULT_RIGHTSIDE_SEPARATOR:-$TMUX_POWERLINE_SEPARATOR_LEFT_BOLD}

# See `man tmux` for additional formatting options for the status line.
# The `format regular` and `format inverse` functions are provided as conveniences

# shellcheck disable=SC2128
if [ -z "$TMUX_POWERLINE_WINDOW_STATUS_CURRENT" ]; then
	TMUX_POWERLINE_WINDOW_STATUS_CURRENT=(
		"#[$(format inverse)]"
		"$TMUX_POWERLINE_DEFAULT_LEFTSIDE_SEPARATOR"
		" #I#F "
		"$TMUX_POWERLINE_SEPARATOR_RIGHT_THIN"
		" #W "
		"#[$(format regular)]"
		"$TMUX_POWERLINE_DEFAULT_LEFTSIDE_SEPARATOR"
	)
fi

# shellcheck disable=SC2128
if [ -z "$TMUX_POWERLINE_WINDOW_STATUS_STYLE" ]; then
	TMUX_POWERLINE_WINDOW_STATUS_STYLE=(
		"$(format regular)"
	)
fi

# shellcheck disable=SC2128
if [ -z "$TMUX_POWERLINE_WINDOW_STATUS_FORMAT" ]; then
	TMUX_POWERLINE_WINDOW_STATUS_FORMAT=(
		"#[$(format regular)]"
		"  #I#{?window_flags,#F, } "
		"$TMUX_POWERLINE_SEPARATOR_RIGHT_THIN"
		" #W "
	)
fi

# Format: segment_name [background_color|default_bg_color] [foreground_color|default_fg_color] [non_default_separator|default_separator] [separator_background_color|no_sep_bg_color]
#                      [separator_foreground_color|no_sep_fg_color] [spacing_disable|no_spacing_disable] [separator_disable|no_separator_disable]
#
# * background_color and foreground_color. Color formatting (see `man tmux` for complete list):
#   * Named colors, e.g. black, red, green, yellow, blue, magenta, cyan, white
#   * Hexadecimal RGB string e.g. #ffffff
#   * 'default_fg_color|default_bg_color' for the default theme bg and fg color
#   * 'default' for the default tmux color.
#   * 'terminal' for the terminal's default background/foreground color
#   * The numbers 0-255 for the 256-color palette. Run `tmux-powerline/color-palette.sh` to see the colors.
# * non_default_separator - specify an alternative character for this segment's separator
#   * 'default_separator' for the theme default separator
# * separator_background_color - specify a unique background color for the separator
#   * 'no_sep_bg_color' for using the default coloring for the separator
# * separator_foreground_color - specify a unique foreground color for the separator
#   * 'no_sep_fg_color' for using the default coloring for the separator
# * spacing_disable - remove space on left, right or both sides of the segment:
#   * "no_spacing_disable" - don't disable spacing (default)
#   * "left_disable" - disable space on the left
#   * "right_disable" - disable space on the right
#   * "both_disable" - disable spaces on both sides
#   * - any other character/string produces no change to default behavior (eg "none", "X", etc.)
#
# * separator_disable - disables drawing a separator on this segment, very useful for segments
#   with dynamic background colours (eg tmux_mem_cpu_load):
#   * "no_separator_disable" - don't disable the separator (default)
#   * "separator_disable" - disables the separator
#   * - any other character/string produces no change to default behavior
#
# Example segment with separator disabled and right space character disabled:
# "hostname 33 0 {TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD} 0 0 right_disable separator_disable"
#
# Example segment with spacing characters disabled on both sides but not touching the default coloring:
# "hostname 33 0 {TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD} no_sep_bg_color no_sep_fg_color both_disable"
#
# Example segment with changing the foreground color of the default separator:
# "hostname 33 0 default_separator no_sep_bg_color 120"
#
## Note that although redundant the non_default_separator, separator_background_color and
# separator_foreground_color options must still be specified so that appropriate index
# of options to support the spacing_disable and separator_disable features can be used
# The default_* and no_* can be used to keep the default behaviour.

# Layout split:
#   LEFT  = session/window + date + tmux mode (prefix) + mail + music
#   RIGHT = machine identity (hostname, IP) + system telemetry
#           (battery, mem, GPU(s), cpu)
#
# The session segment shows ONLY the session name (not window/pane).
export TMUX_POWERLINE_SEG_TMUX_SESSION_INFO_FORMAT="#S"

# Responsive hiding: when the terminal is narrow, segments are dropped from the
# LOWEST priority up so the highest-priority ones survive longest. Priority
# (kept longest first): session name, battery, prefix, date, cpu, mem, then
# everything else. Each segment shows only when the client width (columns) is
# at least its threshold; higher priority -> lower threshold -> hidden later.
# The width comes from the @cw global option, published by status-length.sh
# from a resize/attach hook -- a status-line "#()" command has no client
# context of its own, so it cannot read #{client_width} directly.
_cw=$(tmux show -gv @cw 2>/dev/null)
case "$_cw" in '' | *[!0-9]*) _cw=9999 ;; esac
# High priority (kept longest -> shorter). session name has no threshold.
_W_BATTERY=40     # battery
_W_PREFIX=50      # prefix (mode) indicator -- tiny, kept long, sits before date
_W_DATE=55        # date
_W_CPU=70         # cpu
_W_MEM=85         # mem
# Everything else (lower priority, hidden first -> widest thresholds):
_W_NET1=95        # primary network interface (highest route priority)
_W_HOSTNAME=115
_W_NET2=125       # secondary network interfaces (2nd+)
_W_GPU=140        # GPU pills
_W_DISK=145       # disk usage pill
_W_MAIL=155
_W_MUSIC=170
# Per-host mail toggle: LG14's Gmail app password was revoked, so mail is off
# here; the remote's keyring works and provisioning flips this to 1 there.
_MAIL_ENABLED=0

# Position order: session name, date, prefix (mode), mail, music. (The prefix
# indicator sits AFTER date positionally but has a higher HIDE priority -- one
# tier above date -- so on a narrowing terminal date drops before it does.)
# shellcheck disable=SC1143,SC2128
if [ -z "$TMUX_POWERLINE_LEFT_STATUS_SEGMENTS" ]; then
    _L=("tmux_session_info ${thm_blue} ${thm_base}")
    [ "$_cw" -ge "$_W_DATE" ] \
        && _L+=("date ${thm_teal} ${thm_base} ${TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD}")
    [ "$_cw" -ge "$_W_PREFIX" ] \
        && _L+=("mode_indicator ${thm_yellow} ${thm_base} ${TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD}")
    [ "$_MAIL_ENABLED" = 1 ] && [ "$_cw" -ge "$_W_MAIL" ] \
        && _L+=("mailcount ${thm_red} ${thm_base} ${TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD}")
    [ "$_cw" -ge "$_W_MUSIC" ] \
        && _L+=("now_playing ${thm_green} ${thm_base} ${TMUX_POWERLINE_SEPARATOR_RIGHT_BOLD}")
    TMUX_POWERLINE_LEFT_STATUS_SEGMENTS=("${_L[@]}")
fi

# Dynamic mem / GPU / cpu pill backgrounds: sample once (shared non-blocking
# sampler) and derive a blue->red gradient for each from its own usage %, so
# every telemetry pill's DECLARED bg is its gradient. The plugin then draws
# the round separator to each pill's left in that same color, so the
# separators blend with the pills instead of staying fixed. Each segment
# reuses the SAME cached sample, so its number matches its color exactly.
# One gpu bg per possible discrete GPU (up to 9, matching gpu_pct0..8);
# indices past the actual GPU count render nothing (bg unused).
_mem_pill_bg="${thm_rosewater}"
_cpu_pill_bg="${thm_peach}"
_bat_pill_bg="${thm_teal}"
_disk_pill_bg="${thm_teal}"
_show_battery=1   # hidden when there is no battery, or plugged in above 80%
_gpu_bg=(); for _gi in 0 1 2 3 4 5 6 7 8; do _gpu_bg[_gi]="${thm_teal}"; done
_net_bg=(); for _ni in 0 1 2 3 4 5; do _net_bg[_ni]="${thm_yellow}"; done
if [ -r "${XDG_CONFIG_HOME:-$HOME/.config}/tmux-powerline/lib_stat.sh" ]; then
    # shellcheck source=../lib_stat.sh
    source "${XDG_CONFIG_HOME:-$HOME/.config}/tmux-powerline/lib_stat.sh"
    stat_sample
    _mem_pill_bg="$(stat_gradient "${STAT_MEM_PCT:-0}")"
    _cpu_pill_bg="$(stat_gradient "${STAT_CPU_PCT:-0}")"
    case "${STAT_DISK_PCT}" in '' | *[!0-9]*) ;; *) _disk_pill_bg="$(stat_gradient "$STAT_DISK_PCT")" ;; esac
    for _gi in 0 1 2 3 4 5 6 7 8; do
        _gu="$(stat_gpu_usage "$_gi")"
        case "$_gu" in
            '' | *[!0-9.]*) ;;
            *) _gpu_bg[_gi]="$(stat_gradient "$_gu")" ;;
        esac
    done
    # Battery colour: green while on AC power (plugged in = good). On battery
    # it is a REVERSED gradient (low charge = red, since a low battery is the
    # alarming end, unlike a low cpu load): feed (100 - level) to the same
    # blue->red gradient -> full = blue, empty = red.
    read -r _bl _ba < <(stat_battery)
    if [ "$_ba" = 1 ]; then
        _bat_pill_bg="${thm_green}"
    else
        case "$_bl" in
            '' | *[!0-9]*) ;;
            *) _bat_pill_bg="$(stat_gradient "$((100 - _bl))")" ;;
        esac
    fi
    # Hide the power pill when there is no battery, or when plugged in AND
    # comfortably charged (on AC above 80%): nothing useful to watch there.
    case "$_bl" in
        '' | *[!0-9]*) _show_battery=0 ;;
        *) { [ "$_ba" = 1 ] && [ "$_bl" -gt 80 ]; } && _show_battery=0 ;;
    esac
    # Network interfaces: colour each net_if pill by its type, in hues kept
    # clear of the telemetry side (whose blue->red gradient plus green AC
    # battery already occupy blue/purple/red/green). wifi yellow, eth teal,
    # vpn pink -- distinct from that gradient AND from each other.
    stat_nets
    for _ni in 0 1 2 3 4 5; do
        case "$(stat_net_type "$_ni")" in
            wifi) _net_bg[_ni]="${thm_yellow}" ;;
            eth)  _net_bg[_ni]="${thm_teal}" ;;
            vpn)  _net_bg[_ni]="${thm_pink}" ;;
        esac
    done
fi

# Telemetry cluster (mem, GPU(s) 0..8, cpu) -- every colour-changing pill is
# divided by a thin black vertical bar (left-edge block glyph, fg forced to
# #000000) whose separator background is the pill's OWN colour, so the black
# line has the previous pill's colour on its left and this pill's colour on
# its right (a black divider with a colour on each side). The static pills
# before them (hostname, IP) keep the normal round bubble; battery joins the
# telemetry pills (gradient bg + black divider). The up-to-9 GPU pills are
# generated in a loop; indices past the detected GPU count render nothing.
_tele_divider="▏"
_tele_pill() {   # name bg -> a black-line-divided segment spec string
    printf '%s %s %s %s %s #000000' \
        "$1" "$2" "${thm_base}" "${_tele_divider}" "$2"
}
# shellcheck disable=SC1143,SC2128
if [ -z "$TMUX_POWERLINE_RIGHT_STATUS_SEGMENTS" ]; then
    _R=()
    [ "$_cw" -ge "$_W_HOSTNAME" ] \
        && _R+=("hostname ${thm_mauve} ${thm_base} ${TMUX_POWERLINE_SEPARATOR_LEFT_BOLD}")
    # One pill per active network interface (wifi / eth / vpn), like the GPU
    # pills. The PRIMARY interface (index 0, highest route priority) is kept
    # longer than the secondary ones (2nd+). Static round bubbles (no gradient),
    # coloured by interface type.
    for _ni in {0..5}; do
        if [ "$_ni" -eq 0 ]; then _nthr="$_W_NET1"; else _nthr="$_W_NET2"; fi
        [ "$_cw" -ge "$_nthr" ] \
            && _R+=("net_if${_ni} ${_net_bg[_ni]} ${thm_base} ${TMUX_POWERLINE_SEPARATOR_LEFT_BOLD}")
    done
    # Telemetry pills (black-line dividers), gated by width and battery
    # visibility. GPU pills drop below _W_GPU.
    # Telemetry order: battery (usually hidden on AC), cpu, gpu(s), mem, disk.
    { [ "$_show_battery" = 1 ] && [ "$_cw" -ge "$_W_BATTERY" ]; } \
        && _R+=("$(_tele_pill battery "${_bat_pill_bg}")")
    [ "$_cw" -ge "$_W_CPU" ] && _R+=("$(_tele_pill cpu_pct "${_cpu_pill_bg}")")
    if [ "$_cw" -ge "$_W_GPU" ]; then
        for _gi in {0..8}; do _R+=("$(_tele_pill "gpu_pct${_gi}" "${_gpu_bg[_gi]}")"); done
    fi
    [ "$_cw" -ge "$_W_MEM" ] && _R+=("$(_tele_pill mem_pct "${_mem_pill_bg}")")
    [ "$_cw" -ge "$_W_DISK" ] && _R+=("$(_tele_pill disk "${_disk_pill_bg}")")
    TMUX_POWERLINE_RIGHT_STATUS_SEGMENTS=("${_R[@]}")
fi
