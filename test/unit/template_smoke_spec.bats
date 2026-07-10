#!/usr/bin/env bats
# test/unit/template_smoke_spec.bats — verify template/module-*.template.sh
#
# Smoke-tests a copy of each archetype template (with TODOs filled) through
# the full standalone CLI surface. Catches drift at the template level so
# downstream modules don't inherit broken behavior.
#
# Archetypes covered: apt | github-release | config | custom

load "${BATS_TEST_DIRNAME}/../helper/common"

ARCHETYPES=(apt github-release config custom)

setup() {
    setup_test_env
    export LOG_LEVEL=INFO
    export LOG_COLOR=false
    export INIT_UBUNTU_LANG=en
    # Template header honors LIB_DIR / REPO_ROOT env vars, so a fixture in
    # /tmp/.../scratch/module/ can still locate the real lib helpers.
    export LIB_DIR REPO_ROOT

    FIXTURE_DIR="${INIT_UBUNTU_TEST_SCRATCH}/module"
    mkdir -p "${FIXTURE_DIR}"

    # Materialise a fixture for each archetype.
    local _arch
    for _arch in "${ARCHETYPES[@]}"; do
        local _src="${TEMPLATE_DIR}/module-${_arch}.template.sh"
        local _dst="${FIXTURE_DIR}/smoke-${_arch}.module.sh"
        [[ -f "${_src}" ]] || { printf "missing template: %s\n" "${_src}" >&2; return 1; }
        # Fill the visible <TODO ...> placeholders. Keep the rest untouched so
        # this spec exercises the actual template shape, not a stripped variant.
        # shellcheck disable=SC2016  # single-quoted ${MODULE_DIR}/${HOME} reach sed as literal text and match the template's placeholder strings — https://www.shellcheck.net/wiki/SC2016
        sed \
            -e 's|<TODO-kebab-case-name>|smoke|g' \
            -e 's|<TODO: apt-managed \| latest \| v1.2.3>|test|g' \
            -e 's|<TODO: one-line English description (< 80 chars)>|smoke module|g' \
            -e 's|<TODO: 一行繁中描述 (< 50 字元)>|測試 module|g' \
            -e 's|<TODO: base \| recommended \| optional \| experimental>|optional|g' \
            -e 's|<TODO-primary-tag>|test|g' \
            -e 's|<TODO: owner/repo, e.g. neovim/neovim>|example/example|g' \
            -e 's|<TODO: e.g. nvim-linux-x86_64.tar.gz>|example.tar.gz|g' \
            -e 's|<TODO: e.g. /opt/nvim>|/opt/example|g' \
            -e 's|<TODO: e.g. nvim>|example|g' \
            -e 's|<TODO: ${MODULE_DIR}/config/<tool>/<file>>|/tmp/example.src|g' \
            -e 's|<TODO: ${HOME}/.config/<tool>/<file>>|/tmp/example.dst|g' \
            "${_src}" > "${_dst}"
        chmod +x "${_dst}"
    done
}

teardown() {
    teardown_test_env
}

# Helper: full path to a fixture for a given archetype.
_smoke() {
    printf '%s/smoke-%s.module.sh' "${INIT_UBUNTU_TEST_SCRATCH}/module" "${1}"
}

# Helper: assert a phase succeeds for every archetype, with DRY-RUN output.
_assert_phase_dry_run_all() {
    local _phase="${1:?phase required}"
    local _arch
    for _arch in "${ARCHETYPES[@]}"; do
        run bash "$(_smoke "${_arch}")" "${_phase}" --dry-run
        if [[ "${status}" -ne 0 ]]; then
            printf 'archetype=%s phase=%s exit=%s output=%s\n' \
                "${_arch}" "${_phase}" "${status}" "${output}" >&2
            return 1
        fi
        if [[ "${output}" != *"DRY-RUN"* ]]; then
            printf 'archetype=%s phase=%s missing DRY-RUN in output: %s\n' \
                "${_arch}" "${_phase}" "${output}" >&2
            return 1
        fi
    done
}

# ── Standalone CLI surfaces ─────────────────────────────────────────────────

@test "template smoke: --help lists all phases (all archetypes)" {
    local _arch
    for _arch in "${ARCHETYPES[@]}"; do
        run bash "$(_smoke "${_arch}")" --help
        if [[ "${status}" -ne 0 ]]; then
            printf 'archetype=%s --help failed: %s\n' "${_arch}" "${output}" >&2
            return 1
        fi
        local _p
        for _p in install upgrade remove purge verify detect is-installed is-recommended status info; do
            [[ "${output}" == *"${_p}"* ]] || {
                printf 'archetype=%s missing phase %s in --help\n' "${_arch}" "${_p}" >&2
                return 1
            }
        done
        [[ "${output}" == *"--dry-run"* ]] || { printf 'archetype=%s missing --dry-run\n' "${_arch}" >&2; return 1; }
        [[ "${output}" == *"--lang="* ]]   || { printf 'archetype=%s missing --lang=\n' "${_arch}"   >&2; return 1; }
    done
}

