# ADR-0007: Exit-code-contract scripts default to `set -uo pipefail`

- **Status:** Accepted
- **Date:** 2026-05-16
- **Refs:**
  - BashFAQ #105 — http://mywiki.wooledge.org/BashFAQ/105
  - Google Shell Style Guide — https://google.github.io/styleguide/shellguide.html
  - Bash Pitfalls — http://mywiki.wooledge.org/BashPitfalls
  - ADR-0004 (test isolation) — `doc/adr/0004-tests-must-run-in-docker-only.md`
  - Issue #17 (PRD for shellcheck disable approval hook)

## Context

`init_ubuntu` has two distinct families of shell scripts:

1. **Exit-code-contract scripts** — they decide an outcome and report it
   through stdout / stderr / exit code, then the caller acts on it. The
   `.claude/hook/*.sh` PreToolUse hooks (`enforce_gh_body_file.sh`,
   `enforce_gh_english.sh`, `check_changelog_drift.sh`,
   `remind_main_sync.sh`, `enforce_semver_tag_via_script.sh`,
   `check_main_fresh_before_worktree.sh`, `remind_ci_auto_merge.sh`) and
   `.claude/script/release-tag.sh` fall in this group. They must reach
   `main()` `return` / `exit <code>` with a deliberate value — Claude
   Code reads the exit code (and `permissionDecision` JSON) to decide
   allow vs deny.

2. **Always-act scripts** — they perform side effects and want any
   intermediate failure to abort the whole run. Module action phases
   (`install` / `upgrade` / `remove` / `purge`) and the
   `test-must-use-docker.sh` hook (one decision, fail-closed) fall
   here.

Bash's `set -e` (errexit) interacts poorly with the first family.
BashFAQ #105 documents the gotchas in detail; the relevant ones for an
exit-code-contract hook:

- `set -e` is **disabled inside function bodies tested by `&&` / `||`
  / `if`** (BashFAQ #105 — "command in a conditional context"). A
  hook that runs `match || handle_failure` will silently swallow
  errors inside `match` even though `-e` is in effect.
- `set -e` is **disabled inside subshells whose result is checked**
  — `$(...)` capture or `if cmd; ...` strips errexit from the child.
- `set -e` **exits on the first non-zero return** — even from a
  conditional `grep` / regex check that legitimately returns 1 to say
  "no match". An exit-code-contract hook that wants to emit
  `permissionDecision: allow` on no-match cannot use `-e` without
  guarding every probe with `|| true`, which then defeats the
  purpose.
- The Google Shell Style Guide ("Error Handling") notes the same:
  `set -e` is not a substitute for explicit error handling.

For example, in `enforce_gh_body_file.sh`:

```bash
if [[ "${cmd}" =~ ([[:space:]]|^)-l[[:space:]]+[^[:space:]]+ ]]; then
  return 0
fi
# fall through — return 1 from the [[ ]] above is the intended path
# under -e it would have already exited
```

The intent is "test patterns, return early when one matches, otherwise
fall through to the next check, then `main` returns 0". Under `-e`
each non-matching probe would terminate the script before reaching
the next probe.

`set -u` (nounset) and `set -o pipefail` are unambiguously useful for
both families:

- `-u` catches typos in variable names and missing `$1` defaults — the
  failure mode it produces (`bash: VAR: unbound variable` to stderr,
  non-zero exit) is loud and actionable.
- `-o pipefail` makes the exit code of `a | b | c` the rightmost
  non-zero, which an exit-code-contract caller actually wants.

## Decision

Exit-code-contract scripts default to:

```bash
set -uo pipefail
```

Always-act scripts use:

```bash
set -euo pipefail
```

## Considered Options

### (a) `-euo` everywhere

Rejected. The pattern collides with the contract: every conditional
probe in a hook would have to be wrapped in `|| true`, which dilutes
both readability and the guard's value. Past iterations of
`remind_main_sync.sh` showed the result was either a forest of
`|| true` or accidental early exits.

### (b) No strict mode (plain `#!/usr/bin/env bash`)

Rejected. `-u` catches a class of bugs (unbound variables, typo'd flag
names) that would otherwise silently produce empty matches and pass
through. `-o pipefail` is required for any composed pipeline whose
overall failure must be reported.

### (c) Per-script local-only enabling around critical sections

Considered briefly. Bash supports `set -e` inside a block and `set +e`
after, but the resulting code is harder to audit than choosing one
mode at the top of the file. Rejected.

## Exception criteria

A script may use `-euo pipefail` when **all** of the following hold:

1. It performs side effects whose partial completion is worse than
   no completion (apt installs, file writes, mounts, `rm -rf`).
2. It exposes exactly one decision point or has none (the caller does
   not introspect intermediate steps).
3. It does not use `[[ ... ]]` / `grep -q` / similar as a "probe that
   may return 1 by design".

Current `-euo` scripts that satisfy this:

- `.claude/hook/test-must-use-docker.sh` — single fail-closed
  decision: matches a banned pattern, denies; otherwise allows.

Module action phases (`install` / `upgrade` / `remove` / `purge`)
also satisfy this — they run real `sudo apt-get`, `curl`, `rm -rf`
sequences where a failed step should abort. Their convention is
inherited from the module template.

## Consequences

- **Positive:** Hooks can use natural bash conditional flow (regex
  probes, `grep`, `[[ ]]` tests) without wrapping every check in
  `|| true`. The pattern matches the existing hook landscape — no
  retroactive rewrites needed.
- **Positive:** `-u` still catches the most common bug class for
  exit-code-contract scripts (unbound variables, typo'd flag names).
- **Positive:** `-o pipefail` still surfaces failed pipeline stages
  correctly.
- **Negative:** Removing `-e` means relying on test coverage to catch
  bugs that `-e` would have flagged at runtime. Mitigation: every
  hook has bats tests under `test/unit/hook/` covering its
  observable outputs (introduced alongside this ADR for the new
  `enforce_shellcheck_disable_approval.sh` hook).
- **Negative:** A future contributor (human or agent) may copy a hook
  and assume `-e` is on. The companion `CLAUDE.md` `## Script
  conventions` section documents the default so the assumption stays
  in sync with reality.

## Enforcement

- The `## Script conventions` section of `CLAUDE.md` indexes this
  ADR and the new `enforce_shellcheck_disable_approval.sh` hook.
- Hook authors should grep existing hooks for the `set -uo pipefail`
  pattern before adding a new one; deviation requires updating the
  Exception criteria list above.
- No automated lint rule for the `set -` line itself; the convention
  is small enough that PR review catches drift.
