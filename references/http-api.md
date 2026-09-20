# RS2 HTTP API: discovery, auth, errors, idempotency, limits

## Tenancy and addressing

Tenancy is `single` (every request belongs to the configured tenant) or `multi` (tenant resolved from the Host header: explicit domain map first, then `{tenant}.{mainDomain}` subdomain). Ops endpoints `GET /healthz` and `GET /readyz` are tenant-independent, as is `POST /admin/reload-infras` (node admin token via `Authorization: Bearer`/`X-Admin-Token`; reloads operator infras with no restart → `{loaded, names}`; disabled 503 when no token configured — see `cli.md` → "Infras"). Per-tenant, `GET /services/infras` lists the infras a tenant may consume (secrets redacted; see `services.md`).

Paths are safety-validated before routing: traversal (`..`, encoded variants), null bytes, backslashes, control characters, and drive letters are rejected with 400 `path_unsafe` for **all** services. Longest mount prefix wins, on segment boundaries. (On the Cloudflare host the platform canonicalizes dot segments before the Worker sees the request, so `/files/../x` routes on the normalized path — 404 for an unmounted target — instead of 400 `path_unsafe`; null bytes, backslashes, control characters, and drive letters still reach the router and are 400.)

## Hosts

The RS2 HTTP API has **two implementations**: the Rust server (`rs2-server`) and a TypeScript Worker running natively on Cloudflare Workers (`rs2-worker/` in the runtime repo — one stateless Worker in front of one Durable Object per tenant, R2 for files, DO SQLite for data/idempotency/logs). Every status code, header name, JSON field, error `code`, and listing shape is the same on both, including the odd corners; a black-box conformance runner asserts it. **Identify the host by reading `limits.host` on `GET /.well-known/rs2/services`** (`"rust"` | `"cloudflare"`) — never by probing behaviour.

The differences are declared, not discovered:

| Difference on the Cloudflare host | How it shows up |
| --- | --- |
| **No Wasm engine** — JS bundles only | a `code:` mount whose bundle is Wasm answers **501** `engine_unavailable` at first request; the `code` entry in `GET /services/catalogue` lists `engines: ["js"]` |
| **Guest capabilities are async** | every `code:` mount's entry in `GET /.well-known/rs2/services` carries the **`guest-async`** facet: `ctx.request`, `ctx.state.get/put`, `ctx.readBody`, `ctx.body()` and `ctx.beginStream(...).write` return Promises, so bundles must `await` them (`ctx.log` stays synchronous). A bundle that awaits works on **both** hosts. Timers are real, not virtual, and platform globals are not shadowed — see `custom-services.md` |
| **Per-invocation ceilings** | memory is the platform's fixed 128 MiB; materialized bodies cap at 32 MiB (100 MB on Rust); guest budgets are CPU time via the Worker-only mount config field `"config": {"limits": {"cpuMs": 5000}}` (default 5 000, ceiling 30 000; ignored by the Rust host), breaches reported as `limit_exceeded` with `limit: "wall_clock_ms"`. All readable in the `limits` object below |
| **Opaque validators differ** | `ETag` values and the config version are different strings on the two hosts — they are opaque by contract, so round-trip them and never parse or compare across hosts |
| **`conditional-write` is atomic** | the facet is the same; the Cloudflare host serializes the check-and-put in the tenant's Durable Object, where the Rust local-fs store is best-effort. Client behaviour (send `If-Match`, handle 412) is identical |
| **`DELETE` of a directory that never existed → 204** | R2 has no directories; the Rust local-fs store answers 404. Accept `204|404` |
| **`builtin:mem` is durable** | it is DO-SQLite-backed there, not ephemeral — don't rely on it being wiped |
| **Guest (`code:`) store adapters don't pool connections across requests** | see `custom-services.md` → "Loadable adapters" |
| **Inbound WebSocket upgrade is served only here** | a `webSocket`-flagged mount gains the **`websocket`** facet and the discovery `limits.webSocket` object; on the Rust host such a mount serves the plain GET unchanged (parity is a follow-up) — see `services.md` → "WebSocket-enabled mounts" |

Everything else — including `If-Match` mismatch on `PUT /services/raw` being 409 not 412, and conditional headers being ignored on data `PATCH`/keyless `POST` — is reproduced exactly on both hosts.

