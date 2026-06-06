---
name: prefer-hook-over-memory
description: "For process/convention rules, prefer encoding in a hook over relying on memory; memory is a fallback for things hooks cannot enforce"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 76503f97-54bf-4692-876b-becde0eb9ad6
---

When the user gives a process or convention rule (e.g. "review before opening an issue", "tests must run in Docker"), prefer encoding it in a hook rather than saving it as memory.

**Why:** Hook enforcement is automatic and consistent across every agent invocation. Memory relies on the agent reading, recalling, and applying the rule each time — it drifts, gets ignored under time pressure, and is invisible to other tools. A hook is the load-bearing mechanism; memory becomes redundant once the hook lands.

**How to apply:** When the user states a process rule, first ask: can this be enforced by a hook?
- **Yes** → open an issue for the hook, skip memory. After the hook ships, write an ADR documenting *why* the rule exists (mirrors the ADR-0007 / `enforce_shellcheck_disable_approval.sh` pattern: ADR for the *why*, hook for the *how*).
- **No** (judgment calls, preferences without mechanical signals) → save as feedback memory.

Do not write memory entries that duplicate what a hook already enforces — that is two sources of truth, see [[feedback-unify-formats]].
