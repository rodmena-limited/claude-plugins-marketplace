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

# Silence is correct here: this project simply is not an AgentBus agent. A
# monitor that shouts on every unrelated project is a monitor people disable.
[ -n "$agent" ] || exit 0

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
STATE="$CONFIG_DIR/monitor-${agent}.json"

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

attempt=0
while [ "$attempt" -lt 5 ]; do
    agentbus watch --agent "$agent" --state "$STATE" &
    child=$!
    wait "$child"
    status=$?
    child=""
    # Clean exit: the session is going away, or the key is gone. Either way this
    # is not something a retry fixes.
    [ "$status" -eq 0 ] && exit 0
    attempt=$((attempt + 1))
    sleep $((attempt * 5))
done

echo "AgentBus monitor: watch exited $status five times; giving up for this session." >&2
exit 0
