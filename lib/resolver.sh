#!/usr/bin/env bash
# lib/resolver.sh — dependency resolver (topological sort + cycle detection)
#
# Per docs/architecture.md §3.3 and §18.2 Q-A1 (Kahn's algorithm).
#
# Public API:
#   resolver_resolve <module> [<module> ...]
#     Collect transitive dependencies from MODULES_DEPS (populated by
#     registry_load_all), topo-sort with Kahn's algorithm, print the
#     install order on stdout (one name per line, deps first).
#     Returns:
#       0 — sorted order printed
#       2 — unknown module name (not in registry)
#       5 — cycle detected (per PRD §7.4 exit code table)
#
#   resolver_collect_transitive <module> [<module> ...]
#     Print the transitive dep closure (unsorted) on stdout, one per line.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf "Warn: %s is a library, not a executable script.\n" "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# ── Internal: collect transitive deps via iterative DFS ──────────────────────

_resolver_collect_deps() {
    # Args: <out-name-ref> <module> [<module> ...]
    local -n _out_set="$1"; shift

    local -a _stack=("$@")
    local _node _dep

    while [[ "${#_stack[@]}" -gt 0 ]]; do
        _node="${_stack[-1]}"
        unset '_stack[-1]'

        [[ -n "${_out_set[${_node}]:-}" ]] && continue
        _out_set["${_node}"]=1

        local _deps_str="${MODULES_DEPS[${_node}]:-}"
        if [[ -n "${_deps_str}" ]]; then
            # shellcheck disable=SC2206
            local -a _deps=(${_deps_str})
            for _dep in "${_deps[@]}"; do
                [[ -z "${_dep}" ]] && continue
                [[ -z "${_out_set[${_dep}]:-}" ]] && _stack+=("${_dep}")
            done
        fi
    done
}

# ── Public: transitive closure (unordered) ───────────────────────────────────

resolver_collect_transitive() {
    local -A _closure=()
    _resolver_collect_deps _closure "$@"

    local _name
    for _name in "${!_closure[@]}"; do
        printf "%s\n" "${_name}"
    done
}

# ── Public: Kahn topological sort ────────────────────────────────────────────

resolver_resolve() {
    local -a _requested=("$@")

    if [[ "${#_requested[@]}" -eq 0 ]]; then
        return 0
    fi

    local _name
    for _name in "${_requested[@]}"; do
        if [[ -z "${MODULES_NAME[${_name}]:-}" ]]; then
            printf "[resolver] ERROR: unknown module %s\n" "${_name}" >&2
            return 2
        fi
    done

    # 1. Closure (transitive deps).
    local -A _closure=()
    _resolver_collect_deps _closure "${_requested[@]}"

    # 2. Validate every closure member exists.
    for _name in "${!_closure[@]}"; do
        if [[ -z "${MODULES_NAME[${_name}]:-}" ]]; then
            printf "[resolver] ERROR: module %s depends on unknown module %s\n" \
                "${_requested[0]}" "${_name}" >&2
            return 2
        fi
    done

    # 3. In-degree per node (edge dep -> dependent; in-degree counts deps).
    local -A _indeg=()
    for _name in "${!_closure[@]}"; do
        _indeg["${_name}"]=0
    done
    local _dep _deps_str
    local -a _deps
    for _name in "${!_closure[@]}"; do
        _deps_str="${MODULES_DEPS[${_name}]:-}"
        [[ -z "${_deps_str}" ]] && continue
        # shellcheck disable=SC2206
        _deps=(${_deps_str})
        for _dep in "${_deps[@]}"; do
            [[ -z "${_dep}" ]] && continue
            _indeg["${_name}"]=$(( ${_indeg[${_name}]:-0} + 1 ))
        done
    done

    # 4. Kahn: seed queue with in-degree 0 nodes (sorted for determinism).
    local -a _queue=()
    while IFS= read -r _name; do
        if [[ "${_indeg[${_name}]:-0}" -eq 0 ]]; then
            _queue+=("${_name}")
        fi
    done < <(printf "%s\n" "${!_closure[@]}" | sort)

    local -a _order=()
    local _head
    while [[ "${#_queue[@]}" -gt 0 ]]; do
        _head="${_queue[0]}"
        _queue=("${_queue[@]:1}")
        _order+=("${_head}")

        # Newly-freed children: walk every node X in closure that has
        # _head among its deps; decrement in-degree, enqueue when 0.
        # Collect newly-freed names then sort for determinism within layer.
        local -a _newly_free=()
        local _x _x_deps_str
        local -a _x_deps
        for _x in "${!_closure[@]}"; do
            _x_deps_str="${MODULES_DEPS[${_x}]:-}"
            [[ -z "${_x_deps_str}" ]] && continue
            # shellcheck disable=SC2206
            _x_deps=(${_x_deps_str})
            for _dep in "${_x_deps[@]}"; do
                if [[ "${_dep}" == "${_head}" ]]; then
                    _indeg["${_x}"]=$(( ${_indeg[${_x}]:-0} - 1 ))
                    if [[ "${_indeg[${_x}]}" -eq 0 ]]; then
                        _newly_free+=("${_x}")
                    fi
                fi
            done
        done
        if [[ "${#_newly_free[@]}" -gt 0 ]]; then
            local _f
            while IFS= read -r _f; do
                _queue+=("${_f}")
            done < <(printf "%s\n" "${_newly_free[@]}" | sort)
        fi
    done

    # 5. Detect cycle (closure unreached).
    if [[ "${#_order[@]}" -lt "${#_closure[@]}" ]]; then
        printf "[resolver] ERROR: dependency cycle detected\n" >&2
        printf "[resolver] partial order: %s\n" "${_order[*]}" >&2
        return 5
    fi

    # 6. Emit order.
    for _name in "${_order[@]}"; do
        printf "%s\n" "${_name}"
    done
}
