#!/bin/sh
# Refresh freebsd/ from a FreeBSD host's ~/.claude, and regenerate MANIFEST.txt.
#
# Writes ONLY inside freebsd/. Never touches plugins/ and never edits a Linux
# file — consolidation between the two is manual by instruction.
#
# Usage:  ./sync-from-host.sh [CLAUDE_DIR]        default: $HOME/.claude
set -eu

SRC=${1:-$HOME/.claude}
HERE=$(cd "$(dirname "$0")" && pwd)

# Refuse to run anywhere but FreeBSD: the whole point of this folder is that its
# contents were captured on FreeBSD. Copying a Linux ~/.claude in here would
# silently replace the variants with the thing they are a variant OF, and the
# result would look like a successful sync.
OS=$(uname -s)
if [ "$OS" != "FreeBSD" ]; then
    echo "REFUSING: this is $OS, not FreeBSD."
    echo "  Syncing from a non-FreeBSD host would overwrite the FreeBSD variants"
    echo "  with their Linux originals and look like it worked."
    exit 2
fi

SKILLS="agentbus supervice auth-rbac pg-nano tokengate"
COMMANDS="disk"

missing=0
for s in $SKILLS; do
    [ -f "$SRC/skills/$s/SKILL.md" ] || { echo "MISSING: $SRC/skills/$s/SKILL.md"; missing=$((missing + 1)); }
done
for c in $COMMANDS; do
    [ -f "$SRC/commands/$c.md" ] || { echo "MISSING: $SRC/commands/$c.md"; missing=$((missing + 1)); }
done
if [ "$missing" -ne 0 ]; then
    echo "REFUSING: $missing source file(s) absent under $SRC — nothing copied."
    echo "  A partial sync would drop files from this folder without saying so."
    exit 2
fi

for s in $SKILLS; do
    mkdir -p "$HERE/skills/$s"
    cp "$SRC/skills/$s/SKILL.md" "$HERE/skills/$s/SKILL.md"
done
for c in $COMMANDS; do
    mkdir -p "$HERE/commands"
    cp "$SRC/commands/$c.md" "$HERE/commands/$c.md"
done

{
    echo "# FreeBSD variants — captured from a host, not built here."
    echo "# host   : $(hostname)"
    echo "# uname  : $(uname -sr) $(uname -m)"
    echo "# source : $SRC"
    echo "#"
    echo "# Timestamps are deliberately absent: this file should only change when a"
    echo "# FILE changes, so a no-op sync produces an empty git diff."
    echo ""
    find "$HERE/skills" "$HERE/commands" -type f -name '*.md' | sort | while read -r f; do
        printf '%s  %s\n' "$(sha256 -q "$f")" "${f#"$HERE"/}"
    done
} > "$HERE/MANIFEST.txt"

echo "synced $(find "$HERE/skills" "$HERE/commands" -type f -name '*.md' | wc -l | tr -d ' ') file(s) into ${HERE##*/}/"

# Report drift against any upstream counterpart that exists in this repo. This
# does not resolve it — consolidation is manual — it just refuses to let the
# divergence stay invisible.
UP="$HERE/../plugins/agentbus/skills/agentbus/SKILL.md"
if [ -f "$UP" ]; then
    if cmp -s "$UP" "$HERE/skills/agentbus/SKILL.md"; then
        echo "drift: agentbus SKILL.md identical to upstream"
    else
        only_up=$(diff "$HERE/skills/agentbus/SKILL.md" "$UP" | grep -c '^>' || true)
        only_fb=$(diff "$HERE/skills/agentbus/SKILL.md" "$UP" | grep -c '^<' || true)
        echo "drift: agentbus SKILL.md differs from upstream — $only_up line(s) only upstream, $only_fb only here"
        echo "       lines only upstream are usually BASE drift, not a FreeBSD decision."
        echo "       Consolidate by re-applying FreeBSD changes onto the current upstream file."
    fi
fi
