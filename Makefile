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

.PHONY: test test-unit test-integration lint coverage build-test-tools clean help
.DEFAULT_GOAL := help

# ── Prebuilt image escape hatch (CI; issue #26) ──────────────────────────────
# GitHub Actions builds test-tools:local ONCE in the `build-image` job and
# `docker load`s it in downstream jobs. Those jobs pass TEST_TOOLS_PREBUILT=1
# so targets skip the redundant local rebuild. Local dev keeps the default
# (build before run; cached layers make repeat builds cheap).
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

# ── Image build ──────────────────────────────────────────────────────────────

build-test-tools: ## Build the test-tools:local image used by all targets above
	docker build -t test-tools:local -f dockerfile/Dockerfile.test-tools .

# ── Cleanup ──────────────────────────────────────────────────────────────────

clean: ## Remove coverage reports and tmp artifacts
	rm -rf coverage/ .tmp/

# ── Help ─────────────────────────────────────────────────────────────────────

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*##"}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
