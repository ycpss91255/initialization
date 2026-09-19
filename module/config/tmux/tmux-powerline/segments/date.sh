# shellcheck shell=bash
# Override of tmux-powerline's bundled date segment.
# Appends a Roman numeral (I-VII, ISO weekday via `date +%u`,
# 1=Monday..7=Sunday) in place of the plain "%a" English abbreviation, so
# the weekday shows as a symbol instead of text. Plain Unicode roman
# numerals (U+2160-U+2166, Number Forms) render at text height -- visually
# larger than the icon-region md-roman_numeral glyphs -- and need no Nerd
# Font (tmux cannot enlarge a single glyph, so glyph choice is the only lever).

TMUX_POWERLINE_SEG_DATE_FORMAT="${TMUX_POWERLINE_SEG_DATE_FORMAT:-%F}"

WEEKDAY_ICONS=(
	"Ⅰ"
	"Ⅱ"
	"Ⅲ"
	"Ⅳ"
	"Ⅴ"
	"Ⅵ"
	"Ⅶ"
)

generate_segmentrc() {
	read -r -d '' rccontents <<EORC
# date(1) format for the date. If you don't, for some reason, like ISO 8601 format you might want to have "%D" or "%m/%d/%Y".
export TMUX_POWERLINE_SEG_DATE_FORMAT="${TMUX_POWERLINE_SEG_DATE_FORMAT}"
EORC
	echo "$rccontents"
}

run_segment() {
	local dow
	dow=$(date +%u)
	echo "$(date +"$TMUX_POWERLINE_SEG_DATE_FORMAT") ${WEEKDAY_ICONS[$((dow - 1))]}"
	return 0
}
