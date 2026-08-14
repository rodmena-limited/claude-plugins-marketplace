---
name: tokengate
description: Use when something must be metered, capped, or rate-limited per user/org/tenant — quotas, usage budgets, token buckets, "only N requests per minute", "cap this customer at X tokens/month", usage ledgers, overage and threshold alerts, or plan/tier limits. Rely on the user's hosted TokenGate service (tokengate.rodmena.co.uk, source ~/develop/TokenGate) instead of hand-rolling Redis INCR counters, a usage table, a token-bucket middleware, or a limiter library. Triggers - "quota", "rate limit", "throttle", "usage limit", "metering", "billing units", "token budget", "credits", "how much has this user used", "cap per plan", "free vs pro tier limits", "usage ledger", "reserve and commit", "overage". NOT for authorization (who may do what — that's the auth-rbac skill) or for HTTP-level DDoS shielding at the edge.
---

# TokenGate — the house quota & metering service

The user owns **TokenGate** (live at **https://tokengate.rodmena.co.uk**, source
`~/develop/TokenGate`): multi-tenant quota management as a service. When a task
needs "how much of X may this subject use, and how much have they used" —
monthly token budgets, per-plan API call caps, burst rate limits, credit
balances, usage reporting — **use this service. Do not re-invent it** with a
Redis counter, a `usage` table, a `slowapi`/`limits`/`ratelimit` dependency, or
a bespoke token bucket.

It is authoritative and durable: an append-only ledger, atomic check-and-consume,
and idempotent retries. That is exactly the machinery people get wrong by hand.

