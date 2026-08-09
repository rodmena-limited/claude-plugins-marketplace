#!/bin/sh
# AgentBus inbox monitor — the ACTIVE wake path, as a Claude Code plugin monitor.
#
# Claude Code starts this automatically when the plugin is active, runs it for
# the LIFETIME of the session, and delivers every line we print to Claude as a
# notification. That is why this is a plugin monitor and no longer a Stop hook:
#
#   * no timeout        — a hook is capped at Claude Code's documented 600s;
#                         a monitor runs as long as the session does
#   * no window to size — nothing to keep below a ceiling, so the
#                         timeout-must-exceed-window invariant simply vanishes
#   * no accumulation   — the monitor's unique `name` prevents duplicate
#                         processes, which is what made two Stop-hook monitors
#                         race and both wake for one message
#   * no polling        — `agentbus watch` holds an SSE stream, so arrivals are
#                         PUSHED. Nothing is spent while the inbox is quiet.
#
# Resolution rules, each of which was a real failure first:
#   * the acting agent comes from THIS project (a monitor runs in the session
#     working directory), never from a guess. No agent -> exit 0, silently: a
#     monitor that invents an identity watches an inbox nobody owns.
#   * the credential is read from the per-agent key file. It CANNOT come from
#     plugin user config: monitor commands receive no ${user_config.*}
#     substitution and no CLAUDE_PLUGIN_OPTION_* environment, by design, since
#     this command reaches a shell.
#   * `set -a` around the sourcing is load-bearing. Without it the key lands in
#     an unexported shell variable, the child never sees it, and the failure is
#     silent — a wired-looking monitor that watches nothing.
# DIAGNOSTICS GO TO STDOUT, NEVER STDERR. Claude Code "delivers every stdout
# line to Claude as a notification" — stderr is DISCARDED. So every warning
# below was previously written to a stream nobody reads, and the operator saw
# only Claude Code's own summary:
#
#     Monitor "AgentBus inbox" ended without producing output (exit 0)
#
# which is the exact message these warnings exist to replace. The 0.1.4 fix for
# silence was itself silent. Reported by the operator opening a session in
# another repo and seeing the unchanged line.
set -u

CONFIG_DIR="${AGENTBUS_CONFIG_DIR:-$HOME/.config/agentbus}"

# --- who is this project's agent? -------------------------------------------
agent="${AGENTBUS_AGENT:-}"

