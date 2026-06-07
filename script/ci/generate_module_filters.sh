#!/usr/bin/env bash
# generate_module_filters.sh — Emit dorny/paths-filter YAML for per-module CI
#
# Generates the filter block consumed by the `changes` job in
# .github/workflows/ci.yaml (issue #31, PRD M10). Three filter kinds:
#
#   shared      — anything that affects HOW tests run (lib/, script/,
#                 test/helper/, dockerfile/, compose.yaml, Makefile,
#                 workflows). A match fans out to ALL module jobs + core.
#   core        — non-module unit specs (engine/lib/hook/script/template
#                 specs) and the trees they exercise. A match runs the
#                 single `test-unit (core)` job.
#   module-<X>  — `module/<X>.module.sh` or its spec. A match runs only
#                 that module's matrix job.
#
# Output goes to stdout; CI redirects it to a runtime-generated file and
# points dorny/paths-filter's `filters:` input at it.
#
# Env:
#   INIT_UBUNTU_MODULE_DIR  Override the module dir scanned for
#                           *.module.sh (tests use a fixture dir).
#
# Usage:
#   ./script/ci/generate_module_filters.sh > /tmp/module-filters.yaml

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
readonly REPO_ROOT

MODULE_DIR="${INIT_UBUNTU_MODULE_DIR:-${REPO_ROOT}/module}"

# Static filters: shared (fan-out to everything) + core (non-module specs).
cat <<'EOF'
shared:
  - 'lib/**'
  - 'script/**'
  - 'test/helper/**'
  - 'dockerfile/**'
  - 'compose.yaml'
  - 'Makefile'
  - '.github/workflows/**'
core:
  - 'test/unit/*.bats'
  - 'test/unit/hook/**'
  - 'test/unit/script/**'
  - 'template/**'
EOF

# One filter per module: the module script itself + its unit spec.
# Glob expansion is sorted by bash, so output order is deterministic.
for _f in "${MODULE_DIR}"/*.module.sh; do
    [[ -e "${_f}" ]] || continue  # empty dir: nullglob not set
    _name="$(basename "${_f}" .module.sh)"
    printf "module-%s:\n" "${_name}"
    printf "  - 'module/%s.module.sh'\n" "${_name}"
    printf "  - 'test/unit/module/%s_spec.bats'\n" "${_name}"
done
