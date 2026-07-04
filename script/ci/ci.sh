#!/usr/bin/env bash
# ci.sh — Run init_ubuntu CI pipeline (ShellCheck + fish syntax + Hadolint + Bats [+ Kcov])
#
# Borrowed from ycpss91255-docker/base v0.28.0 (commit ade915a) script/ci/ci.sh
# Customizations vs upstream:
#   - Replaced `_log_err` from base's _lib.sh with inline `_die`
#     (we don't borrow base's docker/_lib.sh per PRD §13.2)
#   - shellcheck path glob: lint all *.sh under repo; exclude small-tools/
#     (deprecated, PRD §6.6) and tool/ (one-off script holding area, §6.5)
#   - Added fish syntax check (`fish -n`) for all *.fish
#   - Added hadolint on dockerfile/Dockerfile.test-tools
#   - Removed `--behavioural` mode (no Docker image build per PRD §2)
#   - Single image: test-tools:local bundles kcov, so coverage uses the
#     same image (base swaps to kcov/kcov debian image)
#
# Usage:
#   ./ci.sh                       # Full pipeline via compose
#   ./ci.sh --ci                  # Inside container: full pipeline
#   ./ci.sh --ci-lint             # Inside container: lint only
#   ./ci.sh --ci-unit             # Inside container: bats unit only
#   ./ci.sh --ci-integration      # Inside container: bats integration only
#   ./ci.sh --lint-only           # Host: route to --ci-lint via compose
#   ./ci.sh --unit-only           # Host: route to --ci-unit via compose
#   ./ci.sh --unit-only --module docker   # Host: only docker's unit spec
#   ./ci.sh --unit-only --module core     # Host: non-module unit specs only
#   ./ci.sh --integration-only    # Host: route to --ci-integration via compose
#   ./ci.sh --coverage            # Host: full + kcov via compose
#   ./ci.sh --unit-only --kcov --module docker
#                                 # Host: docker's unit spec ONCE under kcov
#                                 #   → coverage/shard-docker (issue #28)
#   ./ci.sh --merge-coverage      # Host: kcov --merge all coverage/*shard-*
#                                 #   + assert coverage gate on merged
#                                 #   (ratchet baseline; see COVERAGE_MIN)

# Only set strict mode when running directly; respect caller when sourced
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    set -euo pipefail
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
readonly REPO_ROOT

# ── Logging (minimal; lib/logger.sh not yet available in Phase 1) ────────────

_die()  { printf '[ci] ERROR: %s\n' "$*" >&2; exit 1; }
_info() { printf '[ci] %s\n' "$*"; }

# ── Install deps when running in kcov/kcov debian image ──────────────────────
# test-tools:local already bakes bats + bats-mock + shellcheck + parallel,
# so this is a no-op there (early return via `command -v bats`).
# Only kcov/kcov needs apt-install at runtime because that upstream image
# only ships kcov itself.

