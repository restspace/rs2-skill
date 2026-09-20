---
name: rs2
description: This skill should be used when the user asks to inspect, call, or configure an RS2 server (Restspace 2, the Rust runtime); wants to manage tenant mounts or hot-reload tenant configuration; needs to author, store, or debug an RS2 pipeline spec (typed or string DSL), stored query, JSONata transform, or JSX template (the `template` service rendering data to HTML); asks about RS2 authentication, role specs, idempotency keys, retry policies, or effect classes; wants to read, query, or configure RS2 structured logs (the `log` service, OTel/OTLP records, boundary logging, the `logging` sink config); mentions the `rs2` CLI, `rs2 new`, `rs2 dev`, `rs2 deploy`, `rs2 migrate`, `rs2 sync` (copying or promoting a tenant or mount between two servers), `serverConfig.json`, a `tenants/<name>.json`, or a `code:<name>@<version>` mount; wants to write or deploy a custom sandboxed service (JS bundle or Wasm component) with capability grants; wants a WebSocket / realtime channel on a mount (`"webSocket": true`, the `websocket` facet, a pipeline triggered per socket message, pushing frames through `/<mount>/.sockets/`, guest `onOpen`/`onMessage`/`onClose` handlers); needs the agent surface or OpenAPI under `/.well-known/rs2/`; or is migrating a v1 Restspace `services.json` to RS2.
---

# RS2 (Restspace 2)

An RS2 server hosts composable HTTP services, each mounted on a root path per tenant. Custom code runs sandboxed (V8 isolates for JS, Wasmtime components for Rust/Wasm) with default-deny capabilities and hard resource limits. Example tenant:

```
/files     File store (streamed)
/data      Schema-validated JSON store
/auth      Authentication + RBAC
/orders    Pipeline (composition over other mounts)
/q         Stored queries
/render    JSX templates rendered to HTML
/services  Self-configuration API
/pay       code:stripe-wrapper@a1b2c3 (sandboxed custom service)
```

**Two hosts, one API.** RS2 ships two implementations of that API: the Rust server (`rs2-server`) and a TypeScript Worker running natively on Cloudflare Workers (`rs2-worker/`). Every status code, header, JSON field, error `code`, and listing shape is the same — the CLI, UIs, and agents work unchanged against either — and a black-box conformance suite holds both to it. Tell them apart by reading `limits.host` (`"rust"` | `"cloudflare"`) on `GET /.well-known/rs2/services`; feature-detect the handful of declared differences (Wasm bundles, guest async, per-invocation ceilings, adapter pooling) rather than assuming a host. See `http-api.md` → "Hosts".

The `rs2` CLI covers the developer loop — scaffold, run a local node, validate, deploy bundles, migrate v1 configs — plus a few admin/ops commands that drive a running server: `login`, `send` (PUT a local file to a path), `service add` (add a mount via the self-config API), and `run` (a script of `rs2` lines). These read a saved server identity from `rsconfig.json`. For anything they don't cover, interact with a tenant over **plain HTTP** (curl, `Invoke-RestMethod`). See `references/cli.md`.

## Orient First

1. `GET /.well-known/rs2/services` — every mount the caller may read, with its `pattern` (`store` | `store-view` | `transform` | `api`) and `facets`. Patterns are the polymorphism contract: one client codepath drives every mount sharing a pattern — `file` and `data` are both `store` and obey one normative shape (`references/services.md`); feature-detect facets, never special-case service names.
2. `GET /.well-known/rs2/agent-surface` — entities (data), actions (pipelines, with effect class and idempotency guidance), and stored queries with their parameter schemas. Filter with `?surface=mcp|ui|cli` against each mount's `x-expose`.
3. `GET /.well-known/rs2/openapi` — OpenAPI 3.1 for the tenant; the schemas it references are the ones enforced at runtime.
4. `GET /services/catalogue` — available service types and their config schemas.
5. `GET /services/raw` — the full tenant config (note the `ETag` for later writes).

The discovery surface is generated and read-only; unreadable mounts are invisible to the caller, so an "empty" surface usually means an unauthenticated request, not an empty tenant.

## Authenticate

