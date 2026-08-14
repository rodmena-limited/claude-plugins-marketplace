---
description: Report disk footprint — filesystem, ~/.claude, ZFS/jails, logs — and what is genuinely reclaimable
argument-hint: "[--claude | --zfs | --all]"
allowed-tools: Bash(df:*), Bash(du:*), Bash(zfs:*), Bash(zpool:*), Bash(ls:*), Bash(find:*), Bash(docker:*), Read
---

Report what is actually consuming disk on this machine. Disk — not memory — is
the real constraint on this box; memory only looks bad because of ARC/page
cache. **This host is FreeBSD** — there is no `docker` and no `journalctl`
here (both verified absent), so do not run them or report their absence as a
finding.

Gather:

```bash
df -h /                                          # headline: used / avail / %
du -sh ~/.claude ~/.claude/* | sort -rh | head -15   # sort -rh works on FreeBSD
zfs list -o name,used,refer,avail -s used 2>/dev/null | tail -20  # if ZFS
zpool list 2>/dev/null                           # pool-level free vs allocated
zfs list -t snapshot -o name,used -s used 2>/dev/null | tail -20  # snapshots
du -sh /var/log /var/cache/pkg /usr/local 2>/dev/null | sort -rh
```

On ZFS, `df` lies about reclaimable space: deleting a file frees nothing while
a snapshot still references it. Always check `zfs list -t snapshot` before
claiming anything is recoverable, and report snapshot-held space separately
from genuinely free-able space.

For `~/.claude`, note that `cleanupPeriodDays` is set to 30, so `projects/` and
`transcripts/` prune themselves on that horizon — report their size but do not
propose deleting them by hand.

Then report in three groups, and keep them strictly separate:

1. **Genuinely reclaimable now** — the pkg cache (`pkg clean -a`), rotated logs
   under `/var/log`, stale distfiles, obsolete boot environments
   (`bectl list`). Give the command and the number of bytes it frees.
2. **Reclaimable but load-bearing** — ZFS snapshots and boot environments that
   look stale but are the rollback path, and datasets backing a running jail or
   service. Name what would break. Never propose `zfs destroy` on a snapshot
   without first checking for clones/holds (`zfs holds`, `zfs get clones`) — a
   snapshot with a dependent clone cannot be destroyed without taking the clone
   with it.
3. **Not worth touching** — things whose size is real but whose deletion buys
   little or costs history.

Rules:

- **Do not delete anything without showing the list first and getting a yes.**
  Report the footprint; let Farshid choose what goes.
- `pkg clean -a` (cache only, safe) and `zfs destroy` (irreversible data loss)
  are not interchangeable. Say which one you mean, and never reach for
  `zfs destroy` as a space-saving default — especially not with `-r`/`-R`,
  which take descendant datasets and dependent clones with them.
- Freeing space on ZFS is not the same as deleting files: space held by a
  snapshot returns only when the snapshot goes. Report the two separately
  rather than summing them into one "reclaimable" number.
- If disk is above 85%, lead with that and say how long until it bites.