_install_deps_for_coverage() {
    command -v bats >/dev/null 2>&1 && return 0

    local _mirror="${APT_MIRROR_DEBIAN:-deb.debian.org}"
    if [[ "${_mirror}" != "deb.debian.org" ]]; then
        [[ -f /etc/apt/sources.list ]] \
            && sed -i "s|deb.debian.org|${_mirror}|g" /etc/apt/sources.list
        if compgen -G '/etc/apt/sources.list.d/*.list' >/dev/null; then
            sed -i "s|deb.debian.org|${_mirror}|g" /etc/apt/sources.list.d/*.list
        fi
        if compgen -G '/etc/apt/sources.list.d/*.sources' >/dev/null; then
            sed -i "s|deb.debian.org|${_mirror}|g" /etc/apt/sources.list.d/*.sources
        fi
    fi

    apt-get update -qq \
        || _die "apt-get update failed in kcov/kcov image — check network."
    apt-get install -y --no-install-recommends \
        bats bats-support bats-assert \
        shellcheck git ca-certificates \
        parallel make jq curl unzip \
        || _die "apt-get install failed for bats/shellcheck deps."

    # bats-mock not in debian bookworm; pin to upstream v1.2.5 for reproducibility.
    git clone --depth 1 -b v1.2.5 \
        https://github.com/jasonkarns/bats-mock /usr/lib/bats/bats-mock \
        || _die "git clone bats-mock failed — check GitHub access."
}

# ── Help ─────────────────────────────────────────────────────────────────────

usage() {
    cat >&2 <<'EOF'
Usage: ./ci.sh [OPTIONS]

Run init_ubuntu CI: ShellCheck + fish syntax + Hadolint + Bats [+ Kcov].

Host-side options (route through compose into test-tools container):
  --lint-only           ShellCheck + fish + hadolint
  --unit-only           Bats unit
  --integration-only    Bats integration
  --coverage            Full pipeline with kcov
  --merge-coverage      Merge coverage/*shard-* dirs + assert AC-17 gate
  (no flag)             Full pipeline (lint + bats, no kcov)

Container-side options (called by compose entrypoint):
  --ci                  Full pipeline (honors $COVERAGE=1)
  --ci-lint             Lint only
  --ci-unit             Bats unit only
  --ci-integration      Bats integration only
  --ci-merge-coverage   Merge coverage shards + assert AC-17 gate

Per-shard coverage (issue #28; combine with --unit-only / --ci-unit):
  --kcov                Run the unit bats invocation ONCE under kcov;
                        shard output: coverage/shard-<module|core|all>.
                        Routes to the kcov image (kcov is not available
                        in alpine test-tools). Gate threshold for
                        --merge-coverage: $COVERAGE_MIN (default 80 —
                        the AC-17 gate; ratcheted up from the 66 baseline
                        in #124 once #122/#123 boosted coverage).
                        $COVERAGE_ENFORCE=0|false makes the gate
                        report-only (CI uses this on narrow PR matrices).

Unit-scope filter (combine with --unit-only / --ci-unit; issue #31):
  --module <name>       Only run test/unit/module/<name>_spec.bats
                        (missing spec = skip, exits 0 — per-module CI
                        matrix includes modules without specs yet)
  --module core         Only run the non-module unit specs (engine/lib/
                        hook/script/template specs) as a single shard
  --module core-<N>     Only run the Nth (0-based) round-robin sub-shard
                        of the core specs out of $CORE_SHARD_COUNT
                        (default 4); the CI core matrix runs these in
                        parallel like the per-module matrix (issue #226).
                        Shard output: coverage/shard-core-<N>

  -h, --help            Show this help
EOF
    exit 0
}

# ── Lint discovery (exclude deprecated paths per PRD §6.5/§6.6) ──────────────
#
# Pruned directories (deprecated, holding areas, or vendored upstream):
#   small-tools/             — legacy install scripts, replaced by module/
#   tool/                    — holding area for one-off scripts (PRD §6.5)
#   module/config/          — third-party config files (vendored upstream)
#   module/submodule/       — v1 sub-tool helpers (predates v2 module pattern)
#   module/function/        — v1 lib/ location (moved to lib/)
#
# Pruned files (legacy install scripts that predate the v2 module pattern):
#   module/setup_*.sh       — old all-in-one installers; not migrated yet
#   module/anydesk.sh       — legacy one-off
#   install-nvidia-driver.sh — legacy one-off at repo root

_find_lintable_sh() {
    find "${REPO_ROOT}" \
        \( -path "${REPO_ROOT}/.git" -o \
           -path "${REPO_ROOT}/.tmp" -o \
           -path "${REPO_ROOT}/.worktree" -o \
           -path "${REPO_ROOT}/.claude/worktrees" -o \
           -path "${REPO_ROOT}/worktree" -o \
           -path "${REPO_ROOT}/coverage" -o \
           -path "${REPO_ROOT}/small-tools" -o \
           -path "${REPO_ROOT}/tool" -o \
           -path "${REPO_ROOT}/module/config" -o \
           -path "${REPO_ROOT}/module/submodule" -o \
           -path "${REPO_ROOT}/module/function" \) -prune -o \
        -type f \( -name "*.sh" -o -name "*.bash" -o -name "*.bats" \) \
        ! -path "${REPO_ROOT}/module/setup_*.sh" \
        ! -path "${REPO_ROOT}/module/anydesk.sh" \
        ! -path "${REPO_ROOT}/install-nvidia-driver.sh" \
        -print0
}

_find_lintable_fish() {
    find "${REPO_ROOT}" \
        \( -path "${REPO_ROOT}/.git" -o \
           -path "${REPO_ROOT}/.tmp" -o \
           -path "${REPO_ROOT}/.worktree" -o \
           -path "${REPO_ROOT}/.claude/worktrees" -o \
           -path "${REPO_ROOT}/worktree" -o \
           -path "${REPO_ROOT}/coverage" -o \
           -path "${REPO_ROOT}/small-tools" -o \
           -path "${REPO_ROOT}/tool" -o \
           -path "${REPO_ROOT}/module/config" -o \
           -path "${REPO_ROOT}/module/submodule" -o \
           -path "${REPO_ROOT}/module/function" \) -prune -o \
        -type f -name "*.fish" -print0
}

# ── ShellCheck ───────────────────────────────────────────────────────────────

_run_shellcheck() {
    _info "Running ShellCheck"
    local _count=0
    while IFS= read -r -d '' _f; do
        _count=$((_count + 1))
    done < <(_find_lintable_sh)
    _info "  found ${_count} shell script(s)"
    if [[ "${_count}" -eq 0 ]]; then
        _info "  (no shell scripts to check — skipping)"
        return 0
    fi
    # Parallelize: a single `xargs shellcheck` passed ALL ~197 files to one
    # ShellCheck process — 212s serial and the critical-path CI tail. Adding
    # -P alone does nothing (still one child); we ALSO batch with -n so xargs
    # forks one shellcheck per ${SHELLCHECK_BATCH} files across $(nproc)
    # workers. `-x` still resolves `source`d files from disk regardless of
    # which batch they land in, so batching never changes WHICH files/sources
    # are checked.
    #
    # Fail-signal (correctness constraint): xargs returns 123 — not 1 — when
    # ANY batched child shellcheck reports a violation. We capture that rc
    # and treat ANY nonzero (incl. 123) as failure via _die, so the lint step
    # exits nonzero on a violation regardless of set -e state. Do NOT compare
    # against a single expected code (e.g. `-eq 1`): that would swallow 123.
    local _jobs
    _jobs="$(nproc 2>/dev/null || echo 4)"
    local _rc=0
    _find_lintable_sh \
        | xargs -0 -P "${_jobs}" -n "${SHELLCHECK_BATCH:-40}" shellcheck -x \
        || _rc=$?
    if [[ "${_rc}" -ne 0 ]]; then
        _die "ShellCheck failed (rc=${_rc}) — see violations above"
    fi
    _info "ShellCheck OK"
}

# ── Fish syntax check ────────────────────────────────────────────────────────

_run_fish_syntax() {
    _info "Running fish -n syntax check"
    if ! command -v fish >/dev/null 2>&1; then
        _info "  fish not in PATH — skipping (run inside test-tools image for full coverage)"
        return 0
    fi
    local _count=0 _failed=0
    while IFS= read -r -d '' _f; do
        _count=$((_count + 1))
        if ! fish -n "${_f}" 2>&1; then
            _failed=$((_failed + 1))
            printf '[ci] fish syntax error: %s\n' "${_f}" >&2
        fi
    done < <(_find_lintable_fish)
    _info "  checked ${_count} fish script(s); ${_failed} failed"
    if [[ "${_failed}" -gt 0 ]]; then
        _die "fish syntax check failed on ${_failed} file(s)"
    fi
    _info "fish syntax OK"
}

# ── Hadolint ─────────────────────────────────────────────────────────────────

_run_hadolint() {
    if ! command -v hadolint >/dev/null 2>&1; then
        _info "Hadolint: hadolint not in PATH — skipping"
        return 0
    fi
    # Lint every repo Dockerfile (test-tools + kcov-tools, issue #226); a
    # missing file is skipped rather than failing (bootstrap-friendly).
    local _df _checked=0
    for _df in "${REPO_ROOT}/dockerfile/Dockerfile.test-tools" \
               "${REPO_ROOT}/dockerfile/Dockerfile.kcov-tools"; do
        [[ -f "${_df}" ]] || continue
        _info "Running Hadolint on ${_df#"${REPO_ROOT}/"}"
        hadolint "${_df}"
        _checked=$((_checked + 1))
    done
    if [[ "${_checked}" -eq 0 ]]; then
        _info "Hadolint: no Dockerfile to check — skipping"
        return 0
    fi
    _info "Hadolint OK"
}

# ── Bats ─────────────────────────────────────────────────────────────────────

# Populates global array BATS_ARGS_ARR with the bats invocation flags.
# Using an array (vs `printf` of a space-separated string) lets callers
# expand `"${BATS_ARGS_ARR[@]}"` instead of unquoted `$(_bats_args)`,
# avoiding SC2046 (unquoted command substitution).
# Under kcov instrumentation (--kcov; issue #28) bats runs serially —
# same as the full `_run_coverage` path — because kcov's ptrace tracing
# of GNU-parallel-forked bats jobs is flaky.
_set_bats_args_arr() {
    BATS_ARGS_ARR=()
    [[ "${KCOV_UNIT:-0}" == "1" ]] && return 0
    if command -v parallel >/dev/null 2>&1; then
        local _j
        _j="$(nproc 2>/dev/null || echo 4)"
        BATS_ARGS_ARR=(--jobs "${_j}")
    fi
}

# Comma-joined kcov --exclude-path list, shared by the full coverage run
# and the per-shard unit coverage runs (issue #28).
_kcov_exclude_path() {
    local _excludes=(
        "${REPO_ROOT}/test/"
        "${REPO_ROOT}/script/ci/"
        "${REPO_ROOT}/dockerfile/"
        "${REPO_ROOT}/.github/"
        "${REPO_ROOT}/small-tools/"
        "${REPO_ROOT}/tool/"
    )
    (IFS=,; printf '%s' "${_excludes[*]}")
}

# Run the unit bats invocation — plain, or wrapped ONCE in kcov when
# KCOV_UNIT=1 (issue #28: per-module CI matrix shards run bats a single
# time under kcov instead of a separate test-unit + coverage double run).
# Shard output dir: coverage/shard-<module|core|all>; the aggregation job
# merges all shards via --ci-merge-coverage.
_bats_unit() {
    if [[ "${KCOV_UNIT:-0}" != "1" ]]; then
        bats "$@"
        return
    fi
    command -v kcov >/dev/null 2>&1 \
        || _die "kcov not found in container — per-shard coverage runs in the kcov image (just -f justfile.ci coverage-unit)"
    local _shard="${MODULE_FILTER:-all}"
    local _out="${REPO_ROOT}/coverage/shard-${_shard}"
    # kcov only creates ONE directory level; coverage/ itself does not
    # exist on a fresh checkout ("kcov: error: Can't write helper").
    mkdir -p "${_out}"
    _info "kcov shard output: ${_out}"
    # Bound + retry the kcov run. A deep-fork e2e spec can deadlock kcov ptrace
    # nondeterministically; per-shard the normal run is ~1.5 min, so a short
    # timeout (KCOV_BATS_TIMEOUT, default 180s) catches a hang fast, --kill-after
    # guarantees the SIGKILL of a ptrace-wedged process, and we retry the shard
    # (KCOV_BATS_ATTEMPTS, default 2) before failing. A genuine test failure
    # (rc not 124/137) is NOT retried.
    local _kcov_timeout="${KCOV_BATS_TIMEOUT:-180}"
    local _attempts="${KCOV_BATS_ATTEMPTS:-2}"
    local _kcov_rc=0 _try=1
    while (( _try <= _attempts )); do
        _kcov_rc=0
        timeout --kill-after=20 "${_kcov_timeout}" kcov \
            --include-path="${REPO_ROOT}" \
            --exclude-path="$(_kcov_exclude_path)" \
            --exclude-region='kcov-exclude-start:kcov-exclude-end' \
            "${_out}" \
            bats "$@" || _kcov_rc=$?
        # kcov leaves absolute-path convenience symlinks (e.g. bats →
        # /source/coverage/...) that dangle outside the container and can
        # break the per-shard artifact upload — prune them. `kcov --merge`
        # reads the real bats.<hash>/ data dirs, not the symlinks.
        find "${_out}" -maxdepth 1 -type l -delete 2>/dev/null || true
        # 124 = timeout fired; 137 = SIGKILL after --kill-after (ptrace-wedged).
        if (( _kcov_rc != 124 && _kcov_rc != 137 )); then
            break
        fi
        _info "kcov shard hung (rc=${_kcov_rc}) on attempt ${_try}/${_attempts}; retrying"
        rm -rf "${_out}"; mkdir -p "${_out}"
        _try=$(( _try + 1 ))
    done
    if (( _kcov_rc == 124 || _kcov_rc == 137 )); then
        _die "kcov bats run hung past ${_kcov_timeout}s on all ${_attempts} attempts — a test deadlocks under kcov (see the TAP output above for the last test before the stall)."
    fi
    return "${_kcov_rc}"
}

# Enumerate the non-module ("core") unit specs in a deterministic order.
# Populates the caller-named array (nameref) with the sorted spec paths so
# every shard splits the SAME ordered list — gaps/overlap impossible.
# find ... -print0 | sort -z makes the order stable across runs and hosts.
_find_core_specs_sorted() {
    local -n _out_arr="$1"
    _out_arr=()
    local _f
    while IFS= read -r -d '' _f; do
        _out_arr+=("${_f}")
    done < <(find "${REPO_ROOT}/test/unit" -type f -name '*.bats' \
                 ! -path "${REPO_ROOT}/test/unit/module/*" -print0 \
             | sort -z)
}

# Deterministic round-robin partition of the sorted core specs: shard <idx>
# (0-based) gets every spec whose position in the sorted list is congruent
# to <idx> modulo <count>. Round-robin (vs contiguous slices) keeps the
# per-shard spec count balanced to within 1 even when a few specs dominate
# the runtime, and the union of all <count> shards is exactly the full set
# with no overlap. Populates the caller-named array (nameref).
_partition_core_specs_for_shard() {
    local -n _dst_arr="$1"
    local _idx="$2" _count="$3"
    local -a _all=()
    _find_core_specs_sorted _all
    _dst_arr=()
    local _i
    for ((_i = _idx; _i < ${#_all[@]}; _i += _count)); do
        _dst_arr+=("${_all[_i]}")
    done
}

# Scope: honors MODULE_FILTER (set via --module; issue #31, PRD M10):
#   ""        — full unit tree (default; unchanged behaviour)
#   core      — every unit spec EXCEPT test/unit/module/ (engine/lib/hook/
#               script/template specs) as ONE shard; the legacy single
#               `test-unit (core)` job (kept for local dev + back-compat)
#   core-<N>  — the Nth (0-based) round-robin sub-shard of the core specs
#               out of CORE_SHARD_COUNT (default 4); the CI core matrix
#               runs these in parallel like the per-module matrix (#226).
#               Shard output: coverage/shard-core-<N>
#   <name>    — only test/unit/module/<name>_spec.bats; a missing spec is a
#               skip (exit 0) so matrix jobs for not-yet-specced modules
#               stay green instead of failing the shard
_run_unit() {
    if [[ ! -d "${REPO_ROOT}/test/unit" ]]; then
        _info "test/unit/ does not exist yet — skipping (Phase 1 bootstrap)"
        return 0
    fi
    _set_bats_args_arr
    case "${MODULE_FILTER:-}" in
        "")
            _info "Running Bats unit tests"
            _bats_unit "${BATS_ARGS_ARR[@]}" -r "${REPO_ROOT}/test/unit/"
            ;;
        core)
            _info "Running Bats unit tests (core: non-module specs)"
            local -a _specs=()
            _find_core_specs_sorted _specs
            if [[ "${#_specs[@]}" -eq 0 ]]; then
                _info "  no core unit specs found — skipping"
                return 0
            fi
            _bats_unit "${BATS_ARGS_ARR[@]}" "${_specs[@]}"
            ;;
        core-*)
            # core-<N>: one round-robin sub-shard of the core specs (#226).
            local _shard_idx="${MODULE_FILTER#core-}"
            local _shard_count="${CORE_SHARD_COUNT:-4}"
            if [[ ! "${_shard_idx}" =~ ^[0-9]+$ ]]; then
                _die "Invalid core shard index in --module ${MODULE_FILTER} (expected core-<N>, N a non-negative integer)"
            fi
            if [[ ! "${_shard_count}" =~ ^[1-9][0-9]*$ ]]; then
                _die "Invalid CORE_SHARD_COUNT='${_shard_count}' (expected a positive integer)"
            fi
            if (( _shard_idx >= _shard_count )); then
                _die "core shard index ${_shard_idx} out of range for CORE_SHARD_COUNT=${_shard_count} (valid: 0..$((_shard_count - 1)))"
            fi
            _info "Running Bats unit tests (core shard ${_shard_idx}/${_shard_count}: round-robin non-module specs)"
            local -a _specs=()
            _partition_core_specs_for_shard _specs "${_shard_idx}" "${_shard_count}"
            if [[ "${#_specs[@]}" -eq 0 ]]; then
                _info "  no core unit specs in shard ${_shard_idx} — skipping"
                return 0
            fi
            _bats_unit "${BATS_ARGS_ARR[@]}" "${_specs[@]}"
            ;;
        *)
            local _spec="${REPO_ROOT}/test/unit/module/${MODULE_FILTER}_spec.bats"
            if [[ ! -f "${_spec}" ]]; then
                _info "No unit spec for module '${MODULE_FILTER}'" \
                      "(test/unit/module/${MODULE_FILTER}_spec.bats missing) — skipping"
                return 0
            fi
            _info "Running Bats unit tests (module: ${MODULE_FILTER})"
            _bats_unit "${BATS_ARGS_ARR[@]}" "${_spec}"
            ;;
    esac
}

_run_integration() {
    if [[ ! -d "${REPO_ROOT}/test/integration" ]]; then
        _info "test/integration/ does not exist yet — skipping (Phase 1 bootstrap)"
        return 0
    fi
    _info "Running Bats integration tests"
    _set_bats_args_arr
    bats "${BATS_ARGS_ARR[@]}" -r "${REPO_ROOT}/test/integration/"
}

# ── Kcov coverage ────────────────────────────────────────────────────────────

_run_coverage() {
    if [[ ! -d "${REPO_ROOT}/test/unit" ]] && [[ ! -d "${REPO_ROOT}/test/integration" ]]; then
        _info "No test/ subdirs yet — skipping kcov (Phase 1 bootstrap)"
        return 0
    fi
    if ! command -v kcov >/dev/null 2>&1; then
        _die "kcov not found in container — rebuild test-tools:local (just -f justfile.ci build-test-tools)"
    fi
    _info "Running tests with kcov coverage"
    local -a _targets=()
    [[ -d "${REPO_ROOT}/test/unit" ]] && _targets+=("${REPO_ROOT}/test/unit/")
    [[ -d "${REPO_ROOT}/test/integration" ]] && _targets+=("${REPO_ROOT}/test/integration/")
    kcov \
        --include-path="${REPO_ROOT}" \
        --exclude-path="$(_kcov_exclude_path)" \
        --exclude-region='kcov-exclude-start:kcov-exclude-end' \
        "${REPO_ROOT}/coverage" \
        bats "${_targets[@]}"

    _info "Coverage report: ${REPO_ROOT}/coverage/index.html"
}

# ── Coverage shard merge + coverage gate (issue #28) ─────────────────────────
# The per-module CI matrix uploads one kcov output dir per shard; the
# aggregation job downloads them under coverage/ and calls this to
# `kcov --merge` them and assert the coverage gate on the MERGED result
# — never per shard. Glob matches both the local layout
# (coverage/shard-<name>) and the CI artifact-download layout
# (coverage/coverage-shard-<name>).
#
# Gate semantics:
#   - Threshold: $COVERAGE_MIN, default 80 — the AC-17 gate. This was
#     ratcheted up from the 66 baseline (honest merged number measured
#     66.70% on 2026-06-07) in #124, after #122 (lib specs), #123 (engine
#     specs), and #153 (general/dispatcher boost) lifted the merged number
#     past 80 (measured 80.16% on 2026-06-17). The gate now prevents
#     regression below AC-17's required floor.
#   - Enforcement: $COVERAGE_ENFORCE=0|false → report-only (print the
#     percentage, never fail). CI sets this on narrow-matrix PR runs
#     (only changed shards ran) because they are structurally low — the
#     unrun shards' source files still count in the merged denominator.
#     Full-matrix runs (push to main / shared fan-out) enforce.

_merged_coverage_percent() {
    local _json
    _json="$(find "${REPO_ROOT}/coverage/merged" -name coverage.json 2>/dev/null | head -n1)"
    [[ -n "${_json}" ]] \
        || _die "merged coverage.json not found under coverage/merged"
    # coverage.json lists per-file entries ({"file": ..., "percent_covered":
    # ...}) BEFORE the overall "percent_covered" — match only the overall
    # line (no "file" key on it).
    grep -v '"file"' "${_json}" \
        | sed -n 's/.*"percent_covered"[: ]*"\([0-9.]*\)".*/\1/p' \
        | head -n1
}

