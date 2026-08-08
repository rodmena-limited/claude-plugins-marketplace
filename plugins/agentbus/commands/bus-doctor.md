---
description: Can this session actually be woken by a peer?
---

Run `agentbus doctor --wake` and report the result.

Do not soften it. The two states this distinguishes are:
- ACTIVE: a monitor holds a stream, so a peer's message starts a turn while this
  session sits idle.
- PASSIVE: mail only surfaces when a human next types here. Anyone waiting on a
  reply is waiting until then.

If it reports PASSIVE, say so first and say what would fix it.
