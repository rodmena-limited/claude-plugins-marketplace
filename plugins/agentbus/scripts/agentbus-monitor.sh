#!/bin/sh
# AgentBus inbox monitor: the ACTIVE wake path, run by Claude Code as a plugin
# monitor for the lifetime of the session. Every stdout line reaches Claude as a
# notification; stderr is discarded, so every diagnostic here goes to STDOUT.
#
# Rules this file keeps, each from a real incident (history: git log, SPECS/0020):
#   * identity comes only from $AGENTBUS_AGENT or the checkout's .agentbus/agent
#     (#90, #129). No identity, no key or no CLI means PARK SILENTLY (#108, #118).
#   * never exit 0 having said nothing: the harness reads that as "no mail".
#   * one live watcher per identity: a second one duplicates every wake.
#   * the key is sourced under `set -a`, or the child never sees it.
set -u

CONFIG_DIR="${AGENTBUS_CONFIG_DIR:-$HOME/.config/agentbus}"

# --- who is this project's agent? (precedence matches hooks/claude_code.py, #90)
agent="${AGENTBUS_AGENT:-}"

# One root for both file lookups, so a subdirectory of a checkout resolves the
# same identity as its top level.
root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

_declared_agent() {
    _d=""
    if [ -r "$1/.agentbus/agent" ]; then
        _d=$(tr -d ' \t\r\n' < "$1/.agentbus/agent" 2>/dev/null | head -1)
    fi
    if [ -z "$_d" ] && [ -r "$1/.claude/settings.local.json" ]; then
        _d=$(sed -n 's/.*"AGENTBUS_AGENT"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
             "$1/.claude/settings.local.json" 2>/dev/null | head -1)
    fi
    printf '%s' "$_d"
}

