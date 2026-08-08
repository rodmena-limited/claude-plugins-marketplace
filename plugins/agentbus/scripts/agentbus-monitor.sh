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
    if [ -d "$CONFIG_DIR/keys" ] || [ -r "$CONFIG_DIR/operator.env" ]; then
        if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            echo "AgentBus monitor: this project has no agent, so NOTHING is being watched." >&2
            echo "  AgentBus is signed in on this machine but this project is not wired." >&2
            echo "  Wire it (once, per project):  agentbus setup claude" >&2
        fi
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

# No key anywhere: say so ONCE on stderr and stop. Exiting quietly here would
# make "not signed in" indistinguishable from "nobody has written to you".
if [ -z "${AGENTBUS_API_KEY:-}" ]; then
    echo "AgentBus monitor: no credential for '$agent' ($KEYFILE). Run: agentbus signin <key>" >&2
    exit 0
fi

command -v agentbus >/dev/null 2>&1 || {
    echo "AgentBus monitor: the 'agentbus' CLI is not on PATH. Install: curl -fsSL https://agentbus.rodmena.co.uk/install.sh | bash" >&2
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
cleanup() {
    [ -n "$child" ] && kill "$child" 2>/dev/null
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
INJECT=""
if [ -n "${CLAUDE_CODE_MESSAGING_SOCKET:-}" ] && command -v agentbus-hook >/dev/null 2>&1; then
    INJECT="agentbus-hook inject --sender {sender} --subject {subject} --delivery {delivery_id} --seq {agent_seq}"
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
    # Clean exit: the session is going away, or the key is gone. Either way this
    # is not something a retry fixes.
    [ "$status" -eq 0 ] && exit 0
    # 143 = SIGTERM. Nothing sends that to the streamer except a deliberate
    # teardown — this session's SessionEnd reap, or shutdown. Respawning after
    # it would fight the reap and re-leak the subscription it just closed.
    if [ "$status" -eq 143 ]; then
        exit 0
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

echo "AgentBus monitor: the stream failed 5 times in a row without staying up 60s (last exit $status)." >&2
echo "  This is a startup failure, not a reap: a deliberate teardown exits 143 and stops quietly." >&2
echo "  Check the credential and connectivity: agentbus doctor --wake" >&2
exit 0
