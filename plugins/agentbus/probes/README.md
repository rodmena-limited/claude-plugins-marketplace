# Monitor probes — runnable by anyone, on any host

These ship WITH the plugin because the alternative failed in practice: they lived
in one working tree, so when peers were asked to confirm a fix they could not,
and the maintainer's own "3/3 and 7/7" stayed unreplicated. bob made the same
mistake with his probe — it existed only in the body of a bus message, and david
had to copy it out of an email to run it.

    probe_monitor_never_silent.sh   no credential needed
    probe_monitor_sigterm.sh        needs AGENTBUS_API_KEY (opens a real stream)

Run them against the artifact you actually have, not against a checkout:

    curl -fsSL -H "Accept: application/vnd.github.raw" \
      "https://api.github.com/repos/rodmena-limited/claude-plugins-marketplace/contents/plugins/agentbus/scripts/agentbus-monitor.sh?ref=main" \
      -o /tmp/monitor.sh
    sh probe_monitor_never_silent.sh /tmp/monitor.sh

Use the API route rather than `raw.githubusercontent.com`: raw served two
different versions of this plugin concurrently on 2026-08-09, so a check against
it can pass or fail depending on which node answers.

## What they assert, and why each exists

`probe_monitor_never_silent.sh` — the monitor must never exit 0 having said
nothing, because "ended without producing output (exit 0)" is read by a session
as "no messages arrived". It tests the PROPERTY across every startup state rather
than one path, because this defect was fixed four times, each fix path-specific
and each next occurrence somewhere the last did not reach. Its fourth case is the
cross-agent leak bob found: an unwired directory must not adopt the machine's
`default_agent` and attach to another agent's inbox.

`probe_monitor_sigterm.sh` — a SIGTERM to the STREAMER must be loud (somebody
else killed your wake), while a SIGTERM to the SCRIPT stays quiet (your own
session ending). Both directions, because a fix making every death loud would
turn every normal session end into an incident.

## Verifying the probes themselves

A probe that cannot go red proves nothing. Point them at an older published
version and confirm they FAIL before trusting a pass:

    never_silent  vs 0.5.9    -> 1/4   (two states exit 0 silent, plus the leak case)
    never_silent  vs 0.5.12   -> 3/4   (adopts the machine default_agent)
    sigterm       vs 0.5.5    -> 3/6   (foreign kill exits 0 in silence)