`POST /auth/login` with `{"email": ..., "password": ...}` returns `{"token", "exp"}` and sets the `rs-auth` HttpOnly cookie. Send `Authorization: Bearer <token>` on subsequent requests (simplest from scripts). `POST /auth/refresh` re-issues past 50% of the session; `GET /auth/user` shows the verified principal. A malformed or expired token is rejected with 401 outright — it is never treated as anonymous. Repeated bad logins lock the account temporarily (401 with `Retry-After`).

Mount access is a role spec on the mount config: `"access": {"read": "all", "write": "A E", "delete": "A", "invoke": "A E U"}` — tokens are `all`, `authenticated`, role names, or path-scoped grants like `"U /user/{email}"`. GET/HEAD/OPTIONS check `read` (default `all`); PUT/PATCH check `write` (default `"A"`); DELETE checks `delete`; POST (and other non-idempotent verbs) check `invoke`; `delete`/`invoke` default to `write`. Strings `"open"` and `"authenticated"` also work. Only **operators** (a principal holding a tenant `operatorRoles` role) may change a mount's or a pipeline spec's `access`.

## Read Errors, Don't Guess

Every failure is RFC 9457 problem+json with a machine-readable `code`:

```json
{ "type": "https://rs2.dev/errors#limit_exceeded", "title": "Limit Exceeded",
  "status": 503, "code": "limit_exceeded", "detail": "...", "tenant": "t1",
  "traceId": "...", "retryable": true, "retryAfterMs": 2000,
  "limit": "wall_clock_ms", "observed": 30000, "cap": 30000 }
```