_assert_coverage_gate() {
    # Default 80 = the AC-17 gate, ratcheted up from the 66 baseline in
    # #124 (merged number reached 80.16% on 2026-06-17). See section
    # comment above.
    local _min="${COVERAGE_MIN:-80}"
    local _pct
    _pct="$(_merged_coverage_percent)"
    [[ -n "${_pct}" ]] \
        || _die "could not parse percent_covered from merged coverage.json"
    case "${COVERAGE_ENFORCE:-1}" in
        0|false)
            _info "Merged unit coverage: ${_pct}% (report-only: partial" \
                  "unit matrix — gate >= ${_min}% enforced on full-matrix" \
                  "runs only)"
            return 0
            ;;
    esac
    _info "Merged unit coverage: ${_pct}% (gate: >= ${_min}%, AC-17)"
    awk -v p="${_pct}" -v t="${_min}" 'BEGIN { exit (p >= t) ? 0 : 1 }' \
        || _die "coverage gate failed: ${_pct}% < ${_min}% (AC-17)"
}

_run_coverage_merge() {
    local -a _shards=()
    local _d
    while IFS= read -r -d '' _d; do
        _shards+=("${_d}")
    done < <(find "${REPO_ROOT}/coverage" -mindepth 1 -maxdepth 1 \
                 -type d -name '*shard-*' -print0 2>/dev/null | sort -z)
    if [[ "${#_shards[@]}" -eq 0 ]]; then
        # Zero shards = every selected shard green-skipped (e.g. a PR
        # touching only a module without a spec yet). Mirror the shard
        # green-skip contract instead of failing the aggregate.
        _info "no coverage shards found under coverage/ — nothing to merge, skipping gate"
        return 0
    fi
    command -v kcov >/dev/null 2>&1 \
        || _die "kcov not found in container — merge runs in the kcov image (just -f justfile.ci coverage-merge)"
    _info "Merging ${#_shards[@]} coverage shard(s) into coverage/merged"
    kcov --merge --exclude-region='kcov-exclude-start:kcov-exclude-end' "${REPO_ROOT}/coverage/merged" "${_shards[@]}"
    # chown BEFORE the gate assert: a failed gate is an expected outcome
    # and must not leave root-owned files behind on the host.
    _fix_permissions
    _assert_coverage_gate
}