**Operator endpoints.** `GET /healthz`, `GET /readyz` and `POST /admin/reload-infras` exist on both, with the same admin-token gate. The Rust node's operator surface otherwise is **files on disk** (`tenants/<name>.json`, `infras.json`); the Cloudflare host, which has no disk, exposes the equivalent as a **Worker-only admin API** on the same gate (`RS2_ADMIN_TOKEN`, presented as `Authorization: Bearer` or `X-Admin-Token`; no token configured → 503, bad token → 401). Bodies and responses are JSON, errors problem+json with `tenant: "-"`:

| Endpoint (Cloudflare host only) | Does |
| --- | --- |
| `GET /admin/tenants` | `{"tenants": [{"name", "domains": [...], "configVersion"}]}` |
| `PUT /admin/tenants/<name>` | Create/replace a tenant: `{"config": <tenant config>, "domains": ["api.acme.com"], "bootstrapAdmin": {"email","password"}?}`. Validates the name (`/`, `\`, `.` → 400), dry-builds the config (same errors as `PUT /services/raw`), registers the domains, and seeds the bootstrap admin **if absent** (needs `auth.jwtSecret`, else 400). 201 created / 200 replaced, with an `ETag` |
| `GET /admin/tenants/<name>` | The raw config, redacted like `/services/raw` |
| `DELETE /admin/tenants/<name>?confirm=<name>` | Removes the registry entries and deletes the tenant's Durable Object storage (409 without `confirm`). Stored **files are not deleted** |
| `PUT /admin/domains/<host>` | `{"tenant"}` — **claims** a host for a tenant (host lowercased; a malformed host name is a 400, and the same check applies to the `domains` array above). See "Attaching a customer's domain" below: **202** when it is not proven yet (and it does not route), 200 when it already is, 409 when another tenant holds the claim or the mapping |
| `GET /admin/domains` | `{"domains": [{"host", "tenant", "status"}]}` — live mappings and unproven claims, sorted |
| `GET /admin/domains/<host>` | The attachment; re-polls a pending one and promotes it if it has since been proven. 404 for an unknown host |
| `DELETE /admin/domains/<host>` | 204 — drops the mapping **and** any unproven claim, and removes what the provider provisioned |
| `PUT /admin/infras` | Store the `infras.json` document (the Rust node reads the file instead) |

### Attaching a customer's domain

A tenant can be served at a domain its owner controls (`app.acme.com`). The customer publishes **one CNAME**; nothing routes until the DNS proves them right.

`PUT /admin/domains/app.acme.com` with `{"tenant": "acme"}` answers **202** and:

```json
{ "host": "app.acme.com", "tenant": "acme", "status": "pending",
  "dnsRecords": [ { "type": "CNAME", "name": "app.acme.com", "value": "saas.rs2.example",
                    "required": true, "purpose": "routes the domain to this deployment" } ],
  "nextStep": "publish the required DNS record above at app.acme.com's DNS provider; …",
  "provider": { "name": "cloudflare-saas", "detail": { "cfStatus": "pending" } } }
```

Read `status` (`pending` | `active`), `dnsRecords` and `nextStep` — those are the same on every host and every provider. `provider.detail` is diagnosis for a human when a domain is stuck; never parse it.

A **claim is not a mapping**. The host starts routing only when the provider reports control of the DNS proven — checked on every `GET` of the attachment, and by a minutely reconcile for the customer who publishes the record and never comes back to look. Two tenants may claim the same host; only the one whose DNS resolves gets it. `DELETE` releases a claim.

Which provider runs is deployment configuration: `cloudflare-saas` when the `CF_API_TOKEN` + `CF_ZONE_ID` secrets are set (Cloudflare validates the hostname and issues the certificate), otherwise `manual`, which proves control by fetching `http://<host>/.well-known/rs2/domain-challenge/<token>` — a path only that deployment can answer — and leaves TLS to whatever sits in front.

**On the Rust node** the read endpoints exist and answer identically (`provider: {"name": "static"}`), because its tenancy map is `serverConfig.json` → `tenancy.domainMap`, read at startup. `PUT`/`DELETE` there answer **501 `provider_unavailable`** naming that file: attach the domain by editing it and restarting, and give the certificate to your reverse proxy.

Only these exact paths are claimed by the Worker — any other `/admin/*` path routes to tenant mounts as usual, so a tenant mount at `/admin` works on both hosts. Deploying the Worker host: `cli.md` → "The Cloudflare host".

## Discovery surface (read-only, generated)

| Endpoint | Returns |
| --- | --- |
| `GET /.well-known/rs2/services` | `{tenant, services: [{path, service, pattern, facets?, x-agent?, x-policy?, x-expose?, description?}], control, limits}` — only mounts the caller may read. `limits` is the host's per-invocation ceilings and which host is answering (see "Limits and containment"). `pattern` (`store` \| `store-view` \| `transform` \| `api`) is the conversation shape for polymorphic clients; `facets` are optional capabilities within it (see `services.md`). `control` points a generic admin client at the management surface (the `services` mount, mountable anywhere): `{path, config, catalogue, mounts, code}` with ready-made URLs, or `null` when no such mount is readable. Filter with `?surface=<name>` against mount `x-expose`, same semantics as agent-surface (string or array; absent = exposed everywhere; no param = unfiltered) — `control` follows its backing mount, so it is `null` when the `services` mount is scoped off the requested surface. e.g. `?surface=editor` yields a content-editing client's view |
| `GET /.well-known/rs2/agent-surface` | `{entities, actions, queries}`; actions carry `effect` and `idempotency: {header: "Idempotency-Key", honored: true}`; queries carry their `params` JSON Schema; actions/entities carry `inputSchema`/`outputSchema` when declared (wrapper config, pipeline envelope `input`/`output`, or a `code:` mount's deploy manifest); filter with `?surface=<name>` against mount `x-expose` (string or array; absent = exposed everywhere) |
| `GET /.well-known/rs2/openapi` | OpenAPI 3.1; operations carry `x-effect` and `x-idempotency-key`, and advertise their request/response media types as `content`; stored-query param schemas are the request-body schemas; each installed **dataset schema is inlined** under `components.schemas` with a concrete `{dataset}/{key}` path `$ref`-ing it (the same schema the data service enforces — no second fetch, no drift); wrapper/pipeline/`code:` mounts bind their declared I/O schemas; `components.schemas.Problem` describes errors |

Any non-GET on the surface is 405. Metadata keys carried from mount config: `x-agent`, `x-policy`, `x-expose`, `x-render`, `x-context`, `description`.

**Per-path probe:** `OPTIONS <any mounted path>` returns 200 with an `Allow` header and a JSON descriptor of the mount governing that path — `{path, service, pattern, facets?, schemaUrlPattern? (data), x-agent?, …}` — so a client can render any path from one round trip without correlating it back to the services list. The probe is read-gated (it needs the same access a GET would), and resolves by longest mount prefix, so sub-paths describe their mount. A permitted CORS preflight (`OPTIONS` + a trusted/allowed `Origin`) is still answered as a preflight, not a descriptor.

## Authentication

Tenant config carries an `auth` object: `{"jwtSecret": "<required>", "sessionMinutes": 60, "maxAttempts": 5, "lockMinutes": 10, "userDataset": "users"}`. User records live in the data store dataset (default `users`), keyed by email:

```json
{ "passwordHash": "$argon2id$...", "roles": "A U", "kind": "user" }
```

`passwordHash` is argon2id (new) or bcrypt `$2...` (verified for migration). `roles` is a space-separated string or array. `kind` is `user` or `agent`.

Auth service endpoints (mounted, conventionally at `/auth`):

- `POST /auth/login` `{email, password}` → 200 `{token, exp}` + `Set-Cookie: rs-auth=...` (HttpOnly, SameSite=Strict). Failures are uniform 401 (no user enumeration); `maxAttempts` failures lock for `lockMinutes` (401 + `Retry-After`).
- `POST /auth/refresh` — with a valid token past 50% of its session, issues a fresh one; earlier, echoes the current token.
- `POST /auth/logout` → 204, clears the cookie.
- `GET /auth/user` → the verified principal `{id, roles, kind, ...extra claims}` (401 if anonymous). Extra claims are the user-record fields named by the tenant's `auth.jwtUserProps` (e.g. `accountId`), copied into the JWT at login — see `services.md` → auth.

Tokens are HS512 JWTs; send via `Authorization: Bearer <token>` or the `rs-auth` cookie. The runtime verifies the token on **every** request when `auth.jwtSecret` is configured; an invalid/expired token is 401 even on open mounts that would accept anonymous callers — strip the bad token instead of retrying.

Role specs (mount `config.access`):

```json
{ "read": "all", "write": "A E", "delete": "A", "invoke": "A E U" }
```

- Method mapping: GET/HEAD/OPTIONS → `read` (default `all`); PUT/PATCH → `write` (default `A`); DELETE → `delete` (default = `write`); POST and other non-idempotent verbs → `invoke` (default = `write`). POST is the *action* verb everywhere (store keyless-create, pipeline run, auth login). `access` may also be the string `"open"` or `"authenticated"`.
- Tokens: `all` (anyone), `authenticated` (any principal), a role name (principal must hold it), or role + path pattern (`"U /user/{email}"` — the role applies only under that path). In the pattern, `{email}` substitutes the principal id and any other `{name}` a string **extra claim** (`jwtUserProps`) — so `"authenticated /{accountId} A"` grants each user their own account's subtree. An unresolved placeholder never matches (fail closed).
- No principal + unsatisfied spec → 401; principal lacking the role → 403.
- Internal calls (pipeline steps, capability grants, guest `fetch`) are **not** trusted for being internal — they carry the originating principal and are authorized like any call, so an anonymous trigger reaches only what an anonymous caller could. To deliberately cross a boundary, use the operator-configured **elevation** gateway (see `pipelines.md`), which *adds* a configured role rather than dropping identity. Runtime-originated **system** calls (scheduler ticks) are trusted. Only **operators** — a principal holding a tenant `operatorRoles` role — may change a mount's or a spec's `access`.

## CORS and browser clients

Per-tenant, host-enforced (tenant config `cors` block; absent = no CORS headers, API-only):

```json
"cors": {
  "trustedOrigins": ["https://app.acme.com", "*.acme.dev"],
  "allowedOrigins": ["https://reader.example"]
}
```

Patterns: full origin (scheme-exact), bare hostname (any scheme/port), `*.suffix` (apex included), `*`. Same-origin requests (Origin host == Host) never involve CORS.

- **Trusted origins**: credentialed CORS (`Access-Control-Allow-Credentials: true`, specific-origin echo) and may send cookie-authenticated unsafe requests. Login from a trusted origin sets the `rs-auth` cookie `SameSite=None; Secure`.
- **Allowed origins**: plain CORS, no credentials — the bearer-token browser-app lane. Login from such an origin sets **no cookie**; the body `token` is the credential.
- Preflights (`OPTIONS` + `Origin` + `Access-Control-Request-Method`) from permitted origins are answered 204 by the host before routing; `Access-Control-Expose-Headers` covers `ETag`, `Location`, `Link`, `X-Total-Count`, `X-Trace-Id`, `Idempotency-Replayed`, `Retry-After`. Error responses are decorated too.
- **CSRF guard** (always on): a cookie-authenticated unsafe request from a cross-site origin not in `trustedOrigins` is rejected 403 before routing. Bearer requests are unaffected.
- `auth.allowedLoginOrigins` (auth settings, optional): when non-empty, cross-origin calls to login/refresh must come from a listed origin (403 otherwise); same-origin always allowed.

## Caching

**Default everywhere: `Cache-Control: no-store`** — errors, discovery docs, preflights, anything that didn't opt in. Any mount opts in with the universal `caching` config key (applies to any service's responses, host-applied only when the response sets no `Cache-Control` of its own, never to error or `Set-Cookie` responses):

```json
"caching": { "mode": "cache",          // noStore (default) | revalidate | cache
             "maxAgeSeconds": 3600, "public": true, "immutable": true }
```

- `revalidate` → `no-cache`: stored but always revalidated — pair with conditional GETs: `file` and `data` answer a matching `If-None-Match` with **304** (no body, ETag echoed), so "always fresh" costs no bandwidth.
- `public` is honored **only on anonymously readable mounts** (`access` absent/`"open"`/`read: "all"`); on authenticated mounts it clamps to `private` + `Vary: Authorization, Cookie` — a shared cache can never serve one principal's response to another.
- The static-site/CDN case: a `file` mount with `{"mode": "cache", "maxAgeSeconds": 86400, "public": true, "immutable": true}`.

## Idempotency keys

Send `Idempotency-Key: <opaque ≤256 chars>` with any request whose duplicate execution would be harmful. Scope: tenant + mount + method + path.

| Situation | Response |
| --- | --- |
| First arrival | Executes; response stored for the replay window (default 24 h; bodies up to 1 MB) |
| Duplicate within window | Stored response replayed with `Idempotency-Replayed: true` |
| Duplicate while original in-flight | 409 + `Retry-After` (no double execution) |
| Same key, different payload | 422 `idempotency_key_reuse` |

Pipelines auto-generate stable keys for their keyed/unsafe steps, so composed effects dedupe across segment retries without caller plumbing.

## Errors

All failures are `application/problem+json`:

```json
{ "type": "https://rs2.dev/errors#<code>", "title": "...", "status": 422,
  "code": "validation_failed", "detail": "...", "tenant": "...", "traceId": "...",
  "retryable": false, "errors": [ { "path": "/total", "error": "..." } ] }
```

| code | status | notes |
| --- | --- | --- |
| `bad_request` | 400 | |
| `path_unsafe` | 400 | rejected by the router for every service |
| `unauthorized` | 401 | missing/invalid credentials; lockout adds `Retry-After` |
| `forbidden` | 403 | principal lacks a required role |
| `capability_denied` | 403 | sandboxed code used an ungranted capability; extra `capability` field |
| `not_found` | 404 | |
| `conflict` | 409 | config version mismatch (`If-Match`), in-flight idempotent duplicate |
| `precondition_failed` | 412 | store `If-Match`/`If-None-Match: *` not met on a write or child delete — re-read and retry |
| `payload_too_large` | 413 | |
| `validation_failed` | 422 | extra `errors` array of `{path, error}` |
| `idempotency_key_reuse` | 422 | same key, different payload |
| `internal` | 500 | |
| `engine_unavailable` | 501 | build lacks the engine for this code type |
| `contract_violation` | 502 | custom service broke the contract (bad output, crash, compile failure) |
| `limit_exceeded` | 503 | retryable; extras `limit`, `observed`, `cap`; `retryAfterMs` set |

Pipeline failures merge a `pipeline` object into the problem body: `{"failedStep": "/2", "steps": [{"step": "/0", "kind": "call", "status": 200}, ...]}` — step keys are index paths into the spec.

`x-trace-id` is echoed as a response header by the server binary; correlate with `traceId` in bodies — and with the `traceId` on log records via a `log` mount (`GET /<logmount>/<traceId>` returns every record for that request; see `services.md`).

## Limits and containment

Per-invocation/per-tenant defaults (operator-configurable): wall clock 30 s (service) / 120 s (pipeline), 128 MB memory, 100 MB materialized body, 64 concurrent invocations per tenant (excess fails fast 503, no queueing), 64 outbound calls per invocation, call depth 16, pipeline fan-out 1000.

The ceilings the answering host actually enforces are published on the discovery surface, so a client never has to assume them — `GET /.well-known/rs2/services` carries a top-level `limits` object (both hosts, same field names; only the values and `host` differ):

```json
"limits": { "wallClockMs": 30000, "memoryBytes": 134217728, "materializedBodyBytes": 104857600,
            "outboundCalls": 64, "maxDepth": 16, "host": "rust" }
```

| Field | Means |
| --- | --- |
| `wallClockMs` | the per-service-invocation wall-clock ceiling (breaches → `limit: "wall_clock_ms"`) |
| `memoryBytes` | the per-invocation memory cap (128 MiB, fixed by the platform on the Cloudflare host) |
| `materializedBodyBytes` | the largest body the host will materialize (100 MB on Rust, 32 MiB on Cloudflare) |
| `outboundCalls` | the outbound-call budget per invocation |
| `maxDepth` | the call-depth ceiling; every internal hop — a pipeline step, a guest's `ctx.request`/`fetch` — counts one |
| `host` | which implementation is answering: `"rust"` or `"cloudflare"` (see "Hosts") |

The numbers above are defaults: an operator sets them per deployment (Rust: `serverConfig.limits`; Cloudflare: the `RS2_LIMITS` var), so read them from discovery rather than assuming. A deployment whose platform enforces a tighter ceiling than RS2's own is expected to lower the matching limit — on Workers Free, for instance, `outboundCalls` goes below the platform's 50-subrequest cap so an overrun is RS2's own `limit_exceeded` rather than a platform error.

Breaches return `limit_exceeded` naming the limit. Repeated resource breaches (default 8 within 10 s) trip a per-tenant circuit breaker: subsequent requests fail fast with `limit: "tenant_breaker"` and `Retry-After` for the cooldown (default 5 s). Admission rejections do not feed the breaker; genuine wall-clock/memory/materialization breaches do.

## Calling from PowerShell

`Invoke-RestMethod` is the reliable JSON client; remember Windows PowerShell 5.1 mangles inline JSON quotes in some contexts — build bodies with `ConvertTo-Json` or here-strings:

```powershell
$token = (Invoke-RestMethod -Method Post -Uri "$base/auth/login" `
  -ContentType "application/json" -Body (@{email="a@b.c"; password=$pw} | ConvertTo-Json)).token
Invoke-RestMethod -Uri "$base/.well-known/rs2/agent-surface" -Headers @{Authorization="Bearer $token"}
```

On 4xx/5xx `Invoke-RestMethod` throws; read the problem body from the exception response stream, or use `curl.exe -s` and parse stdout.
