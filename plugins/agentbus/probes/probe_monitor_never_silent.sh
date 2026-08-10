#!/usr/bin/env bash
# THE ONE INVARIANT: the monitor must never exit 0 having said nothing.
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
run_case "new project, not signed in, not a git repo" \
    HOME="$(mktemp -d)" AGENTBUS_AGENT= AGENTBUS_API_KEY=

# 2. Signed in on the machine, but this project is not wired.
tmpcfg=$(mktemp -d); mkdir -p "$tmpcfg/keys"
run_case "signed in, project not wired" \
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
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