# ── Permission fix for HOST_UID/GID ──────────────────────────────────────────

_fix_permissions() {
    local uid="${HOST_UID:-}" gid="${HOST_GID:-}"
    if [[ -n "${uid}" && -n "${gid}" && -d "${REPO_ROOT}/coverage" ]]; then
        chown -R "${uid}:${gid}" "${REPO_ROOT}/coverage" 2>/dev/null || true
    fi
}

# ── Compose wrapper (host-side) ──────────────────────────────────────────────

# Route to a specific compose service:
#   `ci`        — test-tools:<content-hash> (alpine; fast lint+bats path)
#   `coverage`  — kcov/kcov (debian; slow kcov path, apt-installs deps)
#
# The ci service image tag is content-keyed (issue #113): resolved from
# sha256(Dockerfile.test-tools) via resolve_test_tools_tag.sh and exported
# as $TEST_TOOLS_IMAGE so compose's ${TEST_TOOLS_IMAGE:-test-tools:local}
# substitution picks it up. A pre-set $TEST_TOOLS_IMAGE (justfile.ci export,
# CI prebuilt path, manual override) wins — resolution is consistent
# across justfile.ci / ci.sh / compose.yaml by construction.
_run_in_container() {
    local _service="${1:-ci}"
    local _container_flag="${2:---ci}"
    local _coverage="${3:-0}"
    if [[ -z "${TEST_TOOLS_IMAGE:-}" ]]; then
        TEST_TOOLS_IMAGE="$("${SCRIPT_DIR}/resolve_test_tools_tag.sh")" \
            || _die "failed to resolve content-keyed test-tools image tag (issue #113)"
    fi
    export TEST_TOOLS_IMAGE
    # The coverage service runs the baked kcov-tools image (issue #226) so
    # the per-shard kcov jobs skip the runtime apt-install. Resolve its
    # content-keyed tag (or honor a pre-set KCOV_TOOLS_IMAGE: CI prebuilt
    # path / manual override) and export it for compose's
    # ${KCOV_TOOLS_IMAGE:-kcov/kcov} substitution. Fallback stays kcov/kcov
    # (ci.sh then apt-installs the toolchain on demand).
    if [[ "${_service}" == "coverage" && -z "${KCOV_TOOLS_IMAGE:-}" ]]; then
        KCOV_TOOLS_IMAGE="$("${SCRIPT_DIR}/resolve_kcov_tools_tag.sh")" \
            || _die "failed to resolve content-keyed kcov-tools image tag (issue #226)"
    fi
    export KCOV_TOOLS_IMAGE="${KCOV_TOOLS_IMAGE:-}"
    docker compose -f "${REPO_ROOT}/compose.yaml" run --rm \
        -e HOST_UID="$(id -u)" \
        -e HOST_GID="$(id -g)" \
        -e COVERAGE="${_coverage}" \
        -e SYNC_E2E="${SYNC_E2E:-0}" \
        -e COVERAGE_MIN="${COVERAGE_MIN:-}" \
        -e COVERAGE_ENFORCE="${COVERAGE_ENFORCE:-}" \
        -e CORE_SHARD_COUNT="${CORE_SHARD_COUNT:-}" \
        -e INIT_UBUNTU_TEST_IMAGE="${INIT_UBUNTU_TEST_IMAGE:-}" \
        "${_service}" \
        -c "./script/ci/ci.sh ${_container_flag}"
}

