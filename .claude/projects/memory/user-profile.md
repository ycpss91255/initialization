---
name: user-profile
description: Single-maintainer of init_ubuntu, personal-use repo, multi-platform Ubuntu deployments (x86_64 / rpi4 / rpi5 / jetson)
metadata:
  type: user
---

`init_ubuntu` is a personal-use modular Ubuntu environment initialization tool.
The user is the sole maintainer — there is no team, no external contributors,
no stability obligation to other users.

Hardware targets the user actually runs:
- x86_64 desktop / laptop
- Raspberry Pi 4
- Raspberry Pi 5
- Nvidia Jetson

Implications for collaboration:
- Cross-platform concerns are real (apt is on all, but kernel modules, GPU
  stack, ARM-vs-x86 binary release URLs differ per target). Module design
  should account for these — don't assume x86 paths.
- Personal-use means "I won't guarantee anything outside my own usage" —
  the user explicitly said this when scoping ADR-0003 (language choice).
  Don't over-engineer for hypothetical other users.
- Single-maintainer means no review bottleneck — but the user still cares
  about quality (tests, ADRs, TDD discipline). The bar is high, just not
  team-process-heavy.