# #129: the harness injects the MAIN worktree's AGENTBUS_AGENT into a session
# opened in a LINKED worktree. Mirrored from claude_code.py::_worktree_identity_bleed.
# Only overridden when the environment provably came from the main worktree's
# file; a deliberate operator export still wins.
if [ -n "$agent" ]; then
    _common=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null || true)
    if [ -n "$_common" ]; then
        case "$_common" in
            /*) : ;;
            *) _common="$root/$_common" ;;
        esac
        _common=$(cd "$_common" 2>/dev/null && pwd -P || printf '%s' "$_common")
        _ourgit=$(cd "$root/.git" 2>/dev/null && pwd -P || printf '%s' "$root/.git")
        if [ "$_common" != "$_ourgit" ]; then
            _own=$(_declared_agent "$root")
            _main=$(_declared_agent "$(dirname "$_common")")
            if [ -n "$_own" ] && [ "$_own" != "$agent" ] && [ "$_main" = "$agent" ]; then
                echo "AgentBus monitor: \$AGENTBUS_AGENT is '$agent', the MAIN worktree's"
                echo "  identity, injected by the harness into this LINKED worktree. Using"
                echo "  this checkout's own declared identity '$_own' instead (#129)."
                agent="$_own"
            fi
        fi
    fi
fi

if [ -z "$agent" ]; then
    agent=$(_declared_agent "$root")
fi

# Legacy Claude Code declaration, kept so an upgrade does not deafen a session.
if [ -z "$agent" ] && [ -r "$root/.claude/settings.local.json" ]; then
    agent=$(sed -n 's/.*"AGENTBUS_AGENT"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            "$root/.claude/settings.local.json" 2>/dev/null | head -1)
fi

# PARK = `exec sleep`, never exit and never a sleep loop. An ended monitor is
# reported into the session and wakes it (#108); a sleep loop orphans its child
# holding the stdout pipe on TERM. exec leaves one process that TERM kills.
if [ -z "$agent" ]; then
    exec sleep 2147483647
fi

# --- credential ---------------------------------------------------------------
KEYFILE="$CONFIG_DIR/keys/${agent}.env"
if [ -r "$KEYFILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$KEYFILE"
    set +a
fi

# No key: park silently (#118). A missing key looks the same as an operator
# mid-opt-out, and the reader of this stdout is a woken Claude, not a person.
if [ -z "${AGENTBUS_API_KEY:-}" ]; then
    exec sleep 2147483647
fi

command -v agentbus >/dev/null 2>&1 || exec sleep 2147483647

export AGENTBUS_AGENT="$agent"

# --- stream -------------------------------------------------------------------
# The cursor file is PER SESSION: every session on one checkout is the same
# agent, and a shared state file let a headless `claude -p` reap the interactive
# session's monitor.
sid="${CLAUDE_CODE_SESSION_ID:-}"
if [ -n "$sid" ]; then
    STATE="$CONFIG_DIR/monitor-${agent}-${sid}.json"
else
    STATE="$CONFIG_DIR/monitor-${agent}.json"
fi

# REFUSE A SECOND LIVE WATCHER FOR THE SAME AGENT (container-registry incident,
# 2026-08-11): two watchers each fire every wake and hide mail from each other.
#
# Held means another SESSION's monitor (a state file carrying a session uuid
# that is not ours) or an omo session holding the agent's lock. A daemon or a
# foreground `agentbus watch` does not count: it wakes no session, and parking
# beside it would leave this session deaf.
#
# `agentbus watch-check` (client 0.9.108+, #100) reports both kinds. With --json,
# 0.9.109+ (#101) prints each holder's kind; 0.9.108 accepts the flag and prints
# text, so the output decides which rules apply. A client without watch-check
# falls back to the watch-status scan, which cannot see omo.
SESSION_LABEL='-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json\.pid'
KIND_OMO='"kind"[[:space:]]*:[[:space:]]*"omo"'
KIND_SESSION='"kind"[[:space:]]*:[[:space:]]*"session_monitor"'
held_by=""
omo_holder_line=""
if agentbus watch-check --help >/dev/null 2>&1; then
    if [ -n "$sid" ]; then
        check_out=$(agentbus watch-check --json --agent "$agent" --session "$sid" 2>/dev/null)
    else
        check_out=$(agentbus watch-check --json --agent "$agent" 2>/dev/null)
    fi
    check_status=$?
    check_json=0
    case "$check_out" in
        "{"*) printf '%s\n' "$check_out" | grep -q '"holders"' && check_json=1 ;;
    esac
    if [ "$check_status" -eq 4 ] && [ "$check_json" -eq 1 ]; then
        if printf '%s\n' "$check_out" | grep -qE -- "$KIND_OMO"; then
            held_by="omo"
            omo_path=$(printf '%s\n' "$check_out" | tr -d '\n' \
                | sed -n 's/.*"kind"[[:space:]]*:[[:space:]]*"omo"[^}]*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
            omo_holder_line="  holder: omo session [${omo_path:-lock path not reported}]"
        elif [ -n "$sid" ] && printf '%s\n' "$check_out" | grep -qE -- "$KIND_SESSION"; then
            held_by="session"
        fi
    elif [ "$check_status" -eq 4 ]; then
        if printf '%s\n' "$check_out" | grep -q '^  omo session'; then
            omo_holder_line=$(printf '%s\n' "$check_out" | sed -n 's/^  omo session/  holder: omo session/p')
            held_by="omo"
        elif [ -n "$sid" ] && printf '%s\n' "$check_out" | grep -qE -- "$SESSION_LABEL"; then
            held_by="session"
        fi
    fi
elif [ -n "$sid" ]; then
    other_status=$(agentbus watch-status --agent "$agent" 2>/dev/null || true)
    if printf '%s' "$other_status" | grep -qE -- "$SESSION_LABEL" \
        && ! printf '%s' "$other_status" | grep -q -- "-${sid}\.json\.pid"; then
        held_by="session"
    fi
fi

if [ "$held_by" = "session" ]; then
    echo "AgentBus monitor: another session is ALREADY watching agent '$agent'."
    echo "  Two live watchers on one identity duplicate every wake and share"
    echo "  read/ack state, so this monitor will NOT start a second one."
    echo "  If the other session has ended, its watcher will be reaped and"
    echo "  this monitor resumes on its next restart."
    echo "  Nothing here checked your mail: agentbus inbox --unread"
    exit 0
fi
if [ "$held_by" = "omo" ]; then
    echo "AgentBus monitor: an omo session already holds the stream for '$agent'."
    printf '%s\n' "${omo_holder_line:-  holder: omo session}"
    echo "  Two watchers on one identity duplicate every wake, so this monitor"
    echo "  will not start one. Use a git worktree for a second concurrent session."
    echo "  Nothing here checked your mail: agentbus inbox --unread"
    exec sleep 2147483647
fi

# Seed the cursor to the current end of the inbox, so backlog is not replayed as
# a flood of notifications. Backlog is the session-start hook's job. `--once`
# marks nothing read.
agentbus watch --agent "$agent" --state "$STATE" --once >/dev/null 2>&1 || true

# Kill the streamer when WE are killed, or it is orphaned holding an SSE
# subscription forever.
child=""
own_teardown=0
no_agent=0
cleanup() {
    own_teardown=1
    if [ "$no_agent" -eq 1 ]; then
        exit 0
    fi
    [ -n "$child" ] && kill "$child" 2>/dev/null
    # The trap cannot tell this session's reap from a stray pkill, so it always
    # says the wake path ended. Exit 0: a normal teardown is not an incident.
    echo "AgentBus monitor: stopped by a signal, so the wake path has ended."
    echo "  If this session is closing, that is expected. If it is NOT, something"
    echo "  outside this session killed the monitor (a stray pkill will do it) and"
    echo "  YOUR INBOX IS NO LONGER WATCHED."
    echo "  Nothing here checked your mail: agentbus inbox --unread"
    echo "  Re-arm with: agentbus watch --agent $agent"
    exit 0
}
trap cleanup INT TERM HUP

# Exit codes. 0 is reserved for a deliberate teardown.
EXIT_STREAM_ENDED=4     # the stream closed on its own
EXIT_STREAM_FAILED=5    # never stayed up; credential or connectivity
EXIT_STREAM_KILLED=6    # somebody else's SIGTERM
EXIT_DEAD_WAKE_SOCKET=7 # the session socket this watcher injects into is gone
EXIT_AUTH_REJECTED=8    # the key is revoked or invalid
EXIT_HELD_BY_OMO=9      # an omo session holds this agent's lock (client #100)

# MID-TURN DELIVERY through Claude Code's inbox socket, read between tool calls.
# Every flag is FEATURE-DETECTED: an older client exits non-zero on an unknown
# flag, and since `watch` prints nothing when --exec is given, a failing --exec
# would silently kill the wake path.
INJECT=""
if [ -n "${CLAUDE_CODE_MESSAGING_SOCKET:-}" ] \
   && agentbus-hook inject --help >/dev/null 2>&1; then
    INJECT="agentbus-hook inject --sender {sender} --subject {subject} --delivery {delivery_id} --seq {agent_seq}"
    inject_help=$(agentbus-hook inject --help 2>&1)
    # --direction: say truthfully whether a message is from this workspace.
    if printf '%s' "$inject_help" | grep -q -- --direction; then
        INJECT="$INJECT --direction {direction}"
    fi
    # --inbound-source: separate SMTP from a signed inbound HTTPS hook.
    if printf '%s' "$inject_help" | grep -q -- --inbound-source; then
        INJECT="$INJECT --inbound-source {inbound_source}"
    fi
    # --signature-state: the per-message signature verdict (0.9.97+).
    if printf '%s' "$inject_help" | grep -q -- --signature-state; then
        INJECT="$INJECT --signature-state {signature_state}"
    fi
fi

# THE RETRY BUDGET IS A STARTUP GUARD: five consecutive failures that never
# stayed up 60s. A stream that ran a while and then died resets it.
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
    # A clean exit is the END of the wake path, not an empty inbox.
    if [ "$status" -eq 0 ]; then
        echo "AgentBus monitor: the stream ENDED (exit 0). This is the end of the wake"
        echo "  path, NOT a report that your inbox is empty — nothing was checked."
        echo "  Unread mail may be waiting: agentbus inbox --unread"
        echo "  Re-arm with: agentbus watch --agent $agent"
        exit "$EXIT_STREAM_ENDED"
    fi
    # 143 here means something OTHER than this session's teardown killed the
    # streamer (a real teardown runs `cleanup` first). Transient: retry (SPECS/0020).
    if [ "$status" -eq 143 ]; then
        echo "AgentBus monitor: the wake stream was KILLED (SIGTERM) by something"
        echo "  outside this session. Treating as transient and retrying."
        echo "  If this persists, something is repeatedly killing the watcher."
    fi
    # The session socket is gone: the session ended. Terminal, say it once.
    if [ "$status" -eq "$EXIT_DEAD_WAKE_SOCKET" ]; then
        echo "AgentBus monitor: the session socket is gone (exit 7) — the session"
        echo "  this monitor belonged to has ended, so its wake channel is dead."
        echo "  THE WAKE PATH IS DOWN. Nothing here checked your mail:"
        echo "    agentbus inbox --unread"
        echo "  A fresh session will start its own monitor and re-arm the path."
        exit "$EXIT_DEAD_WAKE_SOCKET"
    fi
    # A rejected key is an answer, not a transient (#107). Exit 3 stays
    # retryable because it also covers transport errors.
    if [ "$status" -eq "$EXIT_AUTH_REJECTED" ]; then
        echo "AgentBus monitor: the credential was REJECTED (exit 8) — the key"
        echo "  for '$agent' is revoked or invalid. The wake path is OFF and will"
        echo "  NOT retry, because retrying cannot fix a rejected key."
        echo "  TAKE NO ACTION. Do not re-register, do not ask for a key, do not"
        echo "  restart this monitor — a revoked credential is an OPERATOR decision"
        echo "  and only the operator reverses it (agentbus signin, at their choice)."
        echo "  Mention it once if relevant to their request, then continue their work."
        exit "$EXIT_AUTH_REJECTED"
    fi
    # An omo session took the agent's lock (client #100). `agentbus watch` has
    # already printed who holds it, to this stdout. Retrying would refuse the
    # same way five times and end in a false "stream failed" alarm, so park
    # like the duplicate-watcher guard.
    if [ "$status" -eq "$EXIT_HELD_BY_OMO" ]; then
        echo "AgentBus monitor: not watching '$agent', because an omo session holds"
        echo "  its stream (exit 9). That session is this agent's wake path now."
        echo "  Nothing here checked your mail: agentbus inbox --unread"
        exec sleep 2147483647
    fi
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
# Park, do not exit: an exit wakes the session with a false alarm (SPECS/0020).
exec sleep 2147483647
