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

## Autonomous issue / PR policy

Issues and PRs are created and merged by agents without a per-item human
draft approval. The gate is technical, not conversational: a PR merges once
TDD is done and CI (`ci-passed`) is green -- push, `gh pr create`, arm
`gh pr merge --auto`, let the aggregator decide. No draft file, no
approval phrase, no wait for the maintainer.

The only thing that still needs the maintainer's explicit consent is a
**release tag** (`.claude/script/release-tag.sh`; see
`doc/process/release.md`).

What still applies to every `gh issue|pr create|comment`:

- English-only, emoji-free titles / bodies for this repository's issues
  and PRs (`enforce_gh_english.sh`).
- `--body-file` for bodies (`enforce_gh_body_file.sh`) and the issue
  template (`enforce_gh_issue_template.sh`).

History: the previous transcript-approval gate
(`enforce_gh_review_approval.sh`, issue #34) was retired on 2026-09-19 --
see `doc/changelog/CHANGELOG.md`.
