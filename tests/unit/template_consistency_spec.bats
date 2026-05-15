#!/usr/bin/env bats
# tests/unit/template_consistency_spec.bats — guard against drift between
# the 4 archetype templates.
#
# The 4 templates (module-{apt,github-release,config,custom}.template.sh)
# each carry their own "archetype-data" block, but the rest is shared:
#   - shared-bootstrap  (dual-mode entry detection)
#   - shared-metadata   (NAME / DESCRIPTION / i18n / env / risk)
#   - shared-lifecycle-stubs  (detect / is_recommended / commented optional)
#   - shared-footer     (standalone entry dispatch)
#
# These shared sections must stay byte-identical across the 4 templates so
# that editing one (e.g. adding a new metadata field) is caught when the
# others lag behind. Sections are delimited by sentinel comments of the form
#   # ── BEGIN: <section-name> ──...
#   ...
#   # ── END: <section-name> ──...
# which makes them robust to line-number shifts.

load "${BATS_TEST_DIRNAME}/../helpers/common"

ARCHETYPES=(apt github-release config custom)

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

# Extract the body of a sentinel-bounded section from a file.
# Args: <section-name> <file>
# Prints lines strictly between `# ── BEGIN: <section-name> ` and
# `# ── END: <section-name> ` (exclusive of the sentinel lines themselves).
_extract_section() {
    local _name="${1:?section name required}"
    local _file="${2:?file required}"
    awk -v name="${_name}" '
        $0 ~ ("# ── BEGIN: " name " ") { in_blk=1; next }
        $0 ~ ("# ── END: "   name " ") { in_blk=0 }
        in_blk { print }
    ' "${_file}"
}

# Assert one shared section is byte-identical across all 4 templates.
# Prints diff against the first archetype on failure.
_assert_shared_section_identical() {
    local _section="${1:?section name required}"
    local _reference="" _ref_arch="" _arch _hash _content
    for _arch in "${ARCHETYPES[@]}"; do
        _content=$(_extract_section "${_section}" "${TEMPLATE_DIR}/module-${_arch}.template.sh")
        if [[ -z "${_content}" ]]; then
            printf "archetype=%s empty %s\n" "${_arch}" "${_section}" >&2
            return 1
        fi
        _hash=$(printf '%s' "${_content}" | sha256sum | awk '{print $1}')
        if [[ -z "${_reference}" ]]; then
            _reference="${_hash}"
            _ref_arch="${_arch}"
        elif [[ "${_hash}" != "${_reference}" ]]; then
            printf '%s drift: %s vs %s\n' "${_section}" "${_ref_arch}" "${_arch}" >&2
            diff \
                <(_extract_section "${_section}" "${TEMPLATE_DIR}/module-${_ref_arch}.template.sh") \
                <(_extract_section "${_section}" "${TEMPLATE_DIR}/module-${_arch}.template.sh") >&2 || true
            return 1
        fi
    done
}

# ── All 4 templates exist ───────────────────────────────────────────────────

@test "all 4 archetype templates exist" {
    local _arch _path
    for _arch in "${ARCHETYPES[@]}"; do
        _path="${TEMPLATE_DIR}/module-${_arch}.template.sh"
        [[ -f "${_path}" ]] || { printf "missing: %s\n" "${_path}" >&2; return 1; }
    done
}

@test "the legacy unified templates/module.template.sh no longer exists" {
    [[ ! -f "${TEMPLATE_DIR}/module.template.sh" ]] || {
        printf "legacy unified template still present: %s\n" "${TEMPLATE_DIR}/module.template.sh" >&2
        return 1
    }
}

# ── Each shared section has identical content across the 4 templates ───────

@test "shared-bootstrap is byte-identical across all archetypes" {
    _assert_shared_section_identical shared-bootstrap
}

@test "shared-metadata is byte-identical across all archetypes" {
    _assert_shared_section_identical shared-metadata
}

@test "shared-lifecycle-stubs is byte-identical across all archetypes" {
    _assert_shared_section_identical shared-lifecycle-stubs
}

@test "shared-footer is byte-identical across all archetypes" {
    _assert_shared_section_identical shared-footer
}

# ── Archetype-specific blocks present and binding correctly ────────────────

@test "module-apt template calls module_use_apt_archetype" {
    grep -q '^module_use_apt_archetype$' "${TEMPLATE_DIR}/module-apt.template.sh"
}

@test "module-github-release template calls module_use_github_release_archetype" {
    grep -q '^module_use_github_release_archetype$' "${TEMPLATE_DIR}/module-github-release.template.sh"
}

@test "module-config template calls module_use_config_archetype" {
    grep -q '^module_use_config_archetype$' "${TEMPLATE_DIR}/module-config.template.sh"
}

@test "module-custom template defines all 6 lifecycle functions" {
    local _fn
    for _fn in is_installed install upgrade remove purge verify; do
        grep -qE "^${_fn}\(\) \{" "${TEMPLATE_DIR}/module-custom.template.sh" \
            || { printf "missing %s() in module-custom.template.sh\n" "${_fn}" >&2; return 1; }
    done
}

@test "module-custom is the only template with a custom-lifecycle block" {
    local _arch _has=""
    for _arch in "${ARCHETYPES[@]}"; do
        if grep -q '# ── BEGIN: custom-lifecycle ' "${TEMPLATE_DIR}/module-${_arch}.template.sh"; then
            _has="${_arch}"
            [[ "${_arch}" == "custom" ]] || { printf "archetype=%s unexpectedly has custom-lifecycle block\n" "${_arch}" >&2; return 1; }
        fi
    done
    [[ "${_has}" == "custom" ]] || { printf "module-custom is missing its custom-lifecycle block\n" >&2; return 1; }
}

# ── Lifecycle phase name is `upgrade`, not `update` ─────────────────────────

@test "no template defines an update() lifecycle function (must be upgrade)" {
    local _arch
    for _arch in "${ARCHETYPES[@]}"; do
        if grep -qE '^update\(\) \{' "${TEMPLATE_DIR}/module-${_arch}.template.sh"; then
            printf "archetype=%s still defines update() — must be renamed to upgrade()\n" "${_arch}" >&2
            return 1
        fi
    done
}
