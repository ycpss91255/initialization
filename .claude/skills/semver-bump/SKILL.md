# semver-bump

Cut version tags via the canonical script with X consent + RC enforcement.

## When to use

Whenever you're cutting a version tag (`vX.Y.Z` or `vX.Y.Z-rcN`) in
this org. The hook `enforce_semver_tag_via_script.sh` BLOCKs ad-hoc
`git tag v*` / `git push.*v[0-9]` to force this path.

## Bump classification

| Tag shape | Bump | Requires |
|---|---|---|
| `vX.Y.Z-rcN` | RC tag itself | tag + push (no RC, no ACK) |
| `vX.Y.Z` where `Z>0` | Z (bug fix) | tag + push (no RC, no ACK) |
| `vX.Y.0` where `Y > prev_Y` | Y (feature / behaviour / break) | prior `vX.Y.0-rcN` with CI all `success`/`skipped` |
| `vX.0.0` where `X > prev_X` | X (ceremonial) | above PLUS `RELEASE_X_BUMP_ACK=<tag>` |

`.version` (if present at repo root) must equal the tag literal --
otherwise the script exits 2 with a hint to run `/release` first.

### Project semantics (rule as of 2026-05-15, issue #106)

- **X bump** is purely ceremonial / marketing. Decoupled from
  "breaking change". Cut only when the user explicitly says so;
  the script enforces this with the ACK env.
- **Y bump** covers ALL user-visible non-bug-fix changes: new
  features, behaviour changes, breaking changes. Y bumps always
  go through RC.
- **Z bump** is reserved for bug fixes (and doc fixes). No RC, no
  ACK. Direct tag.

If you're unsure whether a change is Y or Z, lean Y -- the cost
of one extra RC cycle is small; the cost of an unannounced behaviour
change shipped as a Z patch is large.

## Procedure

### Z bump (bug fix)

```
.claude/script/release-tag.sh v1.3.1 -m "v1.3.1: <release notes>"
```

Direct. No RC step.

### Y bump (feature / behaviour / breaking)

```
# 1. Cut RC
.claude/script/release-tag.sh v1.3.0-rc1 -m "v1.3.0-rc1: <notes>"

# 2. Wait CI on the RC tag (use wait-tag-ci skill)
.claude/script/wait-tag-ci.sh --repo ycpss91255-docker/<repo> --branch v1.3.0-rc1

# 3. Promote to non-RC
.claude/script/release-tag.sh v1.3.0 -m "v1.3.0: <notes>"
```

The script's RC CI query (`gh run list --branch vX.Y.0-rcN`) must
return all conclusions in `success`/`skipped`; otherwise the
promote step exits 1 with a hint to cut `rcN+1`.

### X bump (ceremonial -- needs user OK)

```
# 1. Ask user in chat: "ok to cut v1.0.0?"
# 2. Only after explicit user "yes" / "ok":
.claude/script/release-tag.sh v1.0.0-rc1 -m "v1.0.0-rc1: <notes>"

# 3. Wait CI
.claude/script/wait-tag-ci.sh --repo ycpss91255-docker/<repo> --branch v1.0.0-rc1

# 4. Promote with ACK env (value must equal the tag literal)
RELEASE_X_BUMP_ACK=v1.0.0 \
  .claude/script/release-tag.sh v1.0.0 -m "v1.0.0: <notes>"
```

**Claude must not set `RELEASE_X_BUMP_ACK` on its own initiative.**
The env value must come from a user explicit OK in the current
conversation. The script enforces this by exiting 1 when the ACK
is missing or does not match the tag literal verbatim.

### RC failure handling

If the RC's CI fails (any check `FAILURE` / `CANCELLED` /
`TIMED_OUT`):

- Fix the cause on `main` via a normal PR.
- Cut `rcN+1`, never re-tag the same `rcN` (the script accepts any
  `-rcN` so cut `vX.Y.0-rc2` etc.).
- Restart the wait + promote steps.

## Exit codes (the script)

| Exit | Meaning |
|---|---|
| `0` | Success (or `--dry-run` preview) |
| `1` | Blocked by rule (missing RC / failing RC CI / missing ACK / wrong ACK) |
| `2` | Argument or parse error (malformed tag / `.version` mismatch / missing flag value) |

## See also

- `.claude/script/release-tag.sh --help`
- `.claude/hook/enforce_semver_tag_via_script.sh` -- boundary guard
- `.claude/hook/check_tag_version_consistency.sh` -- defensive second
  layer (`.version` integrity, kept as belt-and-suspenders)
- `.claude/commands/release.md` -- orchestration (chore PR + `.version`
  bump + this script)
- `.claude/skills/wait-pr-ci/SKILL.md` -- the tag-scoped sibling
  `wait-tag-ci.sh` is used between RC and promote
- CLAUDE.md "version conventions" section -- narrative source of truth