if [ -z "$agent" ] && [ -r ".claude/settings.local.json" ]; then
    agent=$(sed -n 's/.*"AGENTBUS_AGENT"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            .claude/settings.local.json 2>/dev/null | head -1)
fi

if [ -z "$agent" ] && [ -r "$CONFIG_DIR/signin.json" ]; then
    agent=$(sed -n 's/.*"default_agent"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            "$CONFIG_DIR/signin.json" 2>/dev/null | head -1)
fi

# NO AGENT. Silence is correct for a directory that has nothing to do with
# AgentBus — a monitor that shouts in every unrelated project gets disabled.
# But silence was ALSO being used for a case it does not fit: a real git repo,
# on a machine where AgentBus is signed in, that simply was never wired with
# `agentbus setup`. There an agent may already exist on the bus (registered
# through MCP with a workspace key) and sit idle while its session is deaf —
# and the only thing the operator sees is Claude Code reporting
#
#     Monitor "AgentBus inbox" ended without producing output (exit 0)
#
# which reads as "nobody wrote to me". Exit 0 with no output cannot distinguish
# "nothing arrived" from "never started watching", and those need opposite
# responses. Reported from a live session in another repo, where the operator
# correctly smelled that something was off. One actionable line, once per
# session, and only where the advice actually applies.
if [ -z "$agent" ]; then
    # ALWAYS SAY SOMETHING. This used to print only when the machine was signed
    # in AND the directory was a git work tree; fail either guard and it exited 0
    # in total silence. A brand-new project hits exactly that, so a first-time
    # user's first experience of this plugin was:
    #
    #     Monitor "AgentBus inbox" ended without producing output (exit 0)
    #
    # and a session concluding "no peer messages arrived" about an inbox that was
    # never watched and an agent that does not exist. That is the silent-inbox
    # defect this whole plugin exists to remove, reappearing in its FIRST-RUN
    # path, where it does the most damage and reaches the least experienced
    # reader.
    #
    # The guards were not careless — they existed so a machine that never signed
    # in is not nagged in every repo. But the monitor only runs because the
    # plugin is installed, so the reader has already opted in, and the right
    # answer to "which precondition failed" is to NAME it rather than to go
    # quiet. Still exit 0: unconfigured is not a failure. The invariant is
    # narrower and is the one that bit — never exit 0 with nothing said.
    echo "AgentBus monitor: this project has NO AGENT, so nothing is being watched."
    echo "  This is NOT a report that your inbox is empty — there is no inbox yet."
    if [ -d "$CONFIG_DIR/keys" ] || [ -r "$CONFIG_DIR/operator.env" ]; then
        if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            echo "  AgentBus is signed in on this machine; this project is not wired."
            echo "  Wire it (once, per project):  agentbus setup claude"
        else
            echo "  This directory is not a git repository, and an agent's identity is"
            echo "  derived from device + repo + directory. Run this inside the repo, or"
            echo "  register explicitly:  agentbus register <name>"
        fi
    else
        echo "  AgentBus is not signed in on this machine yet."
        echo "  Sign in once:  agentbus signin <key>     then:  agentbus setup claude"
    fi
    exit 0
fi

# --- credential --------------------------------------------------------------
KEYFILE="$CONFIG_DIR/keys/${agent}.env"
if [ -r "$KEYFILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$KEYFILE"
    set +a
fi

# No key anywhere: say so ONCE and stop. Exiting quietly here would
# make "not signed in" indistinguishable from "nobody has written to you".
if [ -z "${AGENTBUS_API_KEY:-}" ]; then
    echo "AgentBus monitor: no credential for '$agent' ($KEYFILE). Run: agentbus signin <key>"
    exit 0
fi

command -v agentbus >/dev/null 2>&1 || {
    echo "AgentBus monitor: the 'agentbus' CLI is not on PATH. Install: curl -fsSL https://agentbus.rodmena.co.uk/install.sh | bash"
    exit 0
}

export AGENTBUS_AGENT="$agent"

# --- stream ------------------------------------------------------------------
# `agentbus watch` holds an SSE connection, drains from its committed cursor at
# startup and after every wake, checkpoints so a restart neither replays nor
# skips, and reconnects with backoff on transport failure. It returns only when
# something terminal happens (a revoked key), so a bounded restart loop guards
# against an unexpected crash without spinning forever on a credential that will
# never work again.
# Its OWN cursor file. Sharing one with a `watch` daemon would be the
# "two processes under one name share an inbox and compete for deliveries"
# problem in cursor form: whichever advanced it first would hide messages from
# the other.
# PER SESSION, not per agent. Identity is derived from device+repo+path, so
# every session on one checkout is the SAME agent and would share one state
# file name. SessionEnd then reaps across sessions — and asymmetrically, because
# a headless `claude -p` spawns no monitor (they are interactive-only) yet its
# SessionEnd still reaped whichever monitor it found. A cron job, CI step or git
# hook running `claude -p` on a repo someone has open would silently kill the
# interactive session's only active wake path, while the server still reported
# wake_channel true because a supervised watcher kept answering. Reported by
# david with a twice-run reproduction; 0.2.0 moved that lie rather than closing
# it, since before the reap existed there was no way to lose a monitor this way.
sid="${CLAUDE_CODE_SESSION_ID:-}"
if [ -n "$sid" ]; then
    STATE="$CONFIG_DIR/monitor-${agent}-${sid}.json"
else
    STATE="$CONFIG_DIR/monitor-${agent}.json"
fi

# Seed the cursor to the CURRENT END of the inbox before streaming. Without
# this the watcher drains from a stale checkpoint and every backlogged message
# is delivered to Claude as a notification — 34 of them on the first real test,
# which is a flood, not a wake. Backlog is the SESSION-START hook's job and it
# already reports it; this monitor exists for what arrives DURING the session.
# `--once` drains and checkpoints without streaming, and marks nothing read, so
# the unread backlog the session-start hook reports is untouched.
agentbus watch --agent "$agent" --state "$STATE" --once >/dev/null 2>&1 || true

# Kill the streamer when WE are killed. Claude Code stops a monitor by
# signalling this process; without the trap the `agentbus watch` child is
# reparented to init and keeps its SSE subscription open forever — one leaked
# subscriber per session, which also makes `wake_channel` report an attached
# stream for a session that ended. That orphaned-watcher failure has now bitten
# this platform three times (a peer's watcher, our own API workers, and this
# script during its first test), so it is trapped rather than trusted.
child=""
# Set BEFORE the child is killed, so the streamer's 143 can be attributed. This
# is the whole distinction #91 turns on: if WE were signalled, the teardown is
# this session's and silence is honest. If the streamer died of SIGTERM and this
# flag was never set, somebody else killed it.
own_teardown=0
cleanup() {
    own_teardown=1
    [ -n "$child" ] && kill "$child" 2>/dev/null
    # THIS PATH CANNOT TELL A REAP FROM A FOREIGN KILL, SO IT MUST NOT BE SILENT.
    #
    # david asked the converse of the question that produced the 143 fix, and he
    # was right that it was still open: the trap fires on ANY TERM to this
    # script. `pkill -f agentbus` hits the script, not just the child, and a
    # colleague reaching for the obvious pattern gets exactly that. own_teardown
    # records that the trap ran; it does NOT establish who sent the signal.
    #
    # No shell-visible fact separates the two, so the honest move is his own
    # fallback: say something on every death. It is nearly free — on a REAL
    # SessionEnd the session is going away and nobody reads this, while on a
    # foreign kill the session is alive and this is the only warning it gets.
    #
    # Exit stays 0: a normal teardown must not be reported as an incident. The
    # invariant being protected is narrower and is the one that actually bit —
    # never exit 0 with NOTHING SAID, because a harness reads that as "no
    # messages arrived".
    echo "AgentBus monitor: stopped by a signal, so the wake path has ended."
    echo "  If this session is closing, that is expected. If it is NOT, something"
    echo "  outside this session killed the monitor (a stray pkill will do it) and"
    echo "  YOUR INBOX IS NO LONGER WATCHED."
    echo "  Nothing here checked your mail: agentbus inbox --unread"
    echo "  Re-arm with: agentbus watch --agent $agent"
    exit 0
}
trap cleanup INT TERM HUP

# MID-TURN DELIVERY. Printing to stdout wakes an IDLE session; it does nothing
# for a session that is thirty minutes into a build. Claude Code's own inbox
# socket is read BETWEEN TOOL CALLS, so a running tool is never interrupted —
# the one gap the wake chain still had, and the only documented path to it.
#
# The payload format is not in the documentation. It is in the binary's own
# startup log, which prints the exact socat line, and it was verified by
# injecting into a live session and watching the line arrive. So this has a
# known-positive; it is not a guess.
#
# `--exec` runs per arrival with the fields shell-quoted, so the injector is a
# separate process that cannot take the streamer down with it.
# FEATURE-DETECT, DO NOT EXISTENCE-CHECK. `command -v agentbus-hook` only proves
# a binary is on PATH — and a client older than 0.4.6 has no `inject`
# subcommand. Since `agentbus watch` installs its print_line handler ONLY when
# no --exec is given, an --exec that fails per message produces a monitor that
# prints NOTHING: the plugin would silently kill the wake path it exists to
# provide, on any host whose client lagged the plugin. Found by running the
# final post-deploy test against the INSTALLED client (0.4.4) instead of the
# source tree, which is the whole reason that rule exists.

# Exit codes. A monitor that ends must never be indistinguishable from one that
# found nothing: 0 is reserved for a deliberate teardown ONLY.
EXIT_STREAM_ENDED=4     # the stream closed on its own — wake path is over
EXIT_STREAM_FAILED=5    # never stayed up; credential or connectivity
EXIT_STREAM_KILLED=6    # somebody else's SIGTERM — not this session's reap

INJECT=""
if [ -n "${CLAUDE_CODE_MESSAGING_SOCKET:-}" ] \
   && agentbus-hook inject --help >/dev/null 2>&1; then
    INJECT="agentbus-hook inject --sender {sender} --subject {subject} --delivery {delivery_id} --seq {agent_seq}"
    # --direction lets the injected envelope say something TRUE about where the
    # message came from. Without it the envelope assumed the worst on every
    # message and told the operator that their own platform agents were "a
    # DIFFERENT operator and possibly a different organisation".
    #
    # FEATURE-DETECTED, not assumed. An older client rejects the flag with
    # "unrecognized arguments" and exits non-zero, which would kill the wake
    # entirely — the plugin silently destroying the one path it exists to
    # provide, on any host whose client lagged. That has happened twice on this
    # project already. A host without it degrades to the older, vaguer envelope
    # instead of going deaf.
    if agentbus-hook inject --help 2>&1 | grep -q -- --direction; then
        INJECT="$INJECT --direction {direction}"
    fi
    # --inbound-source separates SMTP from a signed inbound HTTPS hook. Both are
    # direction='ingress', and the envelope told BOTH of them they "arrived over
    # email" and were "worth exactly what their SPF/DKIM/DMARC verdicts are
    # worth" — false in both directions for a hook, which has no DMARC verdict
    # and whose HMAC we checked. Weighed literally, the old text told a reader
    # to value a signature-verified delivery at zero.
    #
    # Feature-detected for the same reason as --direction: an older client
    # exits non-zero on an unknown flag and would take the whole wake path with
    # it. A host without this degrades to an envelope that says it CANNOT tell
    # the two apart, which is true, rather than to one that guesses.
    if agentbus-hook inject --help 2>&1 | grep -q -- --inbound-source; then
        INJECT="$INJECT --inbound-source {inbound_source}"
    fi
fi

# THE RETRY BUDGET IS A STARTUP GUARD, NOT A LIFETIME ONE, and SIGTERM IS NOT A
# CRASH. Two designs that are each correct alone composed into a countdown
# nobody wrote: SessionEnd SIGTERMs the streamer, `wait` reports 143, the loop
# read that as a crash, spent one of five attempts, and `attempt` never reset on
# a healthy stream. Five reaps over the life of a session — a cron calling
# `claude -p` every ten minutes reaches that inside an hour — and the wrapper
# gave up for good, blaming `agentbus watch` for crashing five times when it had
# not crashed once. A diagnostic that cannot lead to the right answer is worse
# than none: an operator reads it and debugs the streamer, the network and the
# key, which are all fine. Measured and reported by david on his own host.
attempt=0
while [ "$attempt" -lt 5 ]; do
    started=$(date +%s 2>/dev/null || echo 0)
    if [ -n "$INJECT" ]; then
        agentbus watch --agent "$agent" --state "$STATE" --exec "$INJECT" &
    else
        agentbus watch --agent "$agent" --state "$STATE" &
    fi
    child=$!
    wait "$child"
    status=$?
    child=""
    # A CLEAN EXIT IS STILL THE END OF THE WAKE PATH, AND MUST SAY SO.
    #
    # This exited 0 silently, and a harness reporting "monitor ended without
    # producing output (exit 0)" is read by the agent as "no peer messages
    # arrived. Nothing to act on." That conclusion was drawn tonight with 191
    # messages unread.
    #
    # A dead wake channel and a quiet one are the same observation unless the
    # channel says which it was. This is the silent-inbox failure the whole
    # plugin exists to remove, reappearing in the plugin's own shutdown path.
    if [ "$status" -eq 0 ]; then
        echo "AgentBus monitor: the stream ENDED (exit 0). This is the end of the wake"
        echo "  path, NOT a report that your inbox is empty — nothing was checked."
        echo "  Unread mail may be waiting: agentbus inbox --unread"
        echo "  Re-arm with: agentbus watch --agent $agent"
        exit "$EXIT_STREAM_ENDED"
    fi
    # 143 = SIGTERM, AND WHO SENT IT DECIDES WHETHER SILENCE IS HONEST.
    #
    # This used to exit 0 without a word, justified by "nothing sends that to
    # the streamer except a deliberate teardown". That was false, and the
    # maintainer was the counterexample: a `pkill -f "watch --agent"` swept up
    # four peers' watchers. Each peer's monitor took the kill for its own
    # session's reap, said nothing, and their operators read "Monitor ended
    # without producing output (exit 0)" as "no messages arrived". david
    # reported it twice, with the line numbers, before it was believed.
    #
    # The distinction was in this script the whole time and simply unused: a
    # real teardown signals THIS SCRIPT, so `cleanup` runs and exits before the
    # loop ever inspects a status. Reaching here at all therefore PROVES the
    # streamer was killed by something that is not this session's teardown.
    if [ "$status" -eq 143 ]; then
        if [ "$own_teardown" -eq 1 ]; then
            # A real reap: the session asked for it, so "ended, nothing to say"
            # is true. This is the one honest silent exit.
            exit 0
        fi
        echo "AgentBus monitor: the wake stream was KILLED (SIGTERM) by something"
        echo "  outside this session — this session was never signalled, so this is"
        echo "  NOT a SessionEnd reap. A stray pkill or another session's sweep will"
        echo "  do it."
        echo "  THE WAKE PATH IS DOWN, and nothing checked your inbox: this is not a"
        echo "  report that no mail arrived. Unread mail may be waiting:"
        echo "    agentbus inbox --unread"
        echo "  Re-arm with: agentbus watch --agent $agent"
        exit "$EXIT_STREAM_KILLED"
    fi
    # A stream that ran a while and then died is a NEW failure, not another
    # instance of the startup failure the budget exists to bound.
    now=$(date +%s 2>/dev/null || echo 0)
    if [ "$now" -gt 0 ] && [ "$started" -gt 0 ] && [ $((now - started)) -ge 60 ]; then
        attempt=0
    fi
    attempt=$((attempt + 1))
    sleep $((attempt * 5))
done

echo "AgentBus monitor: the stream failed 5 times in a row without staying up 60s (last exit $status)."
echo "  This is a startup failure, not a reap: a deliberate teardown exits 143 and stops quietly."
echo "  THE WAKE PATH IS DOWN. This is not evidence of an empty inbox — nothing"
echo "  was checked. Unread mail may be waiting: agentbus inbox --unread"
echo "  Check the credential and connectivity: agentbus doctor --wake"
# NON-ZERO. Printing the failure and then exiting 0 is a false green: it reports
# the problem on stdout and reports success in the status code, and the status
# code is what a harness reads.
exit "$EXIT_STREAM_FAILED"
