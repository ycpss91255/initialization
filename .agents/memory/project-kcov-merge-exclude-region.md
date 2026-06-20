---
name: project-kcov-merge-exclude-region
description: "kcov --exclude-region must be on the `kcov --merge` command, not just the per-shard runs, or the AC-17 gate ignores it"
metadata: 
  node_type: memory
  type: project
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
---

The AC-17 coverage gate reads `coverage/merged/**/coverage.json`'s overall
`percent_covered`, produced by `kcov --merge` (script/ci/ci.sh
`_merged_coverage_percent`). `kcov --merge` re-derives per-file totals from raw
shard data and does **NOT** inherit `--exclude-region` applied during per-shard
generation. So passing `--exclude-region` only to the shard kcov runs
(`_bats_unit`, `_run_coverage`) changes the shard reports but leaves the merged
gate number unchanged. It MUST also be on the `kcov --merge` invocation
(ci.sh ~L449). Verified: merged sync.sh total 182→135 once the merge got the flag.

**Why this matters for i18n (#185):** a multi-line `declare -gA TABLE=( [k]=v … )`
makes kcov count every entry line as instrumented-but-uncovered (the DEBUG trap
fires only on the `declare` line). The zh-TW catalogs added ~440 such data lines,
dropping merged coverage 80.5%→76.41%. The catalogs are wrapped with
`# kcov-exclude-start` / `# kcov-exclude-end` markers and excluded via
`--exclude-region='kcov-exclude-start:kcov-exclude-end'` in all three kcov calls.

Coverage headroom is thin: main sits ~80.5% against the 80% gate, so any new
batch of untestable data lines needs exclusion or it tips the gate. See
[[project-release-tag-ceremony]].
