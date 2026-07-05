# Legacy Disposition Plan: `tool/` and `small-tools/`

Status: PROPOSAL for maintainer confirmation. Nothing has been deleted, moved,
or modified. This is a READ-ONLY survey producing a per-item recommendation.

Context: `tool/` and `small-tools/` are the v1 holding area, excluded from
lint/coverage by `script/ci/ci.sh` (PRD 6.5/6.6). Maintainer chose per-script
triage: PROMOTE issue-backed reusable scripts to v2 modules, DELETE truly-dead
scripts replaced by v2, KEEP genuine one-offs. Bias is toward KEEP; DELETE only
with strong, verified evidence.

## Reference / safety check

No LIVE executable code sources or invokes any file under `tool/` or
`small-tools/`. Every reference found is either documentation or the CI
exclusion itself:

- `script/ci/ci.sh:139,277` — intentionally excludes both dirs from
  shellcheck/coverage (deprecated).
- `doc/prd/init-ubuntu.prd.md` — §6.5/§6.6 exit paths, AC-27 (`small-tools/`
  removed by 0.4.0), Q42 (gnome-terminal note).
- `doc/review/*.md` — linux-review F2/F7/F19/F25/F26/F27, module-template-audit,
  test-pyramid-review (survey findings only).
- `TODO.md:179,227` — install instructions for `trash-maintenance.sh` (doc, not code).

Conclusion: no legacy file is wired into live code, so none is unsafe-to-delete
on a "still-sourced" basis. The DELETE recommendations below rest on v2
supersession, not on lack of references.

---

## KEEP

| File | Disposition | Evidence | v2 replacement | Still referenced? |
|------|-------------|----------|----------------|-------------------|
| `tool/copy_gnome_terminal_config.sh` | KEEP | One-off `dconf dump`/`load` helper for GNOME Terminal profiles. PRD Q42 removed it from catalog, defers destination to v0.2+. No v2 equivalent (module/config/gnome-terminal.conf is a config artifact, not a dump/load helper). | none | PRD Q42 (doc) |
| `tool/copy_neovim_local_config.sh` | KEEP | Personal one-off that copies `~/.config/nvim/lua/user` back into the repo; marked `#TODO: wait review`. No v2 equivalent. linux-review F25 flags destructive backup but it is a personal utility. | none | linux-review F25 |
| `tool/dual_system_time_sync.sh` | KEEP | Genuine one-off dual-boot RTC/timezone sync. PRD table: "v0.1 不處理". linux-review F7 flags deprecated `ntpdate` but that is a maintainer fix-later call, not a supersession. | none | PRD; linux-review F7 |
| `tool/setup_terminal_font_size.sh` | KEEP | One-off console-setup font sizer. PRD: "v0.1 不處理". linux-review F19 flags unvalidated input but it is a personal one-off. | none | PRD; linux-review F19 |
| `tool/ros1/rosbag_coreSAM.sh` | KEEP | Project-specific ROS1 experiment automation (LED x Y x Z sweep + rosbag record). No v2 equivalent; not a candidate for a generic module. | none | PRD `tool/ros1/*` |
| `tool/ros1/rosbag_play.sh` | KEEP | ROS1 one-off. NOTE minor typo `rosbag pay` (should be `play`) — flag for maintainer, but KEEP as one-off. | none | PRD `tool/ros1/*` |
| `tool/ros1/rosbag_record.sh` | KEEP | ROS1 dual-scan record helper. Genuine one-off. | none | PRD `tool/ros1/*` |
| `small-tools/README.adoc` | KEEP | Top-level doc for the `small-tools/` dir. PRD §6.6/AC-27 says retain a historical note in README through 0.4.0. | n/a | describes the dir |
| `small-tools/README_zh.adoc` | KEEP | Chinese counterpart of the above. | n/a | describes the dir |

---

## DELETE-SUPERSEDED (verified against v2)

