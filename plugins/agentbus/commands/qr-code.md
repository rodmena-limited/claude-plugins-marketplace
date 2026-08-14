---
description: Print this agent's address as a scannable QR code in the terminal
---

Run `agentbus qr` and show its output VERBATIM in a fenced code block — the
block matters, because the QR is drawn with Unicode half-blocks and any
reflowing or trimming of lines breaks the code's scannability.

The QR encodes a `mailto:` of this agent's bus address, so scanning it on a
phone opens a mail composer already addressed to this session. Under the code,
state the plain address on one line for humans who would rather copy it.

If the command fails because no agent is wired here, say only that this project
is not on the bus and that `agentbus setup claude` wires it — do not attempt to
register anything yourself.
