#!/bin/sh
# WHERE THE MONITOR IS ALLOWED TO GET AN IDENTITY, and where it is not.
#
# Supersedes probe_monitor_default_fallback.sh, which asserted the opposite of
# the rule below. That probe encoded the 0.6.4 design: an unwired directory on a
# signed-in machine ATTACHED to the machine's `default_agent` and announced whose
# mail it was reading. It was written to stop a real failure (david's monitor
# parking silently with no watcher) and it did — by making a cross-agent mail
# leak legible instead of making it impossible.
#
# The operator's directive on 2026-08-13 settles it (issuedb #95):
#
#     AGENTBUS_AGENT IS THE KILL SWITCH. A session with no declared identity gets
#     no AgentBus at all — no watcher, no output, no network call, no advice.
#
# What actually went wrong, and why "visible but wrong" was not good enough: in a
# session that had deliberately not opted in, the monitor announced that the repo
# was unwired and told the reader to run `agentbus setup claude`. The reader was
# an assistant, which cannot distinguish its own tooling's diagnostics from an
# instruction — so it ran setup, adopted an identity, and dumped 242 unread
# messages into an unrelated task. A tool that recommends its own activation is
# not neutral.
#
# david's case is answered by DECLARING identity per checkout (.agentbus/agent)
# rather than by inheriting it from the machine. Explicit beats inherited: it
# survives a reopened session, works in every harness, and cannot attach one
# project to another project's inbox.
#
# THE POSITIVE CASES RUN FIRST AND THEIR FAILURE IS FATAL. Every "must be silent"
# assertion here is meaningless unless this harness can observe output at all — a
# monitor that crashed on line 1 would pass all of them.
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
MON="${1:-$REPO/marketplace/plugins/agentbus/scripts/agentbus-monitor.sh}"
MON="$(cd "$(dirname "$MON")" && pwd)/$(basename "$MON")"
WORK="${TMPDIR:-/tmp}/probe-monitor-identity.$$"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  [PASS] %s\n         %s\n' "$1" "$2"; }
bad()  { fail=$((fail+1)); printf '  [FAIL] %s\n         %s\n' "$1" "$2"; }

# run <name> <default_agent|-> <worktree_agent|-> <settings_agent|-> [env_agent]
run() {
    name="$1"; default_agent="$2"; worktree="$3"; settings="$4"; envagent="${5:-}"
    dir="$WORK/$name"; cfg="$WORK/$name-cfg"
    mkdir -p "$dir/.agentbus" "$cfg/keys"
    ( cd "$dir" && git init -q . 2>/dev/null )
    if [ "$default_agent" = "-" ]; then
        printf '{"default_agent": null}\n' > "$cfg/signin.json"
    else
        printf '{"default_agent": "%s"}\n' "$default_agent" > "$cfg/signin.json"
    fi
    [ "$worktree" != "-" ] && printf '%s\n' "$worktree" > "$dir/.agentbus/agent"
    if [ "$settings" != "-" ]; then
        mkdir -p "$dir/.claude"
        printf '{"env": {"AGENTBUS_AGENT": "%s"}}\n' "$settings" > "$dir/.claude/settings.local.json"
    fi
    if [ -n "$envagent" ]; then
        ( cd "$dir" && env AGENTBUS_AGENT="$envagent" AGENTBUS_CONFIG_DIR="$cfg" \
            CLAUDE_CODE_MESSAGING_SOCKET= timeout 10 sh "$MON" ) 2>&1
    else
        ( cd "$dir" && env -u AGENTBUS_AGENT AGENTBUS_CONFIG_DIR="$cfg" \
            CLAUDE_CODE_MESSAGING_SOCKET= timeout 10 sh "$MON" ) 2>&1
    fi
}

echo "=== SOURCES THAT MUST ACTIVATE (positive controls — run first) ==="

out=$(run env_only - - - "env-agent")
case "$out" in *env-agent*) ok "\$AGENTBUS_AGENT activates" "the operator's word for this session" ;;
  *) bad "\$AGENTBUS_AGENT activates" "declared in the environment and nothing happened; every silence case below is now unverifiable" ;;
esac

out=$(run worktree_only - wt-agent -)
case "$out" in *wt-agent*) ok ".agentbus/agent activates" "the worktree's own declaration" ;;
  *) bad ".agentbus/agent activates" "the per-checkout identity file was ignored" ;;
esac

out=$(run legacy_only - - legacy-agent)
case "$out" in *legacy-agent*) ok ".claude/settings.local.json activates (legacy)" "projects wired before .agentbus/agent keep working" ;;
  *) bad ".claude/settings.local.json activates (legacy)" "an upgrade just deafened an already-wired project" ;;
esac

echo
echo "=== PRECEDENCE (#90: the hooks and the monitor must never disagree) ==="

out=$(run env_beats_wt - wt-agent - "env-agent")
case "$out" in *env-agent*) ok "env outranks .agentbus/agent" "matches hooks/claude_code.py _resolve_agent" ;;
  *) bad "env outranks .agentbus/agent" "the file beat the operator's export — two identities in one session" ;;
esac

out=$(run wt_beats_legacy - wt-agent legacy-agent)
case "$out" in *wt-agent*) ok ".agentbus/agent outranks settings.local.json" "the harness-neutral record wins" ;;
  *) bad ".agentbus/agent outranks settings.local.json" "precedence differs from the hooks" ;;
esac

echo
echo "=== THE SOURCE THAT MUST NEVER ACTIVATE ==="

out=$(run default_ignored someone-else - -)
if [ -z "$out" ]; then
    ok "machine default_agent is NOT adopted" "unwired directory stayed silent (the positives above prove output is observable)"
else
    bad "machine default_agent is NOT adopted" "cross-agent leak: $(printf '%s' "$out" | head -1)"
fi

echo
echo "=== NO DECLARATION ANYWHERE -> THE BUS IS OFF ==="

out=$(run nothing_declared - - -)
if [ -z "$out" ]; then
    ok "silent with no declared identity" "no output, no watcher, no advice to run setup"
else
    bad "silent with no declared identity" "spoke in a project that never opted in: $(printf '%s' "$out" | head -1)"
fi

rm -rf "$WORK"
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
