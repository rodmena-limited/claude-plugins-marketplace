#!/usr/bin/env bash
# #91 V1/V2: a SIGTERM to the STREAMER must be loud; a SIGTERM to the SCRIPT
# must stay quiet. Asserts on the OBSERVED exit code and captured stdout of a
# real run, never on reading the branch.
MON="${1:?usage: test_monitor_sigterm.sh /path/to/agentbus-monitor.sh}"
export AGENTBUS_AGENT="sigterm-probe-$$"
export AGENTBUS_API_KEY="${AGENTBUS_API_KEY:?need a key so the stream actually comes up}"
export CLAUDE_CODE_MESSAGING_SOCKET=""
# The stream cannot come up for an agent that does not exist, and then there is
# no child to kill and nothing below means anything. Register it first.
agentbus register "$AGENTBUS_AGENT" --ephemeral --unlisted >/dev/null 2>&1 \
  || { echo "could not register $AGENTBUS_AGENT — refusing to report a result"; exit 2; }
pass=0; fail=0
say() { if [ "$1" = ok ]; then pass=$((pass+1)); echo "  [PASS] $2"; else fail=$((fail+1)); echo "  [FAIL] $2"; fi; echo "         $3"; }

# ---------------------------------------------------------------- V1
# Foreign kill: signal ONLY the streamer child, leaving the script untouched.
echo "=== V1: someone else kills the streamer -> must PRINT and exit NON-ZERO ==="
out1=$(mktemp)
sh "$MON" > "$out1" 2>/dev/null &
mon=$!
sleep 15                       # let the stream attach
child=$(pgrep -P "$mon" -f "watch --agent" | head -1)
[ -z "$child" ] && child=$(pgrep -f "watch --agent $AGENTBUS_AGENT" | head -1)
if [ -z "$child" ]; then
  say fail "streamer child found" "no child to kill — the harness never got the stream up, so nothing below is evidence"
  kill "$mon" 2>/dev/null; exit 1
fi
say ok "streamer child found (pid $child)" "known-positive: there is something to kill"
kill -TERM "$child" 2>/dev/null
wait "$mon"; rc1=$?
said1=$(wc -c < "$out1")
[ "$rc1" -ne 0 ] && say ok "exit is NON-ZERO on a foreign kill" "exit $rc1" \
                 || say fail "exit is NON-ZERO on a foreign kill" "exit $rc1 — indistinguishable from a clean reap, which is the bug"
[ "$said1" -gt 0 ] && say ok "it PRINTS on a foreign kill" "$said1 bytes on stdout" \
                   || say fail "it PRINTS on a foreign kill" "silent — the harness reports 'ended without output' and the reader concludes no mail arrived"
grep -qi "inbox" "$out1" && say ok "names the inbox risk" "output warns mail may be waiting" \
                         || say fail "names the inbox risk" "output does not say the inbox went unchecked"

# ---------------------------------------------------------------- V2
# Real reap: signal the SCRIPT, as SessionEnd does.
echo
echo "=== V2: a TERM to the SCRIPT -> exit 0, but it must SAY SOMETHING ==="
# This assertion was BACKWARDS until david asked the converse question. It used
# to demand SILENCE here, which meant it could never go red on the case that
# matters: `pkill -f agentbus` signals the SCRIPT, fires the same trap, and was
# equally silent. A test that asserts the defect is correct is worse than no
# test. The trap cannot tell a reap from a foreign kill, so the requirement is
# now: exit 0 (a normal teardown is not an incident) but NEVER exit 0 in
# silence.
out2=$(mktemp)
sh "$MON" > "$out2" 2>/dev/null &
mon2=$!
sleep 12
kill -TERM "$mon2" 2>/dev/null
wait "$mon2"; rc2=$?
# grep -c prints 0 AND exits 1 on no-match, so `|| echo 0` appended a second
# zero and the arithmetic test blew up. Use grep -q and a plain flag.
bytes2=$(wc -c < "$out2")
[ "$rc2" -eq 0 ] && say ok "a real reap exits 0" "exit $rc2" \
                 || say fail "a real reap exits 0" "exit $rc2 — a normal session end must not look like an incident"
[ "$bytes2" -gt 0 ] && say ok "a TERM to the script is NOT silent" "$bytes2 bytes on stdout" \
                     || say fail "a TERM to the script is NOT silent" "exit 0 with nothing said — a harness reads that as 'no messages arrived', which is the whole defect"
grep -qi "inbox" "$out2" && say ok "...and names the inbox risk" "warns the inbox is no longer watched" \
                         || say fail "...and names the inbox risk" "says nothing about unchecked mail"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
