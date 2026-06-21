#!/usr/bin/env bash
# lib/state_migrate.sh — forward-only state.json schema migration (ADR-0008)
#
# On startup the engine reads state.json, which carries a SemVer `version`
# field (PRD §10.1). When the tool's STATE_SCHEMA_VERSION (lib/state.sh) is
# newer than the on-disk version, the chain of migrate_<from>_to_<to>()
# functions is replayed in order to bring the file up to the current shape.
#
# Policy (ADR-0008):
#   - version unknown / not in the chain        -> refuse, exit 1
#   - version > current (newer-than-tool)       -> refuse, exit 1 (no downgrade)
#   - version < current                         -> back up, migrate, atomic write
#   - version == current                        -> no-op
#
# A mandatory backup (state.json.v<old>.bak + state.json.bak.latest symlink)
# is written before any migration; if the backup write fails the migration is
# aborted (the original file is never touched). Each hop is idempotent and
# operates on a parsed JSON payload in memory, never on the file directly.
#
# Public API:
#   state_migrate_run
#     Run the migration pipeline against the engine's state.json. Returns 0 on
#     success or no-op, 1 on any failure (the caller treats this as fatal).
#
# Migration chain (oldest -> newest):
#   0.1.0 -> 0.2.0 : split the apt-essentials bundle into per-tool modules
#                    (ADR-0026). See migrate_0_1_0_to_0_2_0.
#
# Dependencies: jq. Sources nothing; relies on STATE_SCHEMA_VERSION and
# state_get_path / state_validate_file from lib/state.sh (loaded earlier).

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# Ordered list of schema versions in the migration chain. Each adjacent pair
# (i, i+1) must have a migrate_<i>_to_<i+1>() function defined below.
STATE_MIGRATE_CHAIN=("0.1.0" "0.2.0")

# ── helpers ──────────────────────────────────────────────────────────────────

# _state_migrate_underscore <semver> — "0.1.0" -> "0_1_0" (function-name safe).
_state_migrate_underscore() {
    printf '%s' "${1//./_}"
}

# _state_migrate_chain_index <version> — print the 0-based position of
# <version> in STATE_MIGRATE_CHAIN, or nothing (return 1) when not found.
_state_migrate_chain_index() {
    local _want="$1" _i
    for _i in "${!STATE_MIGRATE_CHAIN[@]}"; do
        if [[ "${STATE_MIGRATE_CHAIN[$_i]}" == "${_want}" ]]; then
            printf '%s' "${_i}"
            return 0
        fi
    done
    return 1
}

# _state_migrate_backup <state-path> <old-version>
#   Copy state.json -> state.json.v<old>.bak and point the
#   state.json.bak.latest symlink at it. Returns 1 if the backup write fails
#   (ADR-0008: refuse to proceed without a backup).
_state_migrate_backup() {
    local _path="$1" _old="$2"
    local _bak="${_path}.v${_old}.bak"
    local _latest="${_path}.bak.latest"

    if ! cp -f "${_path}" "${_bak}"; then
        printf "[state_migrate] ERROR: failed to write backup %s — aborting migration\n" \
            "${_bak}" >&2
        return 1
    fi
    # Best-effort latest pointer; a symlink failure is non-fatal (the .bak
    # itself is the durable artifact AC-30 checks for).
    ln -sf "$(basename -- "${_bak}")" "${_latest}" 2>/dev/null || true
    printf "[state_migrate] backed up %s -> %s\n" "${_path}" "${_bak}" >&2
    return 0
}

# ── migration steps (one function per hop, ADR-0008 naming) ──────────────────

