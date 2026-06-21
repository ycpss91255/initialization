---
name: project-ci-lint-covers-bats
description: "CI lint runs shellcheck -x on *.bats too; validate bats files, not just .sh, before integrating"
metadata: 
  node_type: memory
  type: project
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
---

The CI `lint` job (`ci.sh --ci-lint` -> `_find_lintable_sh | xargs -0 shellcheck -x`)
globs `*.sh` AND `*.bash` AND `*.bats`, at shellcheck's default severity (info
included). So an info-level finding in a `.bats` file (e.g. SC2030/SC2031) fails
the lint job even though all bats TESTS pass.

**Why:** a standalone `export VAR=...` inside an `@test` body is "modification
local to the bats subshell" (SC2030), and a later read is SC2031. The passing
convention in this repo is the inline command-prefix form: `VAR=val run cmd ...`
(see the `tui_render_input` / MOCK_WIDGET_OUTPUT cases), which is scoped to the
command and not flagged.

**How to apply:** when an agent adds/edits `.bats` files, validate with
`shellcheck -x <file>` (or run `ci.sh --ci-lint` inside the container) BEFORE
opening the PR — local `bats` runs and shellcheck-on-`.sh`-only both miss this,
and it surfaces only as a red `lint` job. Prefer `VAR=val run ...` over a
standalone `export VAR=...` in test bodies. Relates to [[feedback-autonomous-test-gap-remediation]].
