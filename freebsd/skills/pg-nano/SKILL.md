---
name: pg-nano
description: Use when connecting to, operating, restoring, or troubleshooting any Rodmena production PostgreSQL database — auth, tokengate, identity, futex, ledger, runflow, agentbus, red9, mail_api. Triggers - "connect to the database", "psql", "production database", "pg-nano", "certificate verify failed", "no pg_hba.conf entry", "restore the database", "point in time recovery", "pgbackrest", "promote the standby", "replication lag", "database credentials", "where does the database live". Covers the four-box fleet, the mandatory TLS client-certificate auth, the per-driver DSN idioms that are NOT interchangeable, backup/restore, and the standby topology.
---

# pg-nano — the Rodmena PostgreSQL fleet

Nine production databases on four OVH FreeBSD 15 boxes running PostgreSQL 18.4.
Every remote connection needs **three** things: TLS, a client certificate whose
**CN equals the PostgreSQL role name**, and a SCRAM password. There is no
password-only access from the network, by design.

Built 2026-08-09. If nothing has changed since, everything here still holds — run
`~/.config/pg-nano-01/verify.sh` to confirm before trusting it.

## Where everything is

| host | region | databases |
|---|---|---|
| `pg-nano-01.rodmena.co.uk` (51.38.83.233) | OVH Bexley 🇬🇧 | futex, ledger, runflow |
| `pg-nano-02.rodmena.co.uk` (51.91.248.208) | OVH Gravelines 🇫🇷 | auth, tokengate, identity |
| `pg-nano-03.rodmena.co.uk` (57.129.134.84) | OVH Bexley 🇬🇧 | agentbus, red9, mail_api |
| `pg-nano-04.rodmena.co.uk` (57.131.136.207) | OVH Limburg 🇩🇪 | **no primaries** — 3 standbys |

pg-nano-01 and -03 are 0.59 ms apart: the **same datacenter**. Only -02 and -04 are
elsewhere. Do not assume separate boxes mean separate failure domains — measure RTT.

## Credentials

Everything lives in `~/.config/pg-nano-01/` (mode 0700) on the workstation:

```
credentials.env   every role password, pgBackRest cipher passphrase, S3 keys
ca/ca.key         the private CA — mints client certs for any role
clients/*.crt|key 18 per-role certificate pairs, CN = role name
verify.sh         re-runnable fleet probe; exit 0 = all pass
handover.md       the full written handover — the authority for everything
```

**If that directory is gone** (rebuilt machine, lost workstation), an encrypted copy of
the whole thing is at `/etc/secrets.enc` and in a secret gist. It is age-encrypted to two
SSH keys — the workstation and the laptop — either of which decrypts it alone:

```bash
age -d -i ~/.ssh/id_ed25519 /etc/secrets.enc | tar -xzf -   # creates ./pg-nano-01/
```

`pkg install age` on this FreeBSD host (`apt install age` on Debian-family
boxes — there is no apt here). Ask the user for the gist URL if
`/etc/secrets.enc` is also gone; do not guess it.

## Connecting

```bash
set -a; . ~/.config/pg-nano-01/credentials.env; set +a
C=~/.config/pg-nano-01/clients
CA=/etc/ssl/certs/ca-certificates.crt      # FreeBSD: /etc/ssl/cert.pem

PGPASSWORD="$PG_PGADMIN_PASSWORD" psql \
  "host=pg-nano-01.rodmena.co.uk port=5432 dbname=runflow user=pgadmin \
   sslmode=verify-full sslrootcert=$CA sslcert=$C/pgadmin.crt sslkey=$C/pgadmin.key"
```

`pgadmin` is the superuser role and can reach **any** database on any host — use it for
admin work and migrations. Service roles are scoped in `pg_hba.conf` to their own database
only, so `agentbus` genuinely cannot connect to `red9`.

Client key files must be mode `0600` or libpq refuses them.

## The DSN idioms are NOT interchangeable

Copying a working DSN between services is the single most reliable way to lose an hour.

| service | driver | what works |
|---|---|---|
| auth | psycopg via SQLAlchemy sync, **system libpq** | `sslrootcert=system` works |
| identity, runflow, mail_api | psycopg 3, **binary wheel** | `sslrootcert=system` **FAILS** — needs an explicit CA path |
| tokengate, agentbus, red9 | raw asyncpg | libpq params fine, but **no `system` keyword** — explicit path |
| futex | SQLAlchemy + asyncpg | URL params do **not work at all** — needs `ssl.SSLContext` |

Diagnosing by symptom:

- `SSL error: certificate verify failed` → psycopg **binary** wheel; its bundled OpenSSL
  does not use the system CA store. Check with
  `python -c "import psycopg.pq; print(psycopg.pq.__impl__)"`. Give an explicit CA path.
- bare `FileNotFoundError` naming nothing → asyncpg treating `sslrootcert=system` as a
  filename. Give an explicit CA path.
