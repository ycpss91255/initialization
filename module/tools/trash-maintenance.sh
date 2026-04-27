#!/usr/bin/env bash
# Trash 自動維護：
#   1. 砍掉超過 MAX_DAYS 天的項目（trash-empty）
#   2. 若 ~/.local/share/Trash/files 仍超過 MAX_GB，從最舊的開始砍直到低於上限
# 排程：crontab 每日跑（見章節「Trash 自動維護」於 TODO.md）
#
# 環境變數可覆蓋：MAX_DAYS（預設 90）、MAX_GB（預設 50）
set -euo pipefail

MAX_DAYS="${MAX_DAYS:-90}"
MAX_GB="${MAX_GB:-50}"

TRASH_DIR="${HOME}/.local/share/Trash"
INFO_DIR="${TRASH_DIR}/info"
FILES_DIR="${TRASH_DIR}/files"

log() { printf '[trash-maintenance] %s\n' "$*"; }

if ! command -v trash-empty >/dev/null 2>&1; then
    log "trash-empty not found; install trash-cli first" >&2
    exit 1
fi

log "Purging items older than ${MAX_DAYS} days..."
trash-empty -f "${MAX_DAYS}" 2>&1 || true

[[ -d "${FILES_DIR}" ]] || exit 0

current_kb() { du -sk "${FILES_DIR}" 2>/dev/null | awk '{print $1}'; }

max_kb=$((MAX_GB * 1024 * 1024))
cur_kb=$(current_kb)
log "Current trash size: $((cur_kb / 1024 / 1024)) GB / cap: ${MAX_GB} GB"

if (( cur_kb <= max_kb )); then
    log "Under cap, done."
    exit 0
fi

log "Over cap, evicting oldest items..."
removed=0
while IFS= read -r info; do
    base="${info##*/}"
    base="${base%.trashinfo}"
    rm -rf -- "${FILES_DIR}/${base}" 2>/dev/null || true
    rm -f -- "${info}"
    removed=$((removed + 1))
    cur_kb=$(current_kb)
    if (( cur_kb <= max_kb )); then
        break
    fi
done < <(find "${INFO_DIR}" -maxdepth 1 -name '*.trashinfo' -printf '%T@\t%p\n' 2>/dev/null | sort -n | cut -f2-)

log "Evicted ${removed} items. Final size: $((cur_kb / 1024 / 1024)) GB"