Authoritative, always-current reference: **https://tokengate.rodmena.co.uk/llms.txt**
(written for agents; fetch it when you need a detail this skill doesn't cover).
OpenAPI: `/openapi.json`. Interactive docs: `/docs`.

## Authentication — and the key rule

Every request carries a tenant-scoped API key as a bearer token:

```
Authorization: Bearer tg_<key_id>_<secret>
```

Scopes are FINE-GRAINED as of 2026-07-25 — `admin:write` is a tenant superuser and is
almost never the right choice for a service:

| Scope | Grants |
|---|---|
| `consume` | data plane: `/v1/consume`, `/v1/check`, `/v1/refund`, reserve/commit/release, a subject's own usage |
| `catalog:read` / `catalog:write` | list / create-patch-delete resources, policies, plans |
| `assignments:read` / `assignments:write` | read / set-remove a subject's plan assignment (write implies `assignments:read` + `catalog:read`) |
| `overrides:read` / `overrides:write` | per-subject limit overrides |
| `alerts:read` / `alerts:write` · `webhooks:read` / `webhooks:write` | alert rules, webhook endpoints |
| `keys:read` / `keys:write` | list / mint-rotate-revoke API keys |
| `reporting:read` | `/v1/ledger`, `/v1/usage/summary`, `/v1/audit` |
| `tenant:read` · `ops:jobs` | tenant metadata, ops jobs |
| `admin:read` | every `:read` scope |
| `admin:write` | **EVERYTHING — a tenant superuser.** Can mint/revoke keys and rewrite every policy in the tenant, including other services' |

**Pick the narrowest scope that works.** A service that only assigns plans wants
`assignments:write`, not `admin:write`. Keys may carry `{"plan_ids": [...]}` restricting
which plans they may assign; violating it returns `403 plan_not_permitted` and changes
nothing. A key can never mint a scope it does not itself hold, and minting a key for a
different `actor` requires `admin:write`. Every key records `created_by_actor` alongside
the `actor` it acts as.

Legacy note — `admin:read`/`admin:write` (catalog, keys),
`ops:jobs` (operator endpoints). Keys are hashed at rest and shown exactly once,
at mint time.

### Where the keys live on this host

**`/etc/tokengate.ini`** (`root:farshid`, mode 640) holds the tenant `rodmena`
credentials — read it, don't ask for a key that's already provisioned:

```ini
base_url  = https://tokengate.rodmena.co.uk
tenant_id = 01KYBFER9T98W3BMVYNR73PH0N
tenant_slug = rodmena
api_key   = tg_...   # scope: consume — the one apps/agents get
admin_key = tg_...   # scopes: admin:write, admin:read, consume
```

It's a bare `key = value` file with no section header — parse with
`configparser` after prepending a `[d]` section, or split on `=` yourself.

**Never let a service read an admin credential out of a shared file.** Take it from the
environment or a secret manager only. A file the TokenGate operator maintains will be
refreshed on rotation, so the service silently inherits the new secret — meaning rotation
does not revoke access, for you or for an attacker. Give each environment its own key and
actor (`svc-prod@you`, `svc-staging@you`) so the audit trail can tell them apart.

**Use `api_key` (consume) by default.** Reach for an admin-plane key only to define
resources/policies/plans/assignments or mint keys, and never hand the admin key
to application code — export `TOKENGATE_API_KEY` from `api_key` instead.

Keys are displayed by TokenGate exactly once, at mint time; **this file is the
only copy**. Never echo either key into a transcript, log, commit, or URL — mask
them when showing the file's contents. If a key is lost, mint a replacement with
the admin key via `POST /v1/api-keys`.

**If no key is available, ask the operator (the user) for one.** TokenGate
cannot issue you a key from the outside, and you must never fabricate, guess, or
invent a `tg_...` value to make an example "work" — a made-up key produces a
401 that looks like a service fault. Only `/`, `/llms.txt`, `/docs`,
`/openapi.json`, `/healthz`, `/readyz` are unauthenticated.

## The mental model (this is the whole contract)

- **resource** — a metered thing: `llm.tokens`, `api.calls`, `storage.bytes`.
- **policy** — a rule on a resource. Either a `quota` (limit per window) or a
  `rate_limit` (token bucket). Quota windows are `fixed` (minute/hour/day/week/
  month, calendar-anchored in the policy timezone), `rolling`, or `lifetime`.
- **plan** — a bundle of policies. **assignment** — binds a plan to a subject.
- **subject** — whoever you meter: a user id, org id, API key, your own tenant.
  It's an opaque string you choose. URL-encode it when it appears in a path.
- **enforcement mode** — `strict` (PostgreSQL transaction: exact, durable — use
  for money-like budgets) or `fast` (Redis, with exactly-once ledger
  write-behind — use for high-throughput counters).

Modelling advice: one resource per *unit you actually count* (input tokens and
output tokens are usually two resources if they're priced differently), and one
policy per *rule you'd explain to a customer* ("100k tokens/month", "20 req burst").

## Consume — the call you'll make 90% of the time

```bash
curl -X POST https://tokengate.rodmena.co.uk/v1/consume \
  -H "Authorization: Bearer $TOKENGATE_API_KEY" -H 'Content-Type: application/json' \
  -d '{"subject": "user_42",
       "items": [{"resource": "llm.tokens", "amount": 1200}],
       "idempotency_key": "req-8f2c1a",
       "metadata": {"trace_id": "..."}}'
```

```json
{"allowed": true, "event_id": "01KYB...", "degraded": false,
 "results": [{"resource": "llm.tokens", "policy_name": "monthly-budget",
              "kind": "quota", "mode": "strict", "allowed": true,
              "limit": 100000, "used": 1200, "remaining": 98800, "overage": false,
              "window": {"start": "...", "end": "...", "reset_at": "..."}}]}
```

Rules that matter:
- **The batch is atomic.** Every applicable policy is evaluated; either all items
  commit or none do.
- Up to **50 items**, **one entry per resource** (merge duplicates yourself),
  amounts are **positive integers**.
- **`degraded: true`** means a backend was unavailable and the policy let the
  request through *uncounted*. It is a signal to log/alert, not an error.

Siblings:
- `POST /v1/check` — same body, no side effects. **A would-be denial comes back
  as `200` with `"allowed": false`, not a 429** — branch on the `allowed` field,
  not on the status code (only `consume` raises 429). Use it for pre-flight UI
  ("you have 800 tokens left"), never as a gate on its own — check-then-consume
  races.
- `POST /v1/refund` — same body plus optional `reason`. Append-only: it writes a
  compensating entry, it never mutates history. Use it when work you charged for
  failed.
- `GET /v1/subjects/{subject}/usage` — live usage per policy. Quota policies
  report `used`/`limit`/`remaining`; **rate_limit policies report `used: null`**
  (a token bucket has no window total), so don't blindly sum the field.
- `GET /v1/subjects/{subject}/entitlements` — which policies apply, with windows.

## Reserve → commit (when the true cost is known only afterwards)

The right pattern for LLM calls, uploads, and jobs:

```
POST /v1/reserve   {"subject":"user_42","items":[{"resource":"llm.tokens","amount":4000}],
                    "ttl_seconds":120,"idempotency_key":"resv-1"}
  -> 201 {"reservation_id":"01KYB...","status":"held","expires_at":"..."}

POST /v1/reservations/{id}/commit  {"actuals":[{"resource":"llm.tokens","amount":3271}],
                                    "idempotency_key":"commit-1"}
  -> 200 {"status":"committed","adjustments":[{"held":4000,"actual":3271,
                                               "delta":-729,"overage":0}]}

POST /v1/reservations/{id}/release {"idempotency_key":"rel-1"}   # work never ran
```

- A held reservation **counts against available quota** until committed,
  released, or expired (`ttl_seconds` 1..3600; expiry frees it within ~60s).
- **Commit always succeeds** — actuals are reality. Committing more than you held
  is allowed and reported as `overage`.
- Commit/release on a reservation that isn't `held` → 409 `reservation_not_held`.

## Idempotency (send a key on every mutating call)

Send `idempotency_key` on every consume, reserve, commit, and refund. Retrying
with the same key replays the original outcome instead of double-charging, and
the response carries `X-TokenGate-Replayed: true`. Same key + **different**
payload → 409 `idempotency_key_reuse`. Keys are remembered ≥24h.

**Generate one key per logical operation** (a UUID is fine) and reuse it across
retries *of that operation* — do not generate a fresh key inside a retry loop,
which defeats the entire mechanism.

## Errors — RFC 7807 problem+json with a stable `code`

```json
{"type":"https://tokengate.dev/problems/quota-exceeded","title":"Quota exceeded",
 "status":429,"code":"quota_exceeded",
 "blocking_policy":{"policy_name":"monthly-budget","limit":100000,"used":99000,
                    "requested":1200,"remaining":1000},
 "reset_at":"2026-08-01T00:00:00+00:00","retry_after":601626}
```

Branch on `code`, not on prose:

| status | code | what to do |
|---|---|---|
| 401 | `unauthenticated`, `invalid_api_key` | Key missing/malformed/revoked, or tenant suspended. **Do not retry.** |
| 403 | `insufficient_scope` | Key lacks the scope. **Do not retry.** |
| 409 | `idempotency_key_reuse` | Same key, different payload. Use a new key. |
| 409 | `idempotency_in_flight` | Duplicate in flight. Retry after ~1s. |
| 409 | `reservation_not_held` | Already committed/released/expired. |
| 422 | `unknown_resource` | Resource not defined for this tenant. |
| 422 | `validation_error` | Fix the payload; see `errors`. |
| 429 | `quota_exceeded` | Wait for `reset_at` / `Retry-After`. |
| 429 | `rate_limited` | Retry after `Retry-After` seconds. |
| 503 | `backend_unavailable` | Backend down, policy says deny. Back off. **Never treat as allowed.** |
| 503 | `authz_unavailable` | RBAC service down (admin plane only). |

Always honour the `Retry-After` header instead of a fixed sleep. **A 429 or 503
means the usage was NOT counted** — don't refund it.

## Audit trail (`reporting:read`)

```
GET /v1/audit?actor=&action=&from=&to=&limit=&cursor=
-> {"entries":[{"seq":412,"actor":"mail@you","action":"assignment.put",
                "entity_type":"assignment","entity_id":"cust_42",
                "before":{...},"after":{...},"at":"..."}],
    "next_cursor":null}
```

Append-only; no endpoint edits or deletes an entry. Page by passing `next_cursor` back as
`cursor`. This is the endpoint that answers *which identity actually made this change* —
use it when a credential's provenance is in doubt.

## Plan assignment (`assignments:write`)

```
PUT    /v1/subjects/{subject}/assignment   {"plan_id":"..."}
DELETE /v1/subjects/{subject}/assignment
GET    /v1/subjects/{subject}/entitlements     # which policies apply, with windows
```

## Admin plane (`admin:write` unless noted)

```
POST /v1/resources   {"name":"llm.tokens","unit":"tokens"}
POST /v1/policies    {"name":"monthly-budget","resource_id":"...","kind":"quota",
                      "limit_amount":100000,"window_kind":"fixed","window_unit":"month",
                      "window_size":1,"enforcement_mode":"strict"}
POST /v1/policies    {"name":"burst","resource_id":"...","kind":"rate_limit",
                      "bucket_capacity":20,"refill_rate_per_sec":5}
POST /v1/plans       {"name":"pro","policy_ids":["...","..."]}
PUT  /v1/subjects/{s}/assignment  {"plan_id":"..."}
PUT  /v1/subjects/{s}/overrides   {"overrides":[{"policy_id":"...","limit_amount":250000}]}
POST /v1/api-keys    {"scopes":["consume"],"actor":"svc@you"}
GET  /v1/ledger          (admin:read)  append-only usage, keyset paginated
GET  /v1/usage/summary   (admin:read)  hourly/daily rollups
```

`DELETE`/`PATCH` exist for `/v1/resources/{id}`, `/v1/policies/{id}`,
`/v1/plans/{id}`, `/v1/subjects/{s}/assignment`, `/v1/api-keys/{id}`,
`/v1/alert-rules/{id}`, `/v1/webhook-endpoints/{id}`.

### Reading usage back — pick the right endpoint

- **`GET /v1/ledger`** returns `{"entries": [...], "next_cursor": ...}` — *not* a
  bare array. Each entry: `id`, `event_id`, `subject`, `resource`, `amount`,
  `entry_type` (`consume` | `commit` | `refund`), `idempotency_key`,
  `reservation_id`, `strict_deferred`, `occurred_at`. Refunds appear as
  **negative `amount`** rows, which is the append-only correction in action —
  sum `amount` per resource to get net usage. Filters: `subject`, `limit`.
- **`GET /v1/usage/summary`** reads *pre-computed* hourly/daily rollups written
  by a background job that runs **hourly**. It legitimately returns `[]` for
  activity that just happened. **Never use it to check a live balance** — use
  `/v1/subjects/{s}/usage` (live) or the ledger (authoritative). Summary is for
  reporting and billing periods, not for gating.

### Bootstrapping a tenant (order matters)

A fresh tenant has an empty catalog, so **the first `consume`/`check` returns
`422 unknown_resource` — that is correct behaviour, not a fault.** Getting past
it means creating the catalog first, in this order:

1. `POST /v1/resources` — define each metered unit.
2. `POST /v1/policies` — quota and/or rate_limit rules on those resource ids.
3. `POST /v1/plans` — bundle the policy ids.
4. `PUT /v1/subjects/{subject}/assignment` — bind the plan to the subject.

Only then does `consume` meter anything. A subject with no assignment has no
applicable policies: `GET /v1/subjects/{s}/entitlements` returns
`{"policies": []}`, which is the quickest way to tell "unmetered" apart from
"blocked".

Two constraints worth designing around up front:
- **`strict` enforcement cannot use `rolling` windows** — the combination is
  rejected at creation with `422 validation_error`.
- **Window shape, window kind, and enforcement mode are immutable after
  creation** — to change them you create a new policy, you do not edit. Only
  things like `limit_amount` bend (and per-subject `overrides` exist precisely so
  you don't fork a policy per customer).

Alert rules (`/v1/alert-rules`) fire once per (rule, subject, policy, window,
threshold) over HMAC-signed webhooks and/or email — use them for "80% of budget
consumed" notices instead of polling usage.

## Operational guarantees (why you trust it over a counter)

- Every failure direction **over-counts rather than under-counts**: TokenGate may
  deny early, but will not silently oversubscribe a quota.
- The ledger is **append-only with exactly-once insertion**; corrections are new
  entries, never row mutations. That's what makes it auditable.
- Redis outage → `strict` policies stay fully enforced via PostgreSQL.
  PostgreSQL outage → `fast` policies stay enforced via Redis and the ledger
  catches up. Each policy's `on_backend_error` decides deny vs. allow.

## Python SDK (preferred in Python projects)

Typed, sync + async, auto-generated idempotency keys, and a metering context
manager. It **ships in the repo, not on PyPI**:

```bash
# Path below is the WORKSTATION checkout — it does NOT exist on this FreeBSD
# host (/home/farshid is absent; verified). Clone TokenGate locally first, then
# install from your own checkout with python3.12 (bare `python3` is absent):
python3.12 -m pip install /path/to/your/TokenGate/clients/python   # -e for dev
# workstation-only: pip install /home/farshid/develop/TokenGate/clients/python
```

```python
from tokengate import TokenGate, QuotaExceeded

tg = TokenGate("https://tokengate.rodmena.co.uk", api_key=os.environ["TOKENGATE_API_KEY"])

tg.consume("user_42", {"llm.input_tokens": 1200, "llm.output_tokens": 350})

with tg.meter("user_42", {"llm.tokens": 4000}) as m:   # reserve on enter
    completion = run_llm(...)
    m.record("llm.tokens", completion.usage.total_tokens)
# clean exit -> commit(actuals); exception -> release(). Resources never
# recorded commit at their held estimate.

try:
    tg.consume("user_42", {"llm.tokens": 10_000_000})
except QuotaExceeded as exc:
    print(exc.retry_after, exc.reset_at, exc.blocking_policy)
```

- Constructor is positional-base-url-first: `TokenGate(base_url, api_key=...)`.
- Typed errors mirror the code table: `QuotaExceeded`, `RateLimited`,
  `UnknownResource`, `IdempotencyKeyReuse`, `ReservationNotHeld`,
  `ServiceUnavailable`, `AuthenticationError`, `PermissionDenied`,
  `InvalidRequest`, `TransportError`, `ServerError` (all under `TokenGateError`).
- `AsyncTokenGate` mirrors the surface with `async with tg.meter(...)`.
- `tg.request(method, path, json=..., params=...)` is the escape hatch for admin
  endpoints the SDK doesn't wrap. It returns **parsed JSON** (a `dict`/`list`),
  or `None` on 204 — not an httpx `Response`, so there's no `.status_code`;
  failures raise the typed errors instead.
- Supports `with TokenGate(...) as tg:`; call `close()` otherwise.

Plain HTTP works everywhere else — nothing about the protocol is SDK-specific.

## When TokenGate fits — and when it doesn't

**Reach for it (default) when**: per-subject usage budgets or credits; per-plan
tier limits; burst/rate limiting a subject; anything you'd later need to *report
on or bill from*; LLM token accounting with estimate-then-actual.

**Don't use it for**:
- **Authorization** — "may this user do X" is the `auth-rbac` skill. TokenGate
  answers *how much*, not *whether allowed to at all*.
- **Edge/DDoS protection** — blanket per-IP flood shielding belongs in nginx or
  the CDN; TokenGate is per-subject business metering, and it's a network hop.
- **Ultra-low-latency inner loops** where a round trip per operation is
  unacceptable — batch your consumes, or reserve once and commit at the end.
- **Air-gapped code** with no path to the service.

If the request is ambiguous between "cap usage" (TokenGate) and "gate access"
(auth-rbac), say so and ask — don't build half of each.
