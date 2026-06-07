# Tests MUST run in Docker, never on the host (hard rule)

All `bats` / module-lifecycle invocations execute inside the
`test-tools:local` container via `make test-unit` / `make test-integration` /
`make coverage`. **Running `bats` directly on the host, or invoking
`bash module/<x>.module.sh install` on the host, is prohibited — no
exceptions, no temporary debug shortcuts, no "just this once."**

The rule exists because Module Action Phases (`install` / `upgrade` /
`remove` / `purge`) really call `sudo apt-get`, `curl`, `rm -rf`,
`add-apt-repository`, `chsh`, etc. against whatever system invokes them.
Running them on the developer host — even with `--dry-run` — leaves a single
forgotten flag away from real destructive side effects on the maintainer's
working machine. Docker provides the only safe isolation boundary.

## Considered Options

- **Soft convention** (current state pre-ADR): rule mentioned in Makefile
  comment + PRD G5 but not enforced. Rejected because a single slip during
  rapid iteration can clobber the dev host irreversibly.
- **Run on host with `--dry-run` guards in tests**: rejected because (a)
  dry-run flag depends on every module honoring it correctly, (b) tests
  may legitimately need to verify real side effects, (c) any test that
  forgets the flag becomes a bomb.

## Enforcement

1. `Makefile` test targets exclusively call `script/ci/ci.sh` which routes
   through `docker compose run --rm ci ...`.
2. `.claude/hook/test-must-use-docker.sh` — a Claude PreToolUse Bash hook
   that blocks the following patterns on the host:
   - `bats ` / `bats -` (direct bats invocation)
   - `bash module/*.module.sh <action-phase>` (Action Phase = install /
     upgrade / remove / purge)
   - `sudo apt-get install` / `sudo apt install` (apt install outside container)
3. Documented as a hard rule in `doc/TESTING.md` (banner at top).
4. CI matrix (GitHub Actions) also runs through Docker, mirroring the
   developer workflow exactly.

## Permitted exceptions

None for Action Phases. Read-only Query Phases (`detect`, `is_installed`,
`is_recommended`, `is_outdated`) and helper-provided Phases (`info`,
`status`, `--help`, `--version`) are safe on the host because they never
mutate state, but as a hygiene rule they should also go through Docker for
consistency with the test workflow.

## Consequences

- A small overhead per test invocation (Docker compose run startup ≈ 1s).
- Developers cannot iterate via direct host `bats` even for one-off debug.
  Acceptable: `make test-unit` is the only entry point.
- The hook script must stay current with new dangerous patterns (e.g. if
  a new tool like `pip install` becomes a host-mutating risk, extend the
  hook).
