# FreeBSD skill and command variants

House skills and commands adapted for FreeBSD, kept **separate from the Linux
originals on purpose**. Consolidation between the two is **manual and deliberate**
— nothing here merges, overwrites, or is merged automatically.

Origin: `rodmena-vm-2` (FreeBSD 15.1-RELEASE-p2, ZFS root), `~/.claude/`.

## Why this folder is outside `plugins/`

`.claude-plugin/marketplace.json` lists plugins **explicitly** (`"source":
"./plugins/agentbus"`) rather than globbing directories. A top-level `freebsd/`
folder is therefore **inert to the plugin loader**: it cannot be installed,
cannot shadow a Linux skill, and cannot be picked up by a client that syncs the
marketplace. That is the point — these files are a reference copy, not a second
distribution channel.

If that manifest ever starts globbing, this folder must move or be excluded.

## What differs from the Linux versions

Verified on the host, not assumed:

| Linux | FreeBSD |
|---|---|
| `/run` | `/var/run` |
| `XDG_RUNTIME_DIR` set | unset |
| `systemd` / `systemctl` / `journalctl` | `rc.d` + `daemon(8)`; no journal |
| `apt` | `pkg` |
| bare `python3` | **absent** — `python3.12` only |
| `docker` | absent |
| disk reporting assumes ext4/LVM | ZFS-aware (`zfs list`, datasets, snapshots) |

Two of these are load-bearing enough to have their own tickets:

- **agentbus #153** — `agentbus service` emits a **systemd** unit and **exits 0**
  on a host with neither systemd nor launchd. Silent failure: a unit file nothing
  loads, no watcher, and a success exit code saying otherwise.
- **agentbus #117** — `doctor`'s monitor detection is blind on FreeBSD because
  `ps -eo` lists only gettys.

Both are the same shape: a check that returns a pass-shaped result on a platform
it cannot actually inspect.

## Known drift — read before consolidating

`skills/agentbus/SKILL.md` is **behind** `plugins/agentbus/skills/agentbus/SKILL.md`
by 17 lines. The FreeBSD copy predates the agent-tags work (plugin 0.6.24) and has
no `bus_tag`, no `label=` on `bus_phonebook`, and no tags section.

That is drift in the **base**, not a FreeBSD adaptation. Do not read the absence
of those lines as a platform decision. When consolidating, start from the current
upstream file and re-apply the FreeBSD changes to it, rather than diffing this
copy forward.

The other five files have no upstream counterpart in this repo, so their Linux
originals live wherever the host's `~/.claude/skills` is populated from — which is
**not** this repository, and is not automated on `rodmena-vm-2`: there is no cron
entry, no clone, and `~/.claude/skills` is not a git checkout. Whoever consolidates
needs to know that; the "hourly sync" this folder was created to survive was not
found on the host it supposedly overwrites.

## Files

See `MANIFEST.txt` for sha256 of each file as captured. Regenerate with
`./sync-from-host.sh` on a FreeBSD box.

## Consolidation is manual, and that is the design

There is no tooling here that merges FreeBSD and Linux, by instruction. When a
Linux skill changes, someone decides whether the FreeBSD copy needs the same
change and applies it by hand. `sync-from-host.sh` only refreshes this folder
**from a host**; it never writes to `plugins/`, and it never edits a Linux file.