| File | Disposition | Evidence | v2 replacement | Still referenced? |
|------|-------------|----------|----------------|-------------------|
| `tool/remove/remove_docker.sh` | DELETE-SUPERSEDED | `module/docker.module.sh` defines `remove()` (:135) and `purge()` (:142) with `CONFIG_PATHS`, covering apt purge + NVIDIA toolkit + keyrings + docker group. Manual script also has a bug (`2/dev/null` typo :14). | `module/docker.module.sh` remove()/purge() | no live code |
| `tool/remove/remove_font.sh` | DELETE-SUPERSEDED | `module/font.module.sh` defines `remove()` (:99) and `purge()` (:111). Manual script is also broken: iterates `${FONT_NAMES[@]}` but populates `FONTS_NAME` (undefined var → always empty). | `module/font.module.sh` remove()/purge() | no live code |
| `tool/remove/remove_neovim.sh` | DELETE-SUPERSEDED | `module/neovim.module.sh` uses `module_use_github_release_archetype` (:61) with `CONFIG_PATHS` (:56), auto-providing remove()/purge(). Manual script has a path bug (`${USER_HOME}.cargo/...` missing slash :~). | `module/neovim.module.sh` (archetype remove/purge) | no live code |
| `tool/remove/remove_nvidia_driver.sh` | DELETE-SUPERSEDED | `module/nvidia-driver.module.sh` defines `remove()` (:110) and `purge()` (:118). Manual script runs host `pip uninstall` (hard-rule violation). | `module/nvidia-driver.module.sh` remove()/purge() | no live code |
| `small-tools/config/fish/config.fish` | DELETE-SUPERSEDED | `module/config/fish/config.fish` is the rewritten v2 (editor detection loop, PATH setup, WSL stub). Functionally replaces the legacy interactive config. | `module/config/fish/config.fish` | no live code |
| `small-tools/config/fish/functions/docker-build-run.fish` | DELETE-SUPERSEDED | v2 function is a hardened rewrite (arg-names, exec checks, `--wraps`). Same name present in v2. | `module/config/fish/functions/docker-build-run.fish` | no live code |
| `small-tools/config/fish/functions/docker-exec.fish` | DELETE-SUPERSEDED | v2 rewrite adds guard + `return 1` + `/usr/bin/env bash`. | `module/config/fish/functions/docker-exec.fish` | no live code |
| `small-tools/config/fish/functions/efc.fish` | DELETE-SUPERSEDED | v2 adds EDITOR/file existence checks; same purpose. | `module/config/fish/functions/efc.fish` | no live code |
| `small-tools/config/fish/functions/ehk.fish` | DELETE-SUPERSEDED | v2 hardened rewrite, same name. | `module/config/fish/functions/ehk.fish` | no live code |
| `small-tools/config/fish/functions/etc.fish` | DELETE-SUPERSEDED | v2 points at `~/.config/tmux/tmux.conf` (XDG) + checks; legacy used `~/.tmux.conf`. v2 covers it. | `module/config/fish/functions/etc.fish` | no live code |
| `small-tools/config/fish/functions/sfc.fish` | DELETE-SUPERSEDED | v2 adds file-existence guard; same function. | `module/config/fish/functions/sfc.fish` | no live code |
| `small-tools/config/fish/functions/stc.fish` | DELETE-SUPERSEDED | v2 adds tmux-installed + server-running + file guards; XDG path. | `module/config/fish/functions/stc.fish` | no live code |
| `small-tools/config/fish/functions/system-update-upgrade.fish` | DELETE-SUPERSEDED | v2 adds per-step failure handling; same apt update/upgrade/autoremove/autoclean. | `module/config/fish/functions/system-update-upgrade.fish` | no live code |
| `small-tools/config/ssh/ssh_config` | DELETE-SUPERSEDED | `module/config/ssh_config` is the richer personalized version and covers the legacy hosts (`github`, `my_server`) plus many more. Legacy content is a strict subset. | `module/config/ssh_config` | no live code |
| `small-tools/config/tmux/tmux.conf` | DELETE-SUPERSEDED | `module/config/tmux/tmux.conf` is a superset (192 vs 133 lines): updated `tmux-256color`, XDG source path, adds arrow-key mirrors + zoom toggle + mouse double-click. Functionally covers legacy. | `module/config/tmux/tmux.conf` | no live code |
| `small-tools/config/.vimrc` | DELETE-SUPERSEDED | `module/config/vim_config` is the corrected same-length (259) version: fixes leading-space on line 1, `textwidth 80→120`, typo `jlug→Plug`. v2 is the fixed copy. | `module/config/vim_config` | no live code |
| `small-tools/tools/eza.sh` | DELETE-SUPERSEDED | `module/eza.module.sh` + `module/submodule/eza.sh` provide the full lifecycle install; legacy is a raw apt-repo snippet with no `set`, no guards. | `module/eza.module.sh` | no live code |

---

## PROMOTE