Codes: `bad_request`, `unauthorized`, `forbidden`, `not_found`, `conflict`, `precondition_failed` (412 — a store write's `If-Match`/`If-None-Match` failed; re-read and retry), `payload_too_large`, `validation_failed` (carries an `errors` array), `idempotency_key_reuse`, `limit_exceeded` (carries `limit`/`observed`/`cap`; retryable), `capability_denied`, `contract_violation` (custom-service fault), `engine_unavailable`, `path_unsafe`, `internal`. Pipeline failures additionally carry `pipeline.failedStep` and per-step statuses. Branch on `code`, honor `retryable`/`retryAfterMs`, and quote `traceId` when reporting. A tenant that repeatedly breaches limits trips a circuit breaker — flat 503s with `limit: "tenant_breaker"` until the cooldown passes.

## Write Safely

Exactly-once writes: send `Idempotency-Key: <opaque ≤256 chars>` on POST/PUT. A duplicate within the replay window returns the stored response with `Idempotency-Replayed: true`; a duplicate while the original runs gets 409 + `Retry-After`; the same key with a different payload gets 422 `idempotency_key_reuse`. Keys are scoped per tenant + mount + method + path.

Tenant reconfiguration is read-modify-write through the self-config API:

1. `GET /services/raw` — capture the body and the `ETag`.
2. Edit only the intended mounts/fields.
3. `PUT /services/raw` with `If-Match: <etag>`. The whole config is validated by dry-building the tenant — an invalid config returns 400 with details and the running tenant is untouched; a valid one hot-swaps atomically (204 + new ETag).

A stale `If-Match` returns 409: re-read and reapply. Details and the config document shape: `references/cli.md`.

For versioned or multi-file changes, prefer the **instruction-plane mirror**: `rs2 pull` copies the tenant's config + every spec store into a local `rs2/` directory (git-able, monorepo-friendly), you edit and `rs2 push`. Push reuses the same optimistic concurrency end-to-end (config `If-Match`, spec `If-Match`/412) and aborts on a remote change rather than clobbering. The single-shot `GET → PUT /services/raw` loop above stays the right tool for one quick edit. To copy a tenant — or one mount with its specs, bundle, and data — **from one server to another** (staging → prod), use `rs2 sync --from A --to B [--mount /p] [--dry-run]`, which moves both planes with the target's control mount and secrets protected. Decision rule, the mirror format, and sync semantics: `references/cli.md`. Store writes (file/data/spec) likewise honour `If-Match` (and `If-None-Match: *` for create-only) — the `conditional-write` facet.

## Compose

Pipelines are the composition mechanism, and a `pipeline` mount is a **store of pipelines**: author specs like files under `/<mount>/.pipelines/<name>` (envelope `{pipeline, retry?, …}`; the terse v1 string DSL is accepted and canonicalized to the typed spec); every other path on **any HTTP verb** executes the longest-prefix-matched spec, with `.root` governing the whole mount — so a pipeline can transparently wrap another service. A call step with an **absolute `http(s)://` URL calls out externally** through the mount's `httpOut` grants (host-allowlisted, credentials injected host-side, retry policy applying unchanged). `GET <mount>/.pipelines/<name>?$plan` returns the segment plan (retry/checkpoint boundaries, unsafe-step and uncovered-external-host warnings); `?$to-step=N` truncates execution for debugging. Transforms are JSONata. Read `references/pipelines.md` before authoring or debugging a spec, and for retry policies and effect classes (`pure`/`idempotent`/`keyed`/`unsafe`).

## Realtime (WebSockets — Cloudflare host only)

A mount opts in with `"webSocket": true` and then advertises the `websocket` facet — feature-detect it (and `limits.webSocket`) rather than assuming; on the Rust host a flagged mount just serves the plain GET. Sockets are not a second API: **every socket event is an internal `POST` to the connect URL** (so a `pipeline` mount runs its pipeline per message and the output is the reply frame; a `code:` mount gets `onOpen`/`onMessage`/`onClose(msg, ctx, socket)`), and **every outbound frame is a request to the reserved `/<mount>/.sockets/<path>` subtree** — so a pipeline pushes with an ordinary `call` step. Limits and the wall clock are per message, not per connection. The upgrade is gated by the mount's `read` role (browsers: `rs-auth` cookie, or offer subprotocols `rs2` + `rs2.bearer.<jwt>`); `.sockets/` sends need the mount's `write` role specifically, never `invoke`. A pushed frame can arrive before the HTTP response of the request that sent it — listen first. Config, the `.sockets/` table and auth: `references/services.md`; pipeline trigger/send: `references/pipelines.md`; guest handlers, limits and close codes (4000 + HTTP status, reason = RS2 code): `references/custom-services.md`.

## Extend

In order of preference: use an existing mount → mount another prebuilt service (`file`, `data`, `pipeline`, `query`, `auth`, `services`, `log` — see `references/services.md`) → deploy a custom sandboxed service. Custom services are single-file ES modules (or Wasm components) deployed content-addressed via `PUT /services/code/<name>` and mounted as `"service": "code:<name>@<version>"` with default-deny capability `grants`. The JS environment is a fixed supported-API surface (fetch over `httpOut` grants, virtual-time timers, no event loop). Read `references/custom-services.md` before writing or deploying one.

## Know The v1 Differences

If the user has v1 Restspace habits: there is no `rs call` — use HTTP directly. v1's untyped `rs sync` is replaced by `rs2 pull`/`push` for local, git-based editing, scoped to the **instruction plane** (config + spec subtrees + code pins), secrets-safe and ETag-guarded — and by `rs2 sync --from A --to B` for server-to-server promotion, which does move data and bundles but mount-by-mount through the validated APIs, never as a filesystem copy. RS2 also has `rs2 send` (a single-file PUT) and an `rsconfig.json` (server URL + saved login token, plus named `servers`). `--manage` mode is gone (the `services` mount is the management surface). Pre/post-pipelines on mounts, chords, timers/webhooks/email services, and `()` outer services do not exist in RS2 v1. `rs2 migrate <services.json>` converts a v1 config, carrying over mounts, access roles, retry policies, and pipelines (DSL → typed), and prints explicit warnings for everything it cannot carry.

## Additional Resources

| File | Load when... |
| --- | --- |
| `references/http-api.md` | You need exact endpoint shapes for discovery, auth, errors, idempotency, or limits |
| `references/services.md` | You need config fields and endpoint semantics for a prebuilt service (`file`, `data`, `pipeline`, `query`, `template`, `auth`, `services`, `log`), or the `webSocket` mount flag and `/.sockets/` subtree |
| `references/pipelines.md` | You are authoring, reading, or debugging a pipeline spec, condition, transform, retry policy, or segment plan, or a pipeline triggered by / sending to a WebSocket |
| `references/custom-services.md` | You are writing, validating, or deploying a custom JS/Wasm service, configuring capability grants, or writing WebSocket handler exports |
| `references/cli.md` | You are using the `rs2` CLI, editing `serverConfig.json`/tenant configs, or migrating from v1 |
| `references/v1-patterns.md` | You are mapping v1 pattern vocabulary (store, store-transform, …) onto RS2, or designing a custom service to a pattern |
