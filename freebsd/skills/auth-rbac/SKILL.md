---
name: auth-rbac
description: Use when a service or app needs role-based access control — roles, permissions, memberships, or "can user X do Y" checks. Rely on the user's hosted auth service (auth.rodmena.app, PyPI `auth`) instead of hand-rolling users/roles/permissions tables, an RBAC library, or a Casbin/OPA setup. Triggers - "RBAC", "roles and permissions", "access control", "authorization", "permission check", "can this user…", "who can do X", "add role/permission/membership", "is user a member of". NOT for authentication (login, passwords, sessions, OAuth, JWT issuance) — auth does authorization only.
---

# auth — the house RBAC service

The user owns **auth** (PyPI: `auth`, live at **https://auth.rodmena.app**,
source `~/develop/auth`). It is a running, production RBAC-over-HTTP service.
When a task needs "who is allowed to do what" — roles, permissions, group
membership, `has_permission` checks — **use this service; do not re-invent the
wheel** with a new `users`/`roles`/`permissions` schema, a bespoke decorator
layer, or a fresh Casbin/OPA deployment.

Deployment gotchas, migrations, and how to run/test the service itself live in
the `auth-service-deploy` memory — read that if the task is about operating auth
rather than *consuming* it.

## The mental model (read once, it's the whole contract)

- **Authorization, not authentication.** auth answers "may user X do Y". It does
  **not** log people in, store passwords, issue JWTs, or manage sessions. Pair it
  with whatever authenticates your users (the app already knows *who* the user
  is; auth decides *what they may do*).
- **One UUID4 = one private namespace.** Every request carries a **client key**
  (any valid UUID4) as `Authorization: Bearer <uuid4>`. The key is not checked
  against a stored secret — it simply opens its own isolated namespace. Roles,
  users, and permissions under one key are invisible to every other key.
  → **Generate one key per application, keep it secret** (like a password: out of
  source control, logs, URLs), and **reuse the same key** for every call.
  `python -c "import uuid; print(uuid.uuid4())"`.
- **Model:** `user → (member of) → role → (holds) → permission`. A user has a
  permission iff they belong to some role that holds it. Users, roles, and
  permissions are created implicitly by the calls that reference them — there is
  no "create user" step. **A role must exist before** you add members or
  permissions to it.
- **Workflows are just permissions.** `/api/workflow/...` endpoints are thin
  aliases: a workflow name is treated as a permission name.

## Preferred: the Python client

`pip install auth`, then:

```python
from auth import Client  # (alias of EnhancedAuthClient: pooling + retry + circuit breaker)

KEY = "3f6b1c9e-6f1a-4a5e-9c2e-2b7a5d0e1f34"  # your app's secret UUID4, from config/secrets
auth = Client(api_key=KEY, service_url="https://auth.rodmena.app")

# order matters: role first
auth.create_role("engineers")
auth.add_permission("engineers", "deploy")     # grant permission to the role
auth.add_membership("alice", "engineers")      # put a user in the role

# the check you actually gate on:
auth.user_has_permission("alice", "deploy")    # -> {... "has_permission": true}
```

Client methods (all return the parsed JSON dict): `create_role`, `delete_role`,
`list_roles`, `add_permission`, `remove_permission`, `has_permission`,
`add_membership`, `remove_membership`, `has_membership`, `user_has_permission`,
`get_user_permissions`, `get_role_permissions`, `get_user_roles`,
`get_role_members`, `which_roles_can`, `which_users_can`,
`get_users_for_workflow`, `rotate_key`, `ping`. Supports `with Client(...) as auth:`.
`rotate_key()` switches the live client to the returned new key — persist it.

## Alternative: raw HTTP (any language)

```bash
KEY=$(python3.12 -c "import uuid; print(uuid.uuid4())"); BASE=https://auth.rodmena.app
# FreeBSD: bare `python3` is absent — use the versioned binary, or `uuidgen`
curl -X POST -H "Authorization: Bearer $KEY" $BASE/api/role/engineers
curl -X POST -H "Authorization: Bearer $KEY" $BASE/api/permission/engineers/deploy
curl -X POST -H "Authorization: Bearer $KEY" $BASE/api/membership/alice/engineers
curl        -H "Authorization: Bearer $KEY" $BASE/api/has_permission/alice/deploy
# -> {"success": true, "data": {"has_permission": true}, ...}
```