@test "template smoke: --version prints NAME + VERSION_PROVIDED (all archetypes)" {
    local _arch
    for _arch in "${ARCHETYPES[@]}"; do
        run bash "$(_smoke "${_arch}")" --version
        [[ "${status}" -eq 0 ]] || { printf 'archetype=%s --version exit=%s\n' "${_arch}" "${status}" >&2; return 1; }
        [[ "${output}" == *"smoke"* ]] || { printf 'archetype=%s NAME missing: %s\n' "${_arch}" "${output}" >&2; return 1; }
        [[ "${output}" == *"test"* ]]  || { printf 'archetype=%s VERSION missing: %s\n' "${_arch}" "${output}" >&2; return 1; }
    done
}

@test "template smoke: no args prints usage + exit 2 (all archetypes)" {
    local _arch
    for _arch in "${ARCHETYPES[@]}"; do
        run bash "$(_smoke "${_arch}")"
        [[ "${status}" -eq 2 ]] || { printf 'archetype=%s no-args exit=%s\n' "${_arch}" "${status}" >&2; return 1; }
        [[ "${output}" == *"Usage:"* ]] || { printf 'archetype=%s missing Usage:\n' "${_arch}" >&2; return 1; }
    done
}

@test "template smoke: unknown phase returns exit 2 (all archetypes)" {
    local _arch
    for _arch in "${ARCHETYPES[@]}"; do
        run bash "$(_smoke "${_arch}")" nope
        [[ "${status}" -eq 2 ]] || { printf 'archetype=%s nope exit=%s\n' "${_arch}" "${status}" >&2; return 1; }
    done
}

@test "template smoke: install --dry-run succeeds (all archetypes)" {
    _assert_phase_dry_run_all install
}

@test "template smoke: upgrade --dry-run succeeds (all archetypes)" {
    _assert_phase_dry_run_all upgrade
}

@test "template smoke: remove --dry-run succeeds (all archetypes)" {
    _assert_phase_dry_run_all remove
}

@test "template smoke: purge --dry-run succeeds (all archetypes)" {
    _assert_phase_dry_run_all purge
}

@test "template smoke: verify --dry-run succeeds (all archetypes)" {
    # verify is delegated to module_default_verify which honors --dry-run
    local _arch
    for _arch in "${ARCHETYPES[@]}"; do
        run bash "$(_smoke "${_arch}")" verify --dry-run
        [[ "${status}" -eq 0 ]] || { printf 'archetype=%s verify exit=%s output=%s\n' "${_arch}" "${status}" "${output}" >&2; return 1; }
    done
}

@test "template smoke: is-installed returns 1 on fresh fixture (all archetypes)" {
    local _arch
    for _arch in "${ARCHETYPES[@]}"; do
        run bash "$(_smoke "${_arch}")" is-installed
        [[ "${status}" -eq 1 ]] || { printf 'archetype=%s is-installed exit=%s\n' "${_arch}" "${status}" >&2; return 1; }
    done
}

@test "template smoke: is-outdated has archetype-appropriate exit code" {
    # apt / github-release / config provide is_outdated via the macro (ADR-0002:
    # the macros now emit the full lifecycle); on a not-installed smoke fixture
    # the archetype default returns 1 (not outdated). The custom template leaves
    # is_outdated commented out → standalone CLI returns 2 (not implemented).
    local _arch
    for _arch in "${ARCHETYPES[@]}"; do
        run bash "$(_smoke "${_arch}")" is-outdated
        case "${_arch}" in
            apt|github-release|config)
                [[ "${status}" -eq 1 ]] || { printf 'archetype=%s is-outdated exit=%s (want 1)\n' "${_arch}" "${status}" >&2; return 1; }
                ;;
            custom)
                [[ "${status}" -eq 2 ]] || { printf 'archetype=%s is-outdated exit=%s (want 2)\n' "${_arch}" "${status}" >&2; return 1; }
                [[ "${output}" == *"is_outdated"* ]] || { printf 'archetype=%s missing is_outdated msg\n' "${_arch}" >&2; return 1; }
                ;;
        esac
    done
}

@test "template smoke: doctor has archetype-appropriate exit code" {
    # apt / github-release / config inherit module_default_doctor via the macro
    # (is_installed + TEST_VERIFY_CMD); on a not-installed smoke fixture
    # is_installed fails first, so it returns 1. The custom template leaves
    # doctor commented out → CLI returns 2.
    local _arch
    for _arch in "${ARCHETYPES[@]}"; do
        run bash "$(_smoke "${_arch}")" doctor
        case "${_arch}" in
            apt|github-release|config)
                [[ "${status}" -eq 1 ]] || { printf 'archetype=%s doctor exit=%s (want 1)\n' "${_arch}" "${status}" >&2; return 1; }
                ;;
            custom)
                [[ "${status}" -eq 2 ]] || { printf 'archetype=%s doctor exit=%s (want 2)\n' "${_arch}" "${status}" >&2; return 1; }
                ;;
        esac
    done
}

# ── Engine-side projections (status / info) ─────────────────────────────────

