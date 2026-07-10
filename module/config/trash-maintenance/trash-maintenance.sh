#!/usr/bin/env bash
# Trash maintenance (deployed artifact of module/trash-maintenance.module.sh):
#   1. Purge items older than MAX_DAYS (trash-empty).
#   2. If ~/.local/share/Trash/files is still over MAX_GB, evict oldest-first
#      (by info/*.trashinfo mtime) until under the cap.
# Scheduled by the module via a daily user crontab entry.
#
# Overridable via env: MAX_DAYS (default 90), MAX_GB (default 30).
#
# This is an always-act maintenance script, so it keeps `set -euo pipefail`
# (ADR-0007 always-act semantics). The historical bugs that made it silently
# no-op were fixed per issue #277:
#   - trash-empty is invoked WITHOUT `-f` (that option does not exist on older
#     trash-cli, e.g. 0.17.x, and is a no-op on newer versions).
#   - current_kb() no longer lets a partial/permission-denied `du` failure abort
#     the whole run under pipefail/set -e before the size-cap check runs — it
#     captures whatever total du printed and defaults to 0.
set -euo pipefail

MAX_DAYS="${MAX_DAYS:-90}"
MAX_GB="${MAX_GB:-30}"

TRASH_DIR="${HOME}/.local/share/Trash"
INFO_DIR="${TRASH_DIR}/info"
FILES_DIR="${TRASH_DIR}/files"

log() { printf '[trash-maintenance] %s\n' "$*"; }

if ! command -v trash-empty >/dev/null 2>&1; then
    log "trash-empty not found; install trash-cli first" >&2
    exit 1
fi

# #277 bug 1: no `-f` — portable across trash-cli 0.17.x .. 0.23.x, and
# non-interactive is already the default in both.
log "Purging items older than ${MAX_DAYS} days..."
trash-empty "${MAX_DAYS}" 2>&1 || true

[[ -d "${FILES_DIR}" ]] || exit 0

# #277 bug 2: du may exit non-zero on a permission-denied subpath while still
# printing a usable (partial) total. Capture that total and swallow the failing
# exit status so `set -e`/`pipefail` cannot abort the run here. Default to 0 so
# the arithmetic comparison below never sees an empty value.
current_kb() {
    local _kb
    _kb="$(du -sk "${FILES_DIR}" 2>/dev/null | awk '{print $1}')" || true
    printf '%s' "${_kb:-0}"
}

max_kb=$((MAX_GB * 1024 * 1024))
cur_kb="$(current_kb)"
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
    rm -rf -- "${FILES_DIR:?}/${base}" 2>/dev/null || true
    rm -f -- "${info}"
    removed=$((removed + 1))
    cur_kb="$(current_kb)"
    if (( cur_kb <= max_kb )); then
        break
    fi
done < <(find "${INFO_DIR}" -maxdepth 1 -name '*.trashinfo' -printf '%T@\t%p\n' 2>/dev/null | sort -n | cut -f2-)

log "Evicted ${removed} items. Final size: $((cur_kb / 1024 / 1024)) GB"
