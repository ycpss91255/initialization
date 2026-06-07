# Makefile — init_ubuntu CI entry points
#
# Borrowed from ycpss91255-docker/base v0.28.0 (commit ade915a) Makefile.ci
# Customizations vs upstream:
#   - Renamed to plain Makefile (no symlink-based redirection; we don't use
#     the base subtree flow per PRD §17.2 "Post-install Self-Management")
#   - Removed `test-behavioural` target (no Docker image build/publish)
#   - Removed `init` / `upgrade` / `upgrade-check` (base subtree mgmt only)
#   - Added `test-unit` / `test-integration` (finer-grained selection per
#     PRD §11 AC-17/AC-18)
#   - Added `build-test-tools` (explicit local image build, no implicit
#     pull from ghcr since we don't publish to ghcr)
#
# All test workflows run inside Docker (PRD G5: "全部在 Docker 內驗證").

.PHONY: test test-unit test-integration lint coverage coverage-unit coverage-merge build-test-tools clean help
.DEFAULT_GOAL := help

# ── Content-keyed image tag (issue #113) ─────────────────────────────────────
# Parallel worktrees on one host clobbered the single `test-tools:local`
# tag. The tag is now content-addressed —
# test-tools:<sha256(Dockerfile.test-tools) first 12> — resolved by
# script/ci/resolve_test_tools_tag.sh and exported so compose.yaml
# (${TEST_TOOLS_IMAGE:-test-tools:local}) and ci.sh see the same value.
# An explicit TEST_TOOLS_IMAGE=<ref> on the make command line / env wins.
ifeq ($(origin TEST_TOOLS_IMAGE), undefined)
TEST_TOOLS_IMAGE := $(shell ./script/ci/resolve_test_tools_tag.sh)
endif
export TEST_TOOLS_IMAGE

# ── Prebuilt image escape hatch (CI; issue #26) ──────────────────────────────
# GitHub Actions builds the content-keyed test-tools image ONCE in the
# `build-image` job and `docker load`s it in downstream jobs. Those jobs pass
# TEST_TOOLS_PREBUILT=1 so targets skip the redundant local rebuild. Local
# dev keeps the default (build before run; cached layers make repeat builds
# cheap).
ifeq ($(TEST_TOOLS_PREBUILT),1)
TEST_TOOLS_DEP :=
else
TEST_TOOLS_DEP := build-test-tools
endif

# ── Development ──────────────────────────────────────────────────────────────

test: $(TEST_TOOLS_DEP) ## Run ShellCheck + Bats (unit + integration; no kcov — fast dev loop)
	./script/ci/ci.sh

# MODULE=<name> narrows to test/unit/module/<name>_spec.bats;
# MODULE=core runs the non-module specs only (per-module CI matrix,
# issue #31). Unset = full unit tree (unchanged).
test-unit: $(TEST_TOOLS_DEP) ## Run unit bats only (optional MODULE=<name>|core)
	./script/ci/ci.sh --unit-only $(if $(MODULE),--module $(MODULE))

test-integration: $(TEST_TOOLS_DEP) ## Run integration bats only (slower; container-based)
	./script/ci/ci.sh --integration-only

lint: $(TEST_TOOLS_DEP) ## Run ShellCheck + fish syntax + hadolint
	./script/ci/ci.sh --lint-only

coverage: $(TEST_TOOLS_DEP) ## Run ShellCheck + Bats + kcov coverage report
	./script/ci/ci.sh --coverage

# ── Per-shard coverage + merge (CI; issue #28) ───────────────────────────────
# CI runs each test-unit matrix shard ONCE under kcov (no separate
# test-unit + coverage double run): `coverage-unit MODULE=<name>|core`
# writes coverage/shard-<name>; the aggregation job downloads all shard
# artifacts and runs `coverage-merge`, which kcov-merges them and asserts
# the coverage gate (>= $COVERAGE_MIN, default 66 — ratchet baseline;
# AC-17's 80% flips in via #124 after #122/#123) on the MERGED result.
# CI enforces the gate only on full-matrix runs; narrow PR matrices run
# it report-only ($COVERAGE_ENFORCE=false — see ci.sh / ci.yaml).
# Local dev keeps `make coverage` (full kcov run, unit + integration).

coverage-unit: $(TEST_TOOLS_DEP) ## Run unit bats once under kcov (optional MODULE=<name>|core) → coverage/shard-*
	./script/ci/ci.sh --unit-only --kcov $(if $(MODULE),--module $(MODULE))

coverage-merge: $(TEST_TOOLS_DEP) ## Merge coverage/*shard-* + assert ratchet gate (>= $$COVERAGE_MIN, default 66) on merged result
	./script/ci/ci.sh --merge-coverage

# ── Image build ──────────────────────────────────────────────────────────────

# Builds the content-keyed tag (issue #113) and re-points the legacy
# `test-tools:local` alias at it (muscle memory; plain `docker compose run`
# without the Makefile keeps working in single-worktree setups).
build-test-tools: ## Build the content-keyed test-tools image (+ test-tools:local alias)
	@test -n "$(TEST_TOOLS_IMAGE)" || { \
		echo "ERROR: could not resolve test-tools image tag" \
		     "(script/ci/resolve_test_tools_tag.sh failed — see stderr above)" >&2; \
		exit 1; }
	docker build -t "$(TEST_TOOLS_IMAGE)" -f dockerfile/Dockerfile.test-tools .
	docker tag "$(TEST_TOOLS_IMAGE)" test-tools:local

# ── Cleanup ──────────────────────────────────────────────────────────────────

clean: ## Remove coverage reports and tmp artifacts
	rm -rf coverage/ .tmp/

# ── Help ─────────────────────────────────────────────────────────────────────

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*##"}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
