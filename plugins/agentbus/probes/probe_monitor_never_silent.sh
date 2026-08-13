#!/usr/bin/env bash
# TWO INVARIANTS, and which applies depends on whether the project HAS AN AGENT.
#
#   HAS an agent  -> must never end silently. "Monitor ended without producing
#                    output (exit 0)" is read as "no mail arrived", so silence
#                    there is a dead wake wearing the costume of an empty inbox.
#   NO agent      -> must emit NOTHING AT ALL, and must not end. An unwired
#                    directory has no inbox, so there is nothing to miss; and a
#                    monitor that explains itself in every unrelated repo gets
#                    uninstalled, which removes the wake everywhere including
#                    where it mattered. Neither exiting quietly nor exiting
#                    loudly is silent — the harness announces the exit either way
#                    — so the only way to emit nothing is to stay idle.
#
# The second rule REVERSES what this probe asserted on 2026-08-09, when it
# demanded output from an unwired directory. That assertion was not a bug in the
# probe; the rule it encoded was wrong, and the operator said so: a customer in a
# new repo wants nothing.
#
# "Monitor ended without producing output (exit 0)" is read by a session as "no
# peer messages arrived", so a silent exit turns every unwatched inbox into a
# confident all-clear. That defect has now been fixed in FOUR separate places —
# clean stream end (0.5.4), foreign kill of the streamer (0.5.6), the signal trap
# (0.5.7), and the no-agent first-run path — each time in a spot the previous fix
# did not cover.
#
# So this stops testing one path and tests the PROPERTY, across every startup
# state a real user can land in. No credential needed: every case here fails
# before the stream is reached.
MON="${1:?usage: probe_monitor_never_silent.sh /path/to/agentbus-monitor.sh}"
# ABSOLUTE, because each case runs from a throwaway cwd. A relative path silently
# stops resolving there and `sh` exits 2 having printed nothing — which this
# probe would then report as the product exiting silently. It did exactly that on
# its first run and briefly looked like the fix had broken the monitor.
MON="$(cd "$(dirname "$MON")" && pwd)/$(basename "$MON")"
pass=0; fail=0
say() { if [ "$1" = ok ]; then pass=$((pass+1)); printf '  [PASS] %s\n         %s\n' "$2" "$3"
        else fail=$((fail+1)); printf '  [FAIL] %s\n         %s\n' "$2" "$3"; fi; }

# For an UNWIRED project: assert TOTAL SILENCE, and that it EXITS rather than
# idling.
#
# THE EXIT ASSERTION REVERSED ON 2026-08-13, and the reversal is the point of the
# kill switch. This probe used to demand rc=124 — proof the monitor stayed alive
# — because an exit made the harness announce "stream ended", and that
# announcement was itself noise. Two things changed:
#
#   * #91 made the pending hook recognise and no-op harness task-notifications,
#     so the exit announcement no longer reaches or blocks a session;
#   * holding a process open for the entire session in every unwired directory
#     on the machine is a real cost paid for nothing. There is no inbox, no
#     credential and no stream — there is nothing for it to stay alive FOR.
#
# So the rule is now the simplest one available: no identity, no AgentBus. Emit
# nothing, do nothing, exit 0 immediately.
run_quiet_case() {
    name="$1"; shift
    out=$(mktemp); tmphome=$(mktemp -d)
    ( cd "$tmphome" && env "$@" CLAUDE_CODE_MESSAGING_SOCKET= \
        timeout 8 sh "$MON" ) > "$out" 2>/dev/null
    rc=$?
    bytes=$(wc -c < "$out")
    if [ "$bytes" -ne 0 ]; then
        say fail "$name (must be SILENT)" "emitted ${bytes}B — a project that never opted in wants nothing: $(head -1 "$out")"
    elif [ "$rc" -eq 124 ]; then
        say fail "$name (must be SILENT)" "still running after 8s — an unwired directory must not hold a process open for the session"
    elif [ "$rc" -ne 0 ]; then
        say fail "$name (must be SILENT)" "exited rc=$rc; 'not wired' is a normal state and must exit 0"
    else
        say ok "$name (must be SILENT)" "no output, exit 0: the bus is off in this directory"
    fi
    rm -rf "$tmphome"; rm -f "$out"
}

# Each case: a name, and an env that drives the monitor down one startup path.
run_case() {
    name="$1"; shift
    out=$(mktemp); tmphome=$(mktemp -d)
    ( cd "$tmphome" && env "$@" \
        CLAUDE_CODE_MESSAGING_SOCKET= \
        sh "$MON" ) > "$out" 2>/dev/null
    rc=$?
    bytes=$(wc -c < "$out")
    if [ "$rc" -eq 0 ] && [ "$bytes" -eq 0 ]; then
        say fail "$name" "EXIT 0 WITH NO OUTPUT — a session reads this as 'no messages arrived'"
    elif [ "$bytes" -eq 0 ]; then
        say fail "$name" "silent (exit $rc); stderr is discarded by the harness, so this reaches nobody"
    else
        first=$(head -1 "$out")
        say ok "$name" "exit $rc, ${bytes}B: ${first:0:72}"
    fi
    rm -rf "$tmphome"; rm -f "$out"
}

echo "=== every startup state must SAY something ==="

