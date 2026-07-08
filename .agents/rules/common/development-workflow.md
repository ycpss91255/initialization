# Development Workflow

> This file extends [common/git-workflow.md](./git-workflow.md) with the full feature development process that happens before git operations.

The Feature Implementation Workflow describes the development pipeline: research, planning, TDD, code review, and then committing to git.

## Feature Implementation Workflow

0. **Research & Reuse** _(mandatory before any new implementation)_
   - **GitHub code search first:** Run `gh search repos` and `gh search code` to find existing implementations, templates, and patterns before writing anything new.
   - **Library docs second:** Use Context7 or primary vendor docs to confirm API behavior, package usage, and version-specific details before implementing.
   - **Exa only when the first two are insufficient:** Use Exa for broader web research or discovery after GitHub search and primary docs.
   - **Check package registries:** Search npm, PyPI, crates.io, and other registries before writing utility code. Prefer battle-tested libraries over hand-rolled solutions.
   - **Search for adaptable implementations:** Look for open-source projects that solve 80%+ of the problem and can be forked, ported, or wrapped.
   - Prefer adopting or porting a proven approach over writing net-new code when it meets the requirement.

1. **Plan First**
   - Use **planner** agent to create implementation plan
   - Generate planning docs before coding: PRD, architecture, system_design, tech_doc, task_list
   - Identify dependencies and risks
   - Break down into phases

2. **TDD Approach**
   - Use **tdd-guide** agent
   - Write tests first (RED)
   - Implement to pass tests (GREEN)
   - Refactor (IMPROVE)
   - Verify 80%+ coverage

3. **Code Review**
   - Use **code-reviewer** agent immediately after writing code
   - Address CRITICAL and HIGH issues
   - Fix MEDIUM issues when possible

4. **Commit & Push**
   - Detailed commit messages
   - Follow conventional commits format
   - See [git-workflow.md](./git-workflow.md) for commit message format and PR process

5. **Pre-Review Checks**
   - Verify all automated checks (CI/CD) are passing
   - Resolve any merge conflicts
   - Ensure branch is up to date with target branch
   - Only request review after these checks pass

## GitHub Issue / PR Review Approval (mandatory before `gh ... create`)

`gh issue create|edit` and `gh pr create|edit` publish content to a
public, indexed repo. The user must see and approve the draft BEFORE it
lands. Enforced by `.claude/hook/enforce_gh_review_approval.sh`
(PreToolUse on Bash), which denies these commands until the session
transcript contains an explicit user approval phrase -- the same
transcript-based approval discipline as
`enforce_shellcheck_disable_approval.sh`.

Default flow:

1. Write the draft in the user's working language (zh-TW) to a local
   file, e.g. `/tmp/<slug>.zh.md`.
2. Show the path (and/or a short summary) and ask the user to review it.
3. After the user approves, translate the approved content to English.
4. Run `gh issue create` / `gh pr create` with the English `--body-file`.
   English-only enforcement (`enforce_gh_english.sh`) still runs.

Approval phrases (case-insensitive; any one is enough):

- `approve issue` / `issue ok` -> authorizes `gh issue create|edit`
- `approve pr` / `pr ok` -> authorizes `gh pr create|edit`
- `skip review` -> the explicit opt-out; authorizes either kind when the
  user says to go straight to create ("just open the issue" style).

The canonical tokens stay English so the hook check is locale-agnostic.
Emergency bypass (leaves an audit trail in shell history):
`ECC_ALLOW_GH_REVIEW=1`.