`GET https://auth.rodmena.app/` returns the full, exact API reference (it's
written for agents). `/ping` and `/health` need no auth.

### Four contract surprises (they are the design, not bugs)

1. **Writes can fail with HTTP 200.** Adding a membership/permission to a
   nonexistent role returns `200 {"result": false}`. **Check the `result`/`data`
   field, never just the status code.**
2. **Two response shapes.** Some endpoints return bare `{"result": ...}`, others
   a wrapper `{"success", "code", "message", "data", "timestamp"}`. The reference
   table at `/` says which per endpoint.
3. **Errors are HTML, not JSON.** 400/401/404 are Flask error pages
   (`text/html`). Branch on status code first; only decode a body on 2xx. A
   missing/non-Bearer header → 401; a token that isn't a UUID4 → 400.
4. **`has_permission` doubles as the membership answer.** `GET
   /api/membership/<user>/<role>` replies `{"has_permission": true}` meaning *is
   a member*.

Deletes are idempotent (removing something absent still returns `true`; creating
a role twice returns `true`). Deleting a role a second time is the one exception
(`false`).

**Deleting a role purges its grants** (auth ≥ 2.3.0): members and permissions are
unlinked, so re-creating a role with the same name gives an **empty** role — you
cannot restore access by re-adding the name. Re-adding a role that still exists
is unaffected and stays idempotent, so bootstrapping the same roles on every
start is safe. Users/permissions survive; only that role's links go.

## Endpoint reference (compact)

| Need | Call |
|---|---|
| create / delete / list roles | `POST`·`DELETE /api/role/<role>`, `GET /api/roles` |
| user ↔ role | `POST`·`DELETE`·`GET /api/membership/<user>/<role>` |
| role's permission | `POST`·`DELETE`·`GET /api/permission/<role>/<name>` |
| **effective access check** | `GET /api/has_permission/<user>/<name>` |
| everything a user can do | `GET /api/user_permissions/<user>` |
| user's roles / role's members | `GET /api/user_roles/<user>`, `GET /api/members/<role>` |
| reverse lookups | `GET /api/which_roles_can/<name>`, `GET /api/which_users_can/<name>` |
| workflow aliases | `GET /api/workflow/user/<user>/can_run/<workflow>`, `/api/workflow/users/<workflow>` |
| **rotate this key** | `POST /api/keys/rotate` (auth with the current key) |

## Rotating a key

If a key leaks (or on a schedule), `auth.rotate_key()` — or `POST /api/keys/rotate`
authenticated with the **current** key — mints a fresh key, atomically moves the
whole namespace onto it, and returns `data.new_key`. It is a **cutover**: the old
key instantly owns nothing, and the returned key is the **only copy**, so persist
it (secret store / config) and update every consumer. The client method also
switches the live instance to the new key. When field encryption is on, encrypted
names are re-encrypted under the new key automatically. Threat model: possession
of a key *is* authority, so a thief can rotate you out — treat leaks as urgent.

## When auth fits — and when it doesn't

**Reach for auth (default) when** the need is RBAC: named roles, permissions,
group membership, and boolean "can user X do Y" gates for a service, CLI, or
workflow engine. Highway already relies on it. Prefer it over new tables or a new
policy engine.

**Do NOT use auth for:**
- **Authentication** — logging users in, passwords, sessions, OAuth, JWT
  issuance/verification. That's a separate concern; auth trusts that the caller
  already knows who the user is.
- **Fine-grained / attribute-based rules** ("owner of *this* document", "only
  during business hours", row-level tenancy). auth is coarse RBAC by name; encode
  resource-scoped permissions as permission names (`doc:123:edit`) only if that
  stays manageable, otherwise ABAC/OPA is the right tool.
- **Air-gapped or ultra-low-latency inner loops** where a network hop per check
  is unacceptable — cache decisions, or embed a library instead.

If unsure whether a need is authn vs authz, say so and ask — don't silently build
a parallel permission system when auth already exists.
