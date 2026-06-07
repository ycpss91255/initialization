# Release process

Aligned with `ycpss91255-docker/docker_harness#106` — semver workflow
with X / Y / Z bump rules and RC gating.

## Bump rules

| Shape | Semantics | RC required? | ACK required? |
|---|---|---|---|
| `vX.Y.Z` where `Z>0` | bug fix | no | no |
| `vX.Y.0` where `Y` bumped | feature / breaking change | **yes** (`vX.Y.0-rcN`) | no |
| `vX.0.0` where `X` bumped | ceremonial | **yes** | **yes** (`RELEASE_X_BUMP_ACK`) |
| `vX.Y.Z-rcN` | the RC tag itself | n/a | n/a |

All tag-creation must go through `.claude/script/release-tag.sh`. Direct
`git tag v*` / `git push origin v*` is **denied** by the
`enforce_semver_tag_via_script.sh` PreToolUse hook.

## Workflow

### 1. Decide the version

- Look at the changes since the last tag (`git log $(git describe
  --tags --abbrev=0)..HEAD`).
- If purely bug fixes / docs → next Z bump.
- If features or breaking changes → next Y bump, and you'll need an RC.
- X bump is ceremonial; only when project semantics meaningfully shift.

### 2. Cut a release PR

In a worktree (per `doc/process/worktree.md`):

```bash
cd ~/Desktop/initialization
git worktree add worktree/<N>-release-vX.Y.Z -b chore/release-vX.Y.Z origin/main
cd worktree/<N>-release-vX.Y.Z

# Bump .version
printf 'vX.Y.Z\n' > .version

# Promote CHANGELOG: change [Unreleased] heading to [vX.Y.Z] - YYYY-MM-DD
# Insert a fresh empty [Unreleased] heading above it.
$EDITOR doc/changelog/CHANGELOG.md

git add -A && git commit -m "chore: release vX.Y.Z"
git push -u origin chore/release-vX.Y.Z
gh pr create --title "chore: release vX.Y.Z" --body-file <(cat <<'EOF'
## Summary

<one-liner referencing the merged PRs being rolled into this release.>

No breaking changes from <previous version>.

## Test plan

- [x] CI green on PRs included in this release
- [ ] After merge: tag vX.Y.Z and verify CI re-runs cleanly on the tag
EOF
)
```

### 3. Wait CI green on the chore PR

CI must be green before merging. After merge, the local main checkout
must be brought forward (the `remind_main_sync.sh` hook nags about this
after `gh pr merge`):

```bash
cd ~/Desktop/initialization
git pull --ff-only origin main
```

### 4. Tag the merge commit

```bash
cd ~/Desktop/initialization

# Z bump:
.claude/script/release-tag.sh vX.Y.Z -m "v0.x.Z bug fixes: ..."

# Y bump — cut RC first:
.claude/script/release-tag.sh vX.Y.0-rc1 -m "rc1 release notes ..."
# Wait CI on the RC tag, then:
.claude/script/release-tag.sh vX.Y.0 -m "vX.Y.0 release notes ..."

# X bump — same as Y plus the ACK env var:
RELEASE_X_BUMP_ACK=v1.0.0 .claude/script/release-tag.sh v1.0.0 -m "..."
```

The script:
- Verifies `.version` matches the tag literally.
- For Y / X bumps: verifies the corresponding RC tag exists and all its
  CI conclusions are `success` or `skipped`.
- For X bumps: also verifies `RELEASE_X_BUMP_ACK=<tag>` is set and
  matches the tag literal.
- On success: `git tag -a` + `git push origin <tag>`.

### 5. GitHub release (optional)

`gh release create <tag>` against the tagged commit. Body draws from the
promoted `[vX.Y.Z]` CHANGELOG section.

## Cleanup

After merge + tag:

```bash
cd ~/Desktop/initialization
git worktree remove worktree/<N>-release-vX.Y.Z
git branch -D chore/release-vX.Y.Z
```

## Hooks that enforce this

| Hook | Behaviour |
|---|---|
| `.claude/hook/enforce_semver_tag_via_script.sh` | BLOCKs ad-hoc `git tag v*` / `git push.*v[0-9]` / `git push --tags`; redirects to `release-tag.sh` |
| `.claude/hook/check_changelog_drift.sh` | Reminds if `git commit` stages code without `doc/changelog/CHANGELOG.md` update |
| `.claude/hook/check_main_fresh_before_worktree.sh` | BLOCKs `git worktree add ... main` when local main is behind origin/main |
| `.claude/hook/remind_main_sync.sh` | After `gh pr merge`, reminds to `git pull --ff-only origin main` |

## Companion docs

- [worktree.md](worktree.md) — the worktree workflow used to cut the chore PR
- [`doc/adr/0005-folder-naming-plural-for-collections.md`](../adr/0005-folder-naming-plural-for-collections.md) — folder naming
- [`.claude/skills/semver-bump/SKILL.md`](../../.claude/skills/semver-bump/SKILL.md) — agent-facing skill summarising the same flow