| File | Disposition | Evidence | v2 replacement | Still referenced? |
|------|-------------|----------|----------------|-------------------|
| `tool/trash-maintenance.sh` | PROMOTE | Issue-backed reusable tool (open issues #275/#277). Cron-driven trash cap/age maintenance. Separate feature workstream — becomes a v2 module or first-class one-off tool, not deleted. linux-review F27 notes a newline-in-filename edge case to fix during promotion. | future v2 module (workstream) | TODO.md:179,227 (doc) |

---

## FIX-OR-DELETE

| File | Disposition | Evidence | v2 replacement | Still referenced? |
|------|-------------|----------|----------------|-------------------|
| `tool/setup_wayland.sh` | FIX-OR-DELETE | linux-review F2 (CRITICAL): sources `${SCRIPT_PATH}/../function/logger.sh` and `general.sh`, but no `function/` dir exists relative to `tool/` — script aborts immediately, currently non-functional. Logic (GRUB `nvidia-drm.modeset=1`, GDM Wayland enable, AccountsService session) is otherwise substantive. ASK maintainer: fix the source path (repo logger lives at `module/function/`) if Wayland setup is still wanted, else delete as dead. | none (broken) | linux-review F2; module-template-audit |

---

## LEAVE-ALONE (per explicit instruction — maintainer handling separately)

| File | Disposition | Evidence |
|------|-------------|----------|
| `small-tools/config/tmux/tmux-powerline/config.sh` | LEAVE-ALONE | tmux-powerline (the runaway-RAM process) is being handled separately. Do not touch. |
| `small-tools/config/tmux/tmux-powerline/themes/my-theme.sh` | LEAVE-ALONE | Same — tmux-powerline theme, out of scope for this triage. |

---

## ASK-MAINTAINER (KEEP-or-MIGRATE — unique content or partial supersession)

| File | Disposition | Evidence | v2 replacement | Still referenced? |
|------|-------------|----------|----------------|-------------------|
| `small-tools/config/fish/fish_variables` | KEEP-or-MIGRATE | Machine-generated fish universal-variable dump with stale host-specific paths (`/home/iclab/...`). No v2 equivalent. Likely a stale generated artifact safe to drop, but unique and not covered by v2 — maintainer decides. | none | no |
| `small-tools/config/tmux/README_en.adoc` | KEEP-or-MIGRATE | Doc describing the legacy tmux setup. No v2 tmux README. tmux.conf itself is superseded; the doc is not clearly replaced. Low risk to keep; confirm whether to migrate/drop with the tmux workstream. | none | no |
| `small-tools/config/tmux/README_zh.adoc` | KEEP-or-MIGRATE | Chinese counterpart of the above. | none | no |
| `small-tools/install.sh` | KEEP-or-MIGRATE | Largely superseded by the module system / `setup_ubuntu install` (PRD §6.6). BUT installs a monitoring suite (bashtop, bmon, htop, iftop, iotop, nmon, powertop) — several tools may lack a v2 module. Also buggy (`software-properties` chain). Confirm module coverage of the full package list before deleting. | partial: module pipeline / `setup_ubuntu` | PRD §6.6; linux-review F20/F24 |
| `small-tools/remove.sh` | KEEP-or-MIGRATE | Uninstall counterpart of `install.sh`; paired decision. Buggy (`FDFIND_FILE=...j` stray char, `# BUG: fish not found`). Superseded in spirit by module remove/purge but tied to whatever `install.sh` uniquely covers. | partial: module remove/purge | paired with install.sh |

---

## Safe-to-delete-now shortlist (strongly-evidenced DELETE-SUPERSEDED only)

1. `tool/remove/remove_docker.sh` → `module/docker.module.sh` remove()/purge()
2. `tool/remove/remove_font.sh` → `module/font.module.sh` remove()/purge()
3. `tool/remove/remove_neovim.sh` → `module/neovim.module.sh` (archetype remove/purge + CONFIG_PATHS)
4. `tool/remove/remove_nvidia_driver.sh` → `module/nvidia-driver.module.sh` remove()/purge()
5. `small-tools/config/fish/config.fish` → `module/config/fish/config.fish`
6. `small-tools/config/fish/functions/docker-build-run.fish` → `module/config/fish/functions/docker-build-run.fish`
7. `small-tools/config/fish/functions/docker-exec.fish` → `module/config/fish/functions/docker-exec.fish`
8. `small-tools/config/fish/functions/efc.fish` → `module/config/fish/functions/efc.fish`
9. `small-tools/config/fish/functions/ehk.fish` → `module/config/fish/functions/ehk.fish`
10. `small-tools/config/fish/functions/etc.fish` → `module/config/fish/functions/etc.fish`
11. `small-tools/config/fish/functions/sfc.fish` → `module/config/fish/functions/sfc.fish`
12. `small-tools/config/fish/functions/stc.fish` → `module/config/fish/functions/stc.fish`
13. `small-tools/config/fish/functions/system-update-upgrade.fish` → `module/config/fish/functions/system-update-upgrade.fish`
14. `small-tools/config/ssh/ssh_config` → `module/config/ssh_config`
15. `small-tools/config/tmux/tmux.conf` → `module/config/tmux/tmux.conf`
16. `small-tools/config/.vimrc` → `module/config/vim_config`
17. `small-tools/tools/eza.sh` → `module/eza.module.sh`

## Ask-maintainer list

- `tool/setup_wayland.sh` — FIX (repair broken `../function/` source path) or DELETE (dead)?
- `tool/trash-maintenance.sh` — PROMOTE target for issues #275/#277 (separate workstream) — confirm module vs one-off.
- `small-tools/config/fish/fish_variables` — stale generated universal-var dump, no v2 equivalent; drop?
- `small-tools/config/tmux/README_en.adoc` / `README_zh.adoc` — migrate/drop with the tmux workstream?
- `small-tools/install.sh` + `small-tools/remove.sh` — confirm every package (esp. the monitoring suite) is covered by a v2 module before deleting.

## Counts

- KEEP: 9
- DELETE-SUPERSEDED: 17
- PROMOTE: 1
- FIX-OR-DELETE: 1
- LEAVE-ALONE: 2
- ASK-MAINTAINER (KEEP-or-MIGRATE): 5

Total files assessed: 35.
