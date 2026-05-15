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

# ── Development ──────────────────────────────────────────────────────────────

test: build-test-tools ## Run ShellCheck + Bats (unit + integration; no kcov — fast dev loop)
	./scripts/ci/ci.sh

test-unit: build-test-tools ## Run unit bats only (fastest feedback loop)
	./scripts/ci/ci.sh --unit-only

test-integration: build-test-tools ## Run integration bats only (slower; container-based)
	./scripts/ci/ci.sh --integration-only

lint: build-test-tools ## Run ShellCheck + fish syntax + hadolint
	./scripts/ci/ci.sh --lint-only

coverage: build-test-tools ## Run ShellCheck + Bats + kcov coverage report
	./scripts/ci/ci.sh --coverage

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