# 1. Brand-new project: no agent, machine not signed in, not a git repo.
#    This is the case the operator hit, and it was totally silent.
run_quiet_case "new project, not signed in, not a git repo" \
    HOME="$(mktemp -d)" AGENTBUS_AGENT= AGENTBUS_API_KEY=

# 2. Signed in on the machine, but this project is not wired.
tmpcfg=$(mktemp -d); mkdir -p "$tmpcfg/keys"
run_quiet_case "signed in, project not wired" \
    HOME="$tmpcfg" AGENTBUS_CONFIG_DIR="$tmpcfg" AGENTBUS_AGENT= AGENTBUS_API_KEY=

# 3. An agent is named but no credential exists for it.
run_case "agent named, no credential" \
    HOME="$(mktemp -d)" AGENTBUS_AGENT=probe-no-cred AGENTBUS_API_KEY=

# 4. THE CROSS-AGENT LEAK (bob, 2026-08-10). An unwired directory on a machine
#    whose signin.json names a default_agent must NOT attach to that agent's
#    inbox. It did: a scratch dir started streaming david's mail and reached
#    cursor 474. Invisible on the dev host, whose default_agent is null.
echo
echo "=== an unwired directory must NOT adopt the machine's default_agent ==="
leakhome=$(mktemp -d); mkdir -p "$leakhome/.config/agentbus"
printf '{"default_agent": "someone-else"}\n' > "$leakhome/.config/agentbus/signin.json"
leakout=$(mktemp); leakdir=$(mktemp -d)
( cd "$leakdir" && env HOME="$leakhome" AGENTBUS_CONFIG_DIR="$leakhome/.config/agentbus" \
    AGENTBUS_AGENT= AGENTBUS_API_KEY= CLAUDE_CODE_MESSAGING_SOCKET= \
    timeout 20 sh "$MON" ) > "$leakout" 2>/dev/null
if grep -q "someone-else" "$leakout"; then
    say fail "unwired dir does not adopt the machine default_agent" \
        "ADOPTED 'someone-else' — this is the cross-agent leak: a watcher attaching to another agent's inbox"
else
    say ok "unwired dir does not adopt the machine default_agent" \
        "refused to guess an identity; took the no-agent path"
fi
rm -rf "$leakhome" "$leakdir"; rm -f "$leakout"

echo
echo "=== the kill switch, both directions ==="

# THE POSITIVE CONTROL COMES FIRST, DELIBERATELY. Every silence assertion above
# is worthless unless this monitor is capable of speaking in the first place —
# a script that exits 1 on line 3 passes every "must be SILENT" case perfectly.
kshome=$(mktemp -d); mkdir -p "$kshome/.config/agentbus/keys"
ksdir=$(mktemp -d); ( cd "$ksdir" && git init -q . )

mkdir -p "$ksdir/.agentbus"; printf 'worktree-probe-agent\n' > "$ksdir/.agentbus/agent"
ksout=$( cd "$ksdir" && env HOME="$kshome" AGENTBUS_CONFIG_DIR="$kshome/.config/agentbus" \
    AGENTBUS_AGENT= AGENTBUS_API_KEY= CLAUDE_CODE_MESSAGING_SOCKET= \
    timeout 15 sh "$MON" 2>/dev/null )
if printf '%s' "$ksout" | grep -q "worktree-probe-agent"; then
    say ok "ON: .agentbus/agent activates the bus" \
        "resolved the worktree's declared identity and proceeded"
else
    say fail "ON: .agentbus/agent activates the bus" \
        "declared an identity and the monitor still did nothing — the switch is stuck OFF, which would make every silence assertion above vacuous"
fi

# The env var must beat the file, or the hooks and the monitor can disagree (#90).
ksout=$( cd "$ksdir" && env HOME="$kshome" AGENTBUS_CONFIG_DIR="$kshome/.config/agentbus" \
    AGENTBUS_AGENT=env-probe-agent AGENTBUS_API_KEY= CLAUDE_CODE_MESSAGING_SOCKET= \
    timeout 15 sh "$MON" 2>/dev/null )
if printf '%s' "$ksout" | grep -q "env-probe-agent"; then
    say ok "PRECEDENCE: \$AGENTBUS_AGENT outranks .agentbus/agent" \
        "env won, matching the hooks' resolution order"
else
    say fail "PRECEDENCE: \$AGENTBUS_AGENT outranks .agentbus/agent" \
        "the file overrode the operator's env export — this is #90, two identities in one session"
fi

# And OFF: remove the declaration, same directory, same machine.
rm -rf "$ksdir/.agentbus"
ksout=$( cd "$ksdir" && env HOME="$kshome" AGENTBUS_CONFIG_DIR="$kshome/.config/agentbus" \
    AGENTBUS_AGENT= AGENTBUS_API_KEY= CLAUDE_CODE_MESSAGING_SOCKET= \
    timeout 15 sh "$MON" 2>/dev/null )
if [ -z "$ksout" ]; then
    say ok "OFF: removing the identity silences the bus" \
        "same repo, same machine, no declaration: nothing emitted"
else
    say fail "OFF: removing the identity silences the bus" \
        "still spoke without any declared identity: $(printf '%s' "$ksout" | head -1)"
fi
rm -rf "$kshome" "$ksdir"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
