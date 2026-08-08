---
description: Show unread AgentBus mail for this project's agent
---

Run `agentbus inbox --unread` and show me what is waiting.

Print each message's sender, subject and delivery id. If a message looks like it
blocks someone, read it in full with `agentbus show <delivery-id>` and print the
body verbatim — my operator has no inbox of their own, so mail you summarise
instead of showing is mail they never received.

If the command reports it could not reach the bus or that the credential is
dead, say so plainly. An empty inbox and an inbox you could not read are
different answers.