@test "template smoke: info prints name + description + category (all archetypes)" {
    local _arch
    for _arch in "${ARCHETYPES[@]}"; do
        run bash "$(_smoke "${_arch}")" info
        [[ "${status}" -eq 0 ]] || { printf 'archetype=%s info exit=%s\n' "${_arch}" "${status}" >&2; return 1; }
        [[ "${output}" == *"name:"* && "${output}" == *"smoke"* ]] || { printf 'archetype=%s info missing name\n' "${_arch}" >&2; return 1; }
        [[ "${output}" == *"description:"* && "${output}" == *"smoke module"* ]] || { printf 'archetype=%s info missing description\n' "${_arch}" >&2; return 1; }
        [[ "${output}" == *"category:"* && "${output}" == *"optional"* ]] || { printf 'archetype=%s info missing category\n' "${_arch}" >&2; return 1; }
    done
}

@test "template smoke: info --lang=zh-TW returns Chinese description (all archetypes)" {
    local _arch
    for _arch in "${ARCHETYPES[@]}"; do
        run bash "$(_smoke "${_arch}")" info --lang=zh-TW
        [[ "${status}" -eq 0 ]] || { printf 'archetype=%s info zh-TW exit=%s\n' "${_arch}" "${status}" >&2; return 1; }
        [[ "${output}" == *"測試 module"* ]] || { printf 'archetype=%s missing zh-TW description: %s\n' "${_arch}" "${output}" >&2; return 1; }
    done
}

@test "template smoke: status prints installed:no on fresh fixture (all archetypes)" {
    local _arch
    for _arch in "${ARCHETYPES[@]}"; do
        run bash "$(_smoke "${_arch}")" status
        [[ "${status}" -eq 0 ]] || { printf 'archetype=%s status exit=%s\n' "${_arch}" "${status}" >&2; return 1; }
        [[ "${output}" == *"installed:"* && "${output}" == *"no"* ]] || { printf 'archetype=%s status format: %s\n' "${_arch}" "${output}" >&2; return 1; }
    done
}

# ── Source-mode behavior (the other half of dual-mode) ──────────────────────

@test "template smoke: sourcing does NOT auto-execute footer (all archetypes)" {
    local _arch _expected
    for _arch in "${ARCHETYPES[@]}"; do
        local _smoke; _smoke=$(_smoke "${_arch}")
        run bash -c "
            source '${LIB_DIR}/logger.sh'
            source '${LIB_DIR}/general.sh'
            source '${LIB_DIR}/module_helper.sh'
            source '${_smoke}'
            declare -F install >/dev/null && echo INSTALL_DEFINED
            declare -F upgrade >/dev/null && echo UPGRADE_DEFINED
            declare -F remove  >/dev/null && echo REMOVE_DEFINED
            declare -F purge   >/dev/null && echo PURGE_DEFINED
            declare -F verify  >/dev/null && echo VERIFY_DEFINED
            [[ \"\${NAME}\" == 'smoke' ]] && echo NAME_LOADED
            [[ \"\${MODULE_STANDALONE}\" == 'false' ]] && echo STANDALONE_FALSE
        "
        [[ "${status}" -eq 0 ]] || { printf 'archetype=%s source exit=%s output=%s\n' "${_arch}" "${status}" "${output}" >&2; return 1; }
        for _expected in INSTALL_DEFINED UPGRADE_DEFINED REMOVE_DEFINED PURGE_DEFINED VERIFY_DEFINED NAME_LOADED STANDALONE_FALSE; do
            [[ "${output}" == *"${_expected}"* ]] || { printf 'archetype=%s missing %s\n' "${_arch}" "${_expected}" >&2; return 1; }
        done
        [[ "${output}" != *"Usage:"* ]] || { printf 'archetype=%s leaked Usage: in source mode\n' "${_arch}" >&2; return 1; }
    done
}

# ── No side-effect leakage in dry-run ───────────────────────────────────────

@test "template smoke: install --dry-run does not call apt-get / curl / sudo (all archetypes)" {
    STUB_DIR="${INIT_UBUNTU_TEST_SCRATCH}/stubs"
    STUB_LOG="${INIT_UBUNTU_TEST_SCRATCH}/stub.log"
    mkdir -p "${STUB_DIR}"
    : > "${STUB_LOG}"
    local _bin
    for _bin in apt-get curl sudo; do
        cat > "${STUB_DIR}/${_bin}" <<EOF
#!/usr/bin/env bash
echo "${_bin}: \$*" >> "${STUB_LOG}"
exit 1
EOF
        chmod +x "${STUB_DIR}/${_bin}"
    done

    local _arch
    for _arch in "${ARCHETYPES[@]}"; do
        : > "${STUB_LOG}"
        PATH="${STUB_DIR}:${PATH}" run bash "$(_smoke "${_arch}")" install --dry-run
        [[ "${status}" -eq 0 ]] || { printf 'archetype=%s install --dry-run exit=%s output=%s\n' "${_arch}" "${status}" "${output}" >&2; return 1; }
        [[ ! -s "${STUB_LOG}" ]] || { printf 'archetype=%s leaked side effects: %s\n' "${_arch}" "$(cat "${STUB_LOG}")" >&2; return 1; }
    done
}