# migrate_0_1_0_to_0_2_0 <payload-json>
#   ADR-0026: the apt-essentials bundle becomes per-tool modules. When an
#   installed `apt-essentials` entry exists, replace it with installed entries
#   for the five packages the bundle actually installed and that are now
#   modules (git, vim, curl, wget, jq). build-essential/htop/unzip are NOT
#   added — the old bundle never installed them. Each replacement is marked
#   manual=true, depends_on=[], version_provided="apt-managed", carrying the
#   bundle's installed_at / installed_by forward. The machine-specific `local`
#   sub-object is rebuilt empty. The old apt-essentials entry (and its
#   frozen_pkgs / frozen_platform from ADR-0011) is dropped. ca-certificates
#   stays an untracked system apt package.
#
# Reads the payload on stdin-equivalent ($1) and prints the migrated payload.
# Idempotent: if apt-essentials is absent, the payload passes through with only
# the version field bumped.
migrate_0_1_0_to_0_2_0() {
    local _payload="$1"
    local _split=("git" "vim" "curl" "wget" "jq")
    local _split_json
    _split_json="$(printf '%s\n' "${_split[@]}" | jq -R . | jq -sc .)"

    jq \
        --argjson split "${_split_json}" \
        '
        # Bump schema version regardless.
        .version = "0.2.0"
        # Only act when an apt-essentials entry exists.
        | if (.installed | has("apt-essentials")) then
            (.installed["apt-essentials"]) as $old
            | (($old.synced.installed_at) // null) as $at
            | (($old.synced.installed_by) // null) as $by
            # Drop the bundle entry.
            | del(.installed["apt-essentials"])
            # Add a per-tool entry for each split package (idempotent: an
            # existing manual entry for a tool is overwritten with the same
            # forward-only shape — only synced is rebuilt, local is preserved).
            | reduce $split[] as $tool (.;
                .installed[$tool] = {
                    synced: {
                        manual: true,
                        depends_on: [],
                        version_provided: "apt-managed",
                        installed_at: $at,
                        installed_by: $by
                    },
                    local: ((.installed[$tool].local) // {})
                }
              )
          else
            .
          end
        ' <<<"${_payload}"
}

# ── runner ───────────────────────────────────────────────────────────────────

state_migrate_run() {
    _state_require_jq || return 1
    state_validate_file || return 1

    local _path; _path="$(state_get_path)"
    [[ -f "${_path}" ]] || return 0   # nothing to migrate (fresh install)

    local _current="${STATE_SCHEMA_VERSION}"
    local _onfile
    _onfile="$(jq -r '.version // empty' "${_path}" 2>/dev/null)" || _onfile=""

    if [[ -z "${_onfile}" ]]; then
        printf "[state_migrate] ERROR: %s has no 'version' field — cannot migrate\n" \
            "${_path}" >&2
        return 1
    fi

    # Already current.
    [[ "${_onfile}" == "${_current}" ]] && return 0

    # Unknown on-file version (not in the chain) — ADR-0008 refuse.
    local _from_idx _to_idx
    if ! _from_idx="$(_state_migrate_chain_index "${_onfile}")"; then
        printf "[state_migrate] ERROR: state.json was written by an unknown tool version \"%s\". No migration path to current \"%s\". Restore an older state.json.v*.bak or rm state.json (loses install tracking).\n" \
            "${_onfile}" "${_current}" >&2
        return 1
    fi
    if ! _to_idx="$(_state_migrate_chain_index "${_current}")"; then
        printf "[state_migrate] ERROR: current schema version \"%s\" is not registered in the migration chain (bug)\n" \
            "${_current}" >&2
        return 1
    fi

    # Newer-than-tool — ADR-0008 refuse (no downgrade).
    if (( _from_idx > _to_idx )); then
        printf "[state_migrate] ERROR: state.json was written by a newer tool (\"%s\" > \"%s\"); downgrade is not supported — git checkout the matching tool version or restore an older .bak.\n" \
            "${_onfile}" "${_current}" >&2
        return 1
    fi

    # Backup before mutating (mandatory; abort if it fails).
    _state_migrate_backup "${_path}" "${_onfile}" || return 1

    # Replay the chain in a subshell-safe loop, in memory.
    local _payload; _payload="$(cat "${_path}")"
    local _i _fromv _tov _fn
    for (( _i = _from_idx; _i < _to_idx; _i++ )); do
        _fromv="${STATE_MIGRATE_CHAIN[$_i]}"
        _tov="${STATE_MIGRATE_CHAIN[$((_i + 1))]}"
        _fn="migrate_$(_state_migrate_underscore "${_fromv}")_to_$(_state_migrate_underscore "${_tov}")"
        if ! declare -F "${_fn}" >/dev/null; then
            printf "[state_migrate] ERROR: missing migration step %s\n" "${_fn}" >&2
            return 1
        fi
        printf "[state_migrate] applying %s -> %s\n" "${_fromv}" "${_tov}" >&2
        if ! _payload="$("${_fn}" "${_payload}")" || [[ -z "${_payload}" ]]; then
            printf "[state_migrate] ERROR: migration step %s failed — state.json left unchanged\n" \
                "${_fn}" >&2
            return 1
        fi
    done

    # Atomic write (tmp-file + rename; same filesystem per ADR-0008).
    local _tmp="${_path}.tmp.$$"
    if ! printf '%s\n' "${_payload}" > "${_tmp}"; then
        printf "[state_migrate] ERROR: failed to write migrated payload to %s\n" "${_tmp}" >&2
        rm -f "${_tmp}"
        return 1
    fi
    mv -f "${_tmp}" "${_path}"
    printf "[state_migrate] migrated %s to schema %s\n" "${_path}" "${_current}" >&2
    return 0
}
