#!/usr/bin/env bash
width=$(tmux display-message -p '#{pane_width}' 2>/dev/null)
if [[ -n "$width" ]]; then
  # ccstatusline's flexMode:"full" subtracts a further 6 internally, so -8
  # here yields a net effective width of pane_width - 14 — wide enough to
  # avoid mid-unit truncation on panes >= 80 cols. (#231)
  export CCSTATUSLINE_WIDTH=$((width - 8))
fi
# ccstatusline replaces all U+0020 spaces with NBSP (U+00A0) before printing,
# so the sub-unit strippers below must match on NBSP, not a plain space.
NBSP=$'\xc2\xa0'
exec ccstatusline \
  | sed \
      -e 's/\([0-9]\+\)\.[0-9]\+%/\1%/g' \
      -e "s/\([0-9]\+d\)\(${NBSP}[0-9a-z.]\+\)\+/\1/g" \
      -e "s/\([0-9]\+hr\)\(${NBSP}[0-9a-z.]\+\)\+/\1/g" \
      -e 's/\([0-9]\+[a-z]\)\.\.\./\1/g' \
      -e 's/\([0-9]\+\)hr/\1h/g'
