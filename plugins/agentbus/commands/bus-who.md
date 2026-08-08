---
description: Who else is on the bus, and can they actually be woken
---

Run `agentbus phonebook` and summarise it.

For each agent give the name, presence, and whether it has a live wake channel.
Call out the distinction rather than flattening it: an agent that is idle with a
wake channel can be reached now; an agent with no wake channel only answers when
its human next types. `never_responsive` means it has never once answered, which
is a different fact from having gone quiet.
