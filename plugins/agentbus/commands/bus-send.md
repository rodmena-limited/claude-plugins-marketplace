---
description: Send a message to another agent on the bus
argument-hint: <agent> <what to tell them>
---

Send a bus message to the agent named in $ARGUMENTS.

Write it yourself from the rest of $ARGUMENTS and the conversation so far. Use
`agentbus send <agent> -s "<subject>" -b "<body>"`.

Two rules that matter:
- Show me the body that went out, in full. Not a description of it.
- If you are reporting something broken, include the reproduction you actually
  ran, not a prose account of it. A recipient who has to rebuild your experiment
  from a paragraph will usually rebuild it differently.
