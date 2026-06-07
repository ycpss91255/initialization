# Worktree workflow

This repo uses `git worktree` for all fix / feature work. The main checkout
(`~/Desktop/initialization/` on the maintainer's box) **always stays at
`origin/main`** — never carry an in-progress branch in the main checkout.

Aligned with `ycpss91255-docker/docker_harness#22` (which closed the same
pattern across the harness's downstream repos).

## Layout

```
~/Desktop/initialization/         ← main checkout, always tracks origin/main
└── worktree/                     ← gitignored except for .gitkeep
    ├── 64-engine-upgrade/        ← <N>-<slug> where N is issue/task#
    ├── 69-cookbook/
    └── ...
```

## Lifecycle of a feature / fix branch

### Start

```bash
# 1. Make sure main is fresh first (a hook will BLOCK worktree-add otherwise)
git -C ~/Desktop/initialization fetch origin
git -C ~/Desktop/initialization pull --ff-only origin main

# 2. Create the worktree + branch atomically
cd ~/Desktop/initialization
git worktree add worktree/<N>-<slug> -b feat/<slug> origin/main
#                  └─ path on disk     └─ new branch  └─ base ref

# 3. Move into the worktree to work
cd worktree/<N>-<slug>
```

### Commit + push

```bash
# Inside the worktree:
git add -A
git commit -m "feat: ..."
git push -u origin feat/<slug>
gh pr create --title "..." --body-file <(cat <<'EOF'
## Summary
...
## Test plan
- [x] make test-unit (267 ok / 0 failed)
EOF
)
```

### Merge

PR merges back into `main` via GitHub UI (or `gh pr merge`). The local main
checkout does **not** carry the change directly — wait for the merge, then
update main:

```bash
cd ~/Desktop/initialization      # main checkout
git fetch origin
git pull --ff-only origin main   # remind_main_sync.sh hook nags about this
```

### Cleanup

```bash
# After merge:
cd ~/Desktop/initialization
git worktree remove worktree/<N>-<slug>
git branch -D feat/<slug>        # local branch (remote auto-deleted by PR merge)
```

## Naming

`worktree/<N>-<slug>` where `<N>` is the GitHub issue (or local task) number
and `<slug>` is a kebab-case summary.

Examples:
- `worktree/64-engine-upgrade-verify-doctor`
- `worktree/69-archetype-cookbook`
- `worktree/72-apt-is-outdated`

Sort-order benefit: numerical prefix groups by issue + survives `ls`.

If there's no issue yet (exploratory branch), open the issue first via
`gh issue create` — see [issue-tracker.md](../agent/issue-tracker.md).

## Hooks that enforce this

| Hook | Purpose |
|---|---|
| `.claude/hook/check_main_fresh_before_worktree.sh` | BLOCKs `git worktree add ... main` when local main is behind origin/main |
| `.claude/hook/remind_main_sync.sh` | Reminds to `git pull --ff-only` after `gh pr merge` |

## Branch naming

The branch name inside a worktree follows conventional-commits prefix:

| Prefix | Use case |
|---|---|
| `feat/<slug>` | new feature / behaviour change(Y bump candidate) |
| `fix/<slug>` | bug fix(Z bump candidate) |
| `refactor/<slug>` | internal restructure, no behaviour change |
| `doc/<slug>` | doc-only |
| `chore/<slug>` | tooling / housekeeping |
| `chore/release-<vX.Y.Z>` | release PR — see [release.md](release.md) |

## Gotchas

- **`.claude/` is per-repo, not per-worktree.** Hook scripts, skills, and
  rules live in the main checkout. Worktrees share the same `.claude/`
  via the git internals. Edits to `.claude/` from inside a worktree go
  through the same PR flow as any other file change.
- **Don't `git checkout` in the main checkout.** If you accidentally moved
  main off `origin/main`, `git fetch origin && git reset --hard origin/main`
  is the recovery (destructive — ensure you have no uncommitted work first).
- **`.claude/projects/` is symlinked from `~/.claude/projects/`.** Each
  worktree's session state lands in the same repo location. See
  `.claude/projects/memory/reference-memory-location.md`.
