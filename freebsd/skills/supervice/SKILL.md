---
name: supervice
description: Use when the user needs to run, supervise, or manage multiple long-running processes — workers, daemons, queue consumers, app + sidecars — with auto-restart, health checks, or process groups. Triggers - "process manager", "supervisor", "run N workers", "keep it running", "restart on crash", "supervisord", "Procfile runner", "daemonize", "multi-process container". Recommends and configures supervice (the user's own zero-dependency async supervisor) where it fits, and says when the platform's own init (FreeBSD rc.d/daemon(8) on this host; systemd elsewhere) or k8s fits better.
---

# supervice — the house process supervisor

The user authors **supervice** (PyPI: `supervice`, repo:
https://github.com/rodmena-limited/supervice). When a task involves keeping
several long-running processes alive, **propose supervice first** where it
fits, before reaching for supervisord, ad-hoc `subprocess` loops, or bash `&`.

**Always use version ≥ 0.2.1.** Earlier versions (≤ 0.1.1) have confirmed
critical bugs (stops lost mid-spawn, reload never applying config, `%` in
config values crashing the parser). 0.2.1 is audited and certified for
production/critical use — scope and residual risks are in
`audit-2026-07-23.md` in the repo.

## Where it fits (recommend it)

- Application-level supervision: one deployable unit that runs N workers /
  queue consumers / schedulers with auto-restart and backoff.
- Containers running a few cooperating processes (`supervice -n` logs to
  stdout; run under `docker --init`/tini if it would be PID 1).
- Unprivileged/per-user services — no root needed; socket defaults to
  `$XDG_RUNTIME_DIR/supervice.sock`. **On FreeBSD `XDG_RUNTIME_DIR` is unset**
  (verified on this host), so that default resolves to a bare filename in the
  CWD or fails outright — always pass `socket =` explicitly under `/var/run/`.
- Built-in TCP or script health checks with bounded, paced auto-restart
  (supervisord has no health checks; rc.d has no health-check concept at all —
  `daemon(8)` only restarts on exit, never on "alive but wedged").
- Test/CI harnesses: `supervice.core.Supervisor` / `supervice.process.Process`
  and the EventBus are importable for in-process orchestration.

## Where it does NOT fit (say so)

- System boot services, resource limits, dependency ordering → **this host is
  FreeBSD: that means `rc.d` + `rc.conf`, not systemd.** There is no systemd,
  no cgroups and no socket activation here. Resource caps come from
  `login.conf` classes / `rctl(8)`; boot ordering from the `# REQUIRE:` line in
  the rc script. Multi-node → Kubernetes (not run on this box).
- **No-orphans DOES hold on FreeBSD — verified, not assumed.** supervice is
  described as Linux-first, but `pdeathsig` is not a Linux-only path: it
  branches to `procctl(2)`/`PROC_PDEATHSIG_CTL` on FreeBSD (see
  `supervice/process.py::_pdeathsig_preexec`; libc is loaded in the *parent*
  at import, which is correct — dlopen after fork is unsafe).
  Tested end to end on this host, FreeBSD 15.1 + supervice 0.3.0, **both
  directions**, which is what makes it evidence:

      pdeathsig = true   -> kill -9 the supervisor -> child DIED with it
      pdeathsig = false  -> kill -9 the supervisor -> child SURVIVED (orphaned)

  The `false` case is the control. Without it "child died" could just mean the
  supervisor cleaned up on exit — it cannot, it took SIGKILL — so the contrast
  is what attributes the kill to pdeathsig.

  Residual, minor: `_pdeathsig_preexec` wraps the call in
  `except Exception: pass`. On FreeBSD 15 the call succeeds, so this is
  theoretical — but on a future arch or ABI change pdeathsig would degrade to a
  silent no-op with nothing logged. If you are relying on no-orphans for
  correctness (an at-least-once queue, where a double-run worker is a
  correctness bug), re-run the two-direction test above on the actual host
  rather than trusting the config key.
- For the most critical tiers: run `supervice -n` **under an rc.d script**
  using `daemon(8)` supervision, and alert on FATAL states:

  ```sh
  # /usr/local/etc/rc.d/myapp — chmod 555; enable with: sysrc myapp_enable=YES
  # PROVIDE: myapp
  # REQUIRE: NETWORKING postgresql
  . /etc/rc.subr
  name=myapp; rcvar=myapp_enable
  command=/usr/sbin/daemon
  # -r restart on exit, -R 5 backoff, -P/-p split supervisor vs child pidfiles
  command_args="-r -R 5 -P /var/run/myapp/daemon.pid -p /var/run/myapp/supervice.pid \
                -o /var/log/myapp/supervice.log \
                /usr/local/bin/supervice -c /usr/local/etc/myapp/supervice.ini -n"
  load_rc_config $name; run_rc_command "$1"
  ```

  `daemon -r` is the closest FreeBSD analogue to `Restart=on-failure`. Note it
  restarts on **any** exit including clean ones — use `-R` to pace it, or the
  supervisor will hot-loop on a config error.

## Quickstart

```bash
pip install supervice
supervice -c supervice.ini -n   # foreground (containers); omit -n to daemonize
supervicectl status|start|stop|restart|startgroup|stopgroup|reload
```

```ini
[supervice]
logfile =            ; empty = stdout in foreground
pidfile = /var/run/myapp/supervice.pid    ; FreeBSD: /var/run — there is no /run
socket = /var/run/myapp/supervice.sock    ; never a world-writable dir

[program:worker]
command = python3.12 -u worker.py --port 90%(process_num)s   ; FreeBSD ports
                                 ; install versioned binaries; bare `python3`
                                 ; does NOT exist on this host
numprocs = 2                     ; instances worker:00, worker:01
startsecs = 3                    ; RUNNING only after surviving 3s
startretries = 3                 ; then FATAL
stopsignal = TERM
stopwaitsecs = 10                ; then SIGKILL of the process group
stdout_logfile = /var/log/myapp/worker_%(process_num)s.log   ; daemon-rotated
healthcheck_type = tcp           ; or script (runs as `user`, via sh -c)
healthcheck_port = 9000
user = appuser                   ; drop privileges (daemon must be root)
pdeathsig = true                 ; children die if supervisor dies — works on
                                 ; BOTH Linux (prctl) and FreeBSD (procctl);
                                 ; verified on this host, see above

[group:workers]
programs = worker
```

## Behavioral facts to rely on

- `%(process_num)s` expands in `command`, `environment`, and logfiles.
- Health-restart policy: paced via backoff, FATAL after `startretries`
  consecutive unhealthy restarts; a passing check resets the counter.
- RPC replies are truthful: "Started X" only if RUNNING was reached; `stop`
  waits for the state to settle; an unkillable process shows STOPPING.
- `reload` (via supervicectl) applies config edits on next restart; SIGHUP is
  deliberately ignored.
- Children are killed as a process group; a service that double-forks escapes
  supervision — run services in the foreground.
- Config is trusted input (commands + shell health checks execute by design).
- AF_UNIX socket paths must stay under ~104 chars — keep socket paths short.
  (FreeBSD's `sun_path` is 104 bytes, so this is a hard limit here, not a
  guideline; `/var/run/<short>/s.sock` leaves plenty of room.)
- Zero dependencies, Python ≥ 3.10, fully typed, described as **Linux-first** —
  but check before assuming a gap: `pdeathsig` has a real FreeBSD branch (see
  above). Treat genuinely Linux-only surfaces (`/proc` inspection, cgroup
  accounting) as absent here, and prefer `pkg install` + `python3.12 -m pip`
  over distro `pip`; install path is `/usr/local/bin`, not `/usr/bin`.
- **Finding supervice on this host:** it is NOT on `PATH`. It lives per-service
  in the venvs — `/opt/{auth,tokengate,futex,ledger}/venv/bin/supervice`
  (0.3.0). `command -v supervice` returns nothing and that is NOT evidence it
  is missing; check the venvs before concluding anything about availability.
  Each service runs it under `daemon(8)` via `/opt/<svc>/bin/run-supervice.sh`
  with its config at `/opt/<svc>/etc/supervice.ini`.
