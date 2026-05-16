#!/usr/bin/env bash
# ci.sh — Run init_ubuntu CI pipeline (ShellCheck + fish syntax + Hadolint + Bats [+ Kcov])
#
# Borrowed from ycpss91255-docker/base v0.28.0 (commit ade915a) scripts/ci/ci.sh
# Customizations vs upstream:
#   - Replaced `_log_err` from base's _lib.sh with inline `_die`
#     (we don't borrow base's docker/_lib.sh per PRD §13.2)
#   - shellcheck path glob: lint all *.sh under repo; exclude small-tools/
#     (deprecated, PRD §6.6) and modules/tools/ (pending relocation, §6.5)
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
#   ./ci.sh --integration-only    # Host: route to --ci-integration via compose
#   ./ci.sh --coverage            # Host: full + kcov via compose

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
        parallel make jq \
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
  (no flag)             Full pipeline (lint + bats, no kcov)

Container-side options (called by compose entrypoint):
  --ci                  Full pipeline (honors $COVERAGE=1)
  --ci-lint             Lint only
  --ci-unit             Bats unit only
  --ci-integration      Bats integration only

  -h, --help            Show this help
EOF
    exit 0
}

# ── Lint discovery (exclude deprecated paths per PRD §6.5/§6.6) ──────────────

_find_lintable_sh() {
    find "${REPO_ROOT}" \
        \( -path "${REPO_ROOT}/.git" -o \
           -path "${REPO_ROOT}/.tmp" -o \
           -path "${REPO_ROOT}/coverage" -o \
           -path "${REPO_ROOT}/small-tools" -o \
           -path "${REPO_ROOT}/modules/tools" -o \
           -path "${REPO_ROOT}/modules/config" \) -prune -o \
        -type f \( -name "*.sh" -o -name "*.bash" -o -name "*.bats" \) -print0
}

_find_lintable_fish() {
    find "${REPO_ROOT}" \
        \( -path "${REPO_ROOT}/.git" -o \
           -path "${REPO_ROOT}/.tmp" -o \
           -path "${REPO_ROOT}/coverage" -o \
           -path "${REPO_ROOT}/small-tools" -o \
           -path "${REPO_ROOT}/modules/tools" -o \
           -path "${REPO_ROOT}/modules/config" \) -prune -o \
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
    _find_lintable_sh | xargs -0 shellcheck -x
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
    if [[ ! -f "${REPO_ROOT}/dockerfile/Dockerfile.test-tools" ]]; then
        _info "Hadolint: no Dockerfile.test-tools — skipping"
        return 0
    fi
    if ! command -v hadolint >/dev/null 2>&1; then
        _info "Hadolint: hadolint not in PATH — skipping"
        return 0
    fi
    _info "Running Hadolint on dockerfile/Dockerfile.test-tools"
    hadolint "${REPO_ROOT}/dockerfile/Dockerfile.test-tools"
    _info "Hadolint OK"
}

# ── Bats ─────────────────────────────────────────────────────────────────────

_bats_args() {
    if command -v parallel >/dev/null 2>&1; then
        local _j
        _j="$(nproc 2>/dev/null || echo 4)"
        printf -- '--jobs %s' "${_j}"
    fi
}

_run_unit() {
    if [[ ! -d "${REPO_ROOT}/tests/unit" ]]; then
        _info "tests/unit/ does not exist yet — skipping (Phase 1 bootstrap)"
        return 0
    fi
    _info "Running Bats unit tests"
    # shellcheck disable=SC2046
    bats $(_bats_args) -r "${REPO_ROOT}/tests/unit/"
}

_run_integration() {
    if [[ ! -d "${REPO_ROOT}/tests/integration" ]]; then
        _info "tests/integration/ does not exist yet — skipping (Phase 1 bootstrap)"
        return 0
    fi
    _info "Running Bats integration tests"
    # shellcheck disable=SC2046
    bats $(_bats_args) -r "${REPO_ROOT}/tests/integration/"
}

# ── Kcov coverage ────────────────────────────────────────────────────────────

_run_coverage() {
    if [[ ! -d "${REPO_ROOT}/tests/unit" ]] && [[ ! -d "${REPO_ROOT}/tests/integration" ]]; then
        _info "No tests/ subdirs yet — skipping kcov (Phase 1 bootstrap)"
        return 0
    fi
    if ! command -v kcov >/dev/null 2>&1; then
        _die "kcov not found in container — rebuild test-tools:local (make build-test-tools)"
    fi
    local _excludes=(
        "${REPO_ROOT}/tests/"
        "${REPO_ROOT}/scripts/ci/"
        "${REPO_ROOT}/dockerfile/"
        "${REPO_ROOT}/.github/"
        "${REPO_ROOT}/small-tools/"
        "${REPO_ROOT}/modules/tools/"
    )
    local _exclude_path
    _exclude_path="$(IFS=,; printf '%s' "${_excludes[*]}")"

    _info "Running tests with kcov coverage"
    local -a _targets=()
    [[ -d "${REPO_ROOT}/tests/unit" ]] && _targets+=("${REPO_ROOT}/tests/unit/")
    [[ -d "${REPO_ROOT}/tests/integration" ]] && _targets+=("${REPO_ROOT}/tests/integration/")
    kcov \
        --include-path="${REPO_ROOT}" \
        --exclude-path="${_exclude_path}" \
        "${REPO_ROOT}/coverage" \
        bats "${_targets[@]}"

    _info "Coverage report: ${REPO_ROOT}/coverage/index.html"
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
#   `ci`        — test-tools:local (alpine; fast lint+bats path)
#   `coverage`  — kcov/kcov (debian; slow kcov path, apt-installs deps)
_run_in_container() {
    local _service="${1:-ci}"
    local _container_flag="${2:---ci}"
    local _coverage="${3:-0}"
    docker compose -f "${REPO_ROOT}/compose.yaml" run --rm \
        -e HOST_UID="$(id -u)" \
        -e HOST_GID="$(id -g)" \
        -e COVERAGE="${_coverage}" \
        "${_service}" \
        -c "./scripts/ci/ci.sh ${_container_flag}"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    local mode="compose"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage ;;
            --ci) mode="ci"; shift ;;
            --ci-lint) mode="ci-lint"; shift ;;
            --ci-unit) mode="ci-unit"; shift ;;
            --ci-integration) mode="ci-integration"; shift ;;
            --lint-only) mode="lint"; shift ;;
            --unit-only) mode="unit"; shift ;;
            --integration-only) mode="integration"; shift ;;
            --coverage) mode="coverage"; shift ;;
            *) _die "Unknown option: $1" ;;
        esac
    done

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
            _run_unit
            ;;
        ci-integration)
            _run_integration
            ;;
        # ── Host-side modes (route through compose) ──
        # service = ci (alpine, fast) for everything except --coverage,
        # which uses the kcov/kcov service.
        lint)        _run_in_container ci       --ci-lint        0 ;;
        unit)        _run_in_container ci       --ci-unit        0 ;;
        integration) _run_in_container ci       --ci-integration 0 ;;
        coverage)    _run_in_container coverage --ci             1 ;;
        compose)     _run_in_container ci       --ci             0 ;;
    esac
}

# Guard: only run main when executed directly, not when sourced
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    main "$@"
fi