- `TypeError: connect() got an unexpected keyword argument 'sslmode'` → SQLAlchemy's
  asyncpg dialect forwarding URL params. Build an `ssl.SSLContext` and pass
  `connect_args={"ssl": ctx}`.
- `PermissionError` on `.postgresql/root.crl` → asyncpg with an unexpected `$HOME`
  (e.g. under `su -m`, which keeps root's).
- `no pg_hba.conf entry for host ... user X, database Y` → that role is not permitted that
  database. This is isolation working, not a bug.
- `connection requires a valid client certificate` → no cert supplied.

## Migrations

migretti, state in `public._migrations` **inside** each database, so `pg_dump` carries it.
Run as `pgadmin`; service roles have no DDL rights:

```bash
export PGPASSWORD="$PG_PGADMIN_PASSWORD"
export MG_DATABASE_URL="postgresql://pgadmin@pg-nano-0N.rodmena.co.uk:5432/<db>\
?sslmode=verify-full&sslrootcert=/etc/ssl/certs/ca-certificates.crt\
&sslcert=$HOME/.config/pg-nano-01/clients/pgadmin.crt\
&sslkey=$HOME/.config/pg-nano-01/clients/pgadmin.key"
mg status && mg apply --yes
```

migretti runs on psycopg even where the app uses asyncpg, so it needs the psycopg-style
URL, never `postgresql+asyncpg://`.

## Backups and restore

pgBackRest to OVH S3 (`s3://tedious-brattain/pg-nano-0N/`), aes-256-cbc, daily full +
hourly incremental + continuous WAL (`archive_timeout=300`, RPO ≤ 5 min). Run on the box:

```bash
pgbackrest --stanza=pg-nano-0N info      # state of the repository
pgbackrest --stanza=pg-nano-0N check     # forces a WAL switch and verifies archiving
pgbackrest --stanza=pg-nano-0N --type=time --target="YYYY-MM-DD HH:MM:SS+00" restore
pgbackrest --stanza=pg-nano-0N --pg1-path=/var/db/postgres/scratch restore  # elsewhere
```

The cipher passphrase is in `credentials.env`. **Losing it makes every backup
unrecoverable.**

## The standbys (pg-nano-04)

Three physical standbys, one per primary, as FreeBSD rc profiles:

| instance | port | follows |
|---|---|---|
| s01 | 5433 | pg-nano-01 |
| s02 | 5434 | pg-nano-02 |
| s03 | 5435 | pg-nano-03 |

```bash
/usr/local/sbin/pg-standby-check.sh          # exit 0 = all healthy; runs every 10 min
service postgresql status s02
service postgresql promote s02               # standby becomes a primary
```

No replication slots — the standbys fall back to the S3 archive when they lag, so they can
never fill a primary's disk. **Promotion is manual**; there is no automatic failover.
After promoting, repoint the affected services' DSNs at `pg-nano-04.rodmena.co.uk:<port>`.

**A standby is not a backup.** `DROP TABLE` replicates in milliseconds. Only pgBackRest
PITR recovers from a logical mistake.

## Things that will bite you

- **Never rate-limit port 5432 in pf.** A per-source connection cap is fine; rate-based
  blocklisting takes the whole fleet down on any pool restart or rolling deploy. This
  happened once already.
- **Never restore grants with a blanket `GRANT ... ON ALL TABLES`.** It silently widens
  append-only audit tables to full DML. After any `--no-owner` restore, diff the privilege
  set against the source:
  `select table_name||':'||privilege_type from information_schema.table_privileges where grantee='<role>'`.
- **Standby `max_connections` must be ≥ the primary's** or recovery aborts. `shared_buffers`
  may be smaller.
- **`LIKE 'pg_%'` hides roles** — `_` is a wildcard, so it also matches `pgadmin`. Escape it.
- **`n_live_tup` is an estimate.** Compare exact `count(*)` when verifying a migration, and
  sort both sides with `LC_ALL=C sort` (FreeBSD and GNU `sort` collate `_` differently).
- **Health endpoints often do not touch the database.** identity's
  `/.well-known/openid-configuration` returns 200 with the DB down; use `/oauth2/jwks`.
  mail_api has no `/healthz` at all. Prefer a query that must read migrated rows.
- **`gh gist delete --yes` is not a valid flag** — it prints usage and deletes nothing.
  Use `gh api -X DELETE gists/<id>` and verify.

## Verifying the whole fleet

```bash
~/.config/pg-nano-01/verify.sh          # all hosts; add 01|02|03 for one
```

It deliberately fails authentication a few times per host — that is how it proves bad
credentials are refused — and refuses to re-run within 600 s so it cannot get the operator
banned by fail2ban. Expect **37 passed, 0 failed**.

Each migrated repo also carries `docs/runbooks/database-deployment.md` on its default
branch with service-specific detail: ledger, auth, tokengate, futex, identity, RunFlow,
rodmena-mail-api, agentbus, red9.