# ── Sync E2E receiver (AC-15, issue #67) ─────────────────────────────────────
# The integration suite's dual-container sync spec needs the sshd receiver
# on the same compose network BEFORE the ci container joins it. Profile-gated
# (sync-e2e) so no other compose workflow ever starts it; the spec itself is
# gated on SYNC_E2E=1 and skips everywhere else (full `just -f justfile.ci test`, coverage).

_sync_receiver_up() {
    _info "Starting sync-receiver (compose profile sync-e2e) for the AC-15 sync E2E"
    docker compose -f "${REPO_ROOT}/compose.yaml" --profile sync-e2e \
        up -d sync-receiver
}

_sync_receiver_down() {
    docker compose -f "${REPO_ROOT}/compose.yaml" --profile sync-e2e \
        rm -sf sync-receiver >/dev/null 2>&1 || true
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    local mode="compose"
    MODULE_FILTER=""
    KCOV_UNIT=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage ;;
            --ci) mode="ci"; shift ;;
            --ci-lint) mode="ci-lint"; shift ;;
            --ci-unit) mode="ci-unit"; shift ;;
            --ci-integration) mode="ci-integration"; shift ;;
            --ci-merge-coverage) mode="ci-merge-coverage"; shift ;;
            --lint-only) mode="lint"; shift ;;
            --unit-only) mode="unit"; shift ;;
            --integration-only) mode="integration"; shift ;;
            --coverage) mode="coverage"; shift ;;
            --merge-coverage) mode="merge-coverage"; shift ;;
            --kcov) KCOV_UNIT=1; shift ;;
            --module)
                [[ $# -ge 2 ]] || _die "--module requires a value (module name or 'core')"
                MODULE_FILTER="$2"; shift 2 ;;
            *) _die "Unknown option: $1" ;;
        esac
    done

    if [[ "${KCOV_UNIT}" == "1" && "${mode}" != "unit" && "${mode}" != "ci-unit" ]]; then
        _die "--kcov is only valid with --unit-only / --ci-unit"
    fi

    # Module names are kebab-case (PRD Q11); 'core' is the reserved
    # non-module bucket. Validate before interpolating into the compose
    # `-c` command line.
    if [[ -n "${MODULE_FILTER}" && ! "${MODULE_FILTER}" =~ ^[A-Za-z0-9_-]+$ ]]; then
        _die "Invalid --module value: ${MODULE_FILTER} (expected [A-Za-z0-9_-]+)"
    fi

    case "${mode}" in
        # ── Inside-container modes ──
        ci)
            # kcov/kcov image needs apt-install on entry; test-tools:local
            # already bakes bats/shellcheck so this short-circuits.
            if [[ "${COVERAGE:-0}" == "1" ]]; then
                _install_deps_for_coverage
            fi
            _run_shellcheck
            _run_fish_syntax
            _run_hadolint
            if [[ "${COVERAGE:-0}" == "1" ]]; then
                _run_coverage
                _fix_permissions
            else
                _run_unit
                _run_integration
            fi
            ;;
        ci-lint)
            _run_shellcheck
            _run_fish_syntax
            _run_hadolint
            ;;
        ci-unit)
            # Per-shard kcov runs use the kcov/kcov image, which needs the
            # bats toolchain apt-installed on entry (no-op in test-tools).
            if [[ "${KCOV_UNIT}" == "1" ]]; then
                _install_deps_for_coverage
            fi
            _run_unit
            if [[ "${KCOV_UNIT}" == "1" ]]; then
                _fix_permissions
            fi
            ;;
        ci-integration)
            _run_integration
            ;;
        ci-merge-coverage)
            _run_coverage_merge
            _fix_permissions
            ;;
        # ── Host-side modes (route through compose) ──
        # service = ci (alpine, fast) for everything except --coverage,
        # which uses the kcov/kcov service.
        lint)        _run_in_container ci       --ci-lint        0 ;;
        unit)
            # --kcov shards need the kcov image (kcov is not packaged for
            # alpine, so test-tools:local cannot bundle it).
            if [[ "${KCOV_UNIT}" == "1" ]]; then
                _run_in_container coverage \
                    "--ci-unit${MODULE_FILTER:+ --module ${MODULE_FILTER}} --kcov" 0
            else
                _run_in_container ci \
                    "--ci-unit${MODULE_FILTER:+ --module ${MODULE_FILTER}}" 0
            fi
            ;;
        integration)
            # AC-15 sync E2E: receiver up → suite with SYNC_E2E=1 → always
            # tear the receiver down, then propagate the suite's exit code.
            _sync_receiver_up
            local _integration_rc=0
            SYNC_E2E=1 _run_in_container ci --ci-integration 0 \
                || _integration_rc=$?
            _sync_receiver_down
            return "${_integration_rc}"
            ;;
        coverage)    _run_in_container coverage --ci             1 ;;
        merge-coverage)
                     _run_in_container coverage --ci-merge-coverage 0 ;;
        compose)     _run_in_container ci       --ci             0 ;;
    esac
}

# Guard: only run main when executed directly, not when sourced
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    main "$@"
fi
