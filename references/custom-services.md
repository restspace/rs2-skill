# Custom services: writing, validating, deploying, granting

All custom code is untrusted: full sandbox, default-deny capabilities, hard limits. There is no unsandboxed path. Two engines satisfy one contract (the shared conformance suite is the source of truth): V8 isolates for JS bundles, Wasmtime for Wasm components.

## The JS service contract

A deployed bundle is a **single-file ES module** whose default export is the handler (or an object containing it):

```js
export default async (msg, ctx) => {
  const order = ctx.request("orders", { url: `/${msg.url.split("/").pop()}` });
  ctx.log("info", `loaded ${order.status}`);
  return {
    status: 200,
    headers: { "x-source": "my-service" },
    body: { orderStatus: order.body.status },
  };
};
```

- `msg`: `{ method, url (path+query), headers (object), body, mediaType }` — JSON bodies arrive parsed; others as strings.
- Return `{ status?, headers?, body?, mediaType? }`; a string body is `text/plain` (unless `mediaType`), an object body is JSON; returning any non-envelope value makes it a 200 JSON body; `null`/`undefined` → 204.
- `ctx.config` — the mount's config object. `ctx.log(level, text)`. `ctx.state.get(key)` / `ctx.state.put(key, value)` — string state that survives invocations (keyed per service version). **Globals do not survive invocations** (fresh isolate each time).
- `ctx.request(capability, { method?, url, headers?, body?, mediaType? })` — the only way out of the sandbox; synchronous from JS (no await needed, though awaiting works). Returns `{status, headers, body (parsed if JSON), mediaType}`. An ungranted capability throws an Error with `e.code === "capability_denied"`; uncaught, it fails the invocation with that same structured error.
- **`x-rs2-body-ref` response header** (`"<capability>:<path>"`, either engine): return it **instead of a body** and the host resolves a `GET <path>` through that grant *after* the handler returns, attaching the result as the response body — streamed host-side, zero bytes through the sandbox. The hot path for serving cached/derived files from a `store` grant, or passthrough via a `prefix` grant (which keeps the caller's authz). Returning both a body and the header, or referencing a path that doesn't yield a 2xx-with-body, fails the invocation 502 `contract_violation`; an ungranted capability name is `capability_denied`. The header never reaches the client.
- **`x-rs2-base-path` request header**: stamped by the host on every guest invocation with the matched mount prefix (`"/"` for a root mount), so a service can derive its mount-relative sub-path from `msg.url` without hard-coding where it is mounted.

### On the Cloudflare host: the `guest-async` facet

The Worker host (`http-api.md` → "Hosts") runs JS bundles as Cloudflare Dynamic Workers rather than V8 isolates behind a prelude, and declares the difference as the **`guest-async` facet** on every `code:` mount. Write bundles to it and they run unchanged on both hosts:

- **`await` every context call.** `ctx.request(...)`, `ctx.state.get/put`, `ctx.readBody()`, `ctx.body()` and `ctx.beginStream(...).write(...)` are Promises there; on the Rust host they are synchronous, and awaiting a plain value is a no-op — so **an awaiting bundle is portable, one that uses the return value synchronously is not**. `ctx.log` stays synchronous on both. Host errors still arrive as an `Error` carrying `.code`/`.status`, so `e.code === "capability_denied"` holds either way.
- **Timers are real**, not virtual: a `setTimeout` backoff costs actual time and counts against the invocation budget (on Rust, pending timers fast-forward while the handler is idle).
- **Platform globals are not shadowed.** The Worker gives the bundle the platform's own spec-correct `fetch`/`Request`/`Response`/`Headers`/`URL`/`crypto` (with `subtle`)/streams/`Blob`/`FormData`/`WebSocket` etc. — a superset of the prelude, so `ReadableStream` and `WebSocket` are real rather than throwing stubs. Only `Buffer`, `global`, `process` and `RS2Socket` are shim-provided, in the same shapes as the prelude. Don't rely on the extras if the bundle must also run on the Rust host.
- `fetch` is still routed through the mount's `fetch` grant with the same `capability_denied`/allowlist behaviour, and the guest's budgets are CPU-time based (mount config `limits.cpuMs`, e.g. `"config": {"limits": {"cpuMs": 5000}}`; default 5 000, ceiling 30 000) surfacing as `wall_clock_ms` breaches.
- **Wasm components do not run there** — a Wasm bundle is 501 `engine_unavailable`.

### Supported API surface (the compat prelude)

`console.*`, `fetch`/`Headers`/`Request`/`Response` (through the `fetch` grant — see below), `setTimeout`/`clearTimeout`/`setInterval`/`clearInterval` (**virtual time**: pending timers fast-forward when the handler is idle, so retry backoffs cost no wall time), `queueMicrotask`, `structuredClone`, `TextEncoder`/`TextDecoder`, `atob`/`btoa`, `Buffer` (from/alloc/concat/toString utf8|base64|hex), `URL`/`URLSearchParams`, `AbortController`/`AbortSignal` (signals never fire — fetch is synchronous), `crypto.getRandomValues`/`crypto.randomUUID`, `process.{env, nextTick, version (v22.x), platform: "rs2"}`, `Blob`/`File`/`FormData` (text-based), `Event`/`EventTarget`/`CustomEvent`. Presence-only stubs that throw on real use: `WebSocket`, `ReadableStream`.

Not available in v1: real wall-clock timers and event loop, WebSocket connections, binary multipart uploads, `node:` builtins. (Streaming bodies in and out of the sandbox **are** available behind mount flags — see "Streaming bodies" below; the `ReadableStream` global stays a throwing stub, the streaming API is `ctx.readBody`/`ctx.beginStream`.) Validated against the real-SDK corpus: stripe (fetch client), openai, @anthropic-ai/sdk, @octokit/core, @supabase/supabase-js, resend, @google/generative-ai, @mistralai/mistralai, groq-sdk run unmodified after esbuild bundling; @slack/web-api does not (axios/node transport).

Module imports do not resolve at runtime — **bundle dependencies at build time** (`rs2 deploy --bundle` runs `npx esbuild --bundle --format=esm --platform=browser`). Code doing I/O at module top level fails deploy-time validation: do work inside `handle`.

### Streaming bodies (opt-in, JS engine)

By default the request body is materialized before the handler runs, and the response body is whatever the handler returns. Three mount-config flags let large or incremental bodies cross the sandbox without buffering. Each goes in the mount's `config` (alongside `grants`):

- **`"bodyPassthrough": true`** — the handler sees the request body's *metadata* (`msg.bodySize`, `msg.mediaType`) but `msg.body` is `null`; the body is carried past the isolate and, unless the handler returns its own `body`, forwarded unchanged as the response body. For header-rewriting proxies over large uploads/downloads — nothing materializes.
- **`"requestStreaming": true`** — the handler pulls the request body chunk-by-chunk: `ctx.readBody()` returns the next `Uint8Array` (or `null` at EOF), or iterate `for await (const chunk of ctx.body()) { … }`. `msg.body` is `null`; `msg.bodySize` is the declared size when known.
- **`"responseStreaming": true`** — the handler emits the response incrementally: `const w = ctx.beginStream({ status, headers?, mediaType? })` sends the status + headers immediately (the client starts receiving), then `w.write(bytes|string)` pushes each chunk. `write` applies **backpressure** (it blocks when the consumer is behind); the stream ends when the handler returns. If the handler returns a normal envelope without ever calling `beginStream`, it falls back to the buffered path. For SSE, NDJSON, LLM token relays, generated exports.

```json
{ "path": "/sse", "service": "code:ticker@v1",
  "config": { "responseStreaming": true } }
```

```js
export default async (msg, ctx) => {
  const w = ctx.beginStream({ status: 200, mediaType: "text/event-stream" });
  for (let i = 0; i < 10; i++) w.write(`data: ${i}\n\n`);
};
```

Cumulative streamed bytes (in or out) are bounded by the same materialization cap; exceeding it aborts the stream. The handler's wall-clock limit spans the whole stream (backpressure waits count against it). A streamed response is ephemeral — non-cacheable, no ETag. These flags are **JS-engine only**; the Wasm boundary still materializes.

## The Wasm service contract

`rs2 new <name>` scaffolds a Rust component against the published WIT world (`rs2:service@0.1.0`): exports `init(config)` and `handle(message, config) -> result<message, string>`; imports `host.request/log/state-get/state-put`. Build with `cargo build --target wasm32-wasip2 --release`; the scaffold compiles as-is. Bodies materialize at the component boundary in v1 (no streaming through the sandbox).

## Limits inside the sandbox

Wall clock (default 30 s) terminates the invocation (`limit_exceeded`); the memory cap kills allocation bombs the same way (no process impact); outbound calls are budgeted (default 64); body materialization is capped. Repeated breaches trip the tenant's circuit breaker.

## Deploying

```powershell
rs2 deploy service.ts --name my-svc --bundle            # JS: esbuild then upload
rs2 deploy target/wasm32-wasip2/release/my_svc.wasm --name my-svc   # Wasm
# or raw HTTP:
# PUT /services/code/my-svc   (Content-Type: application/javascript | application/wasm)
```

The response gives `ref: "code:my-svc@<version>"` (content-addressed, immutable). Then mount it via the self-config read-modify-write:

```json
{ "path": "/my-svc", "service": "code:my-svc@<version>",
  "config": {
    "grants": {
      "orders": { "prefix": "/data/orders" },
      "fetch":  { "type": "httpOut", "hosts": ["api.stripe.com", "*.example.com"] }
    },
    "access": { "read": "all", "write": "A" }
  } }
```

`rs2 test <projectDir>` validates the manifest and component before deploying; the server also compile-checks at `PUT /code/<name>` (502 `contract_violation` for a broken bundle).

### Declaring a discovery manifest at deploy time

A deployed bundle can carry an **optional manifest** so its mount appears on the discovery surface with a real contract (otherwise a `code:` mount lists as a bare action with no schemas). Send it as the `X-RS2-Manifest` request header (a JSON object) on the deploy `POST /services/code/<name>/` (or `PUT /services/code/<name>/<version>`):

```jsonc
// X-RS2-Manifest: { ... }
{
  "inputSchema":  { "type": "object", "properties": { "q": { "type": "string" } } },
  "outputSchema": { "type": "object" },
  "effect": "idempotent",            // pure | idempotent | unsafe (default unsafe)
  "requestMediaType":  "application/json",   // default application/json
  "responseMediaType": "application/json",
  "storePattern": "store"            // optional — list as an entity, not an action
}
```

The manifest is stored alongside the content-addressed bundle (`.rs2-code/<name>/<version>.manifest.json`); it is metadata about the deployment, not part of the content hash, so the version is unchanged. It surfaces verbatim on `/.well-known/rs2/agent-surface` (the mount lists as an action carrying `inputSchema`/`outputSchema`, or an entity when `storePattern` is `store*`) and on `/.well-known/rs2/openapi` (a path item whose request/response bind the declared schemas and media types). Absent ⇒ no schemas, no regression.

## Catalogues (browse & install from a URL)

Instead of building a bundle locally, a tenant can **install** a published service or adapter from an external catalogue. A tenant registers catalogues in its config (`tenantSchema.catalogues`):

```json
{ "catalogues": [ { "name": "acme", "url": "https://catalogues.acme.com/index.json" } ] }
```

The host only ever fetches from catalogue/bundle hosts the **operator** allowlisted in `serverConfig.catalogueHosts` (`cli.md`) — an SSRF bound; with no allowlist the feature is off. A catalogue URL serves `{ "items": [ … ] }`, each item mirroring a `manifest.json` plus a content-pinned bundle:

```json
{ "name": "stripe-wrapper", "kind": "service",
  "adapterKind": "data",                 // adapters only: data | file | query
  "engine": "js",                        // js | wasm
  "version": "<16-hex content hash>",    // the bundle must hash to this
  "bundleUrl": "https://cdn.acme.com/stripe-wrapper.js",
  "description": "…", "endpoints": [ … ], "capabilities": { … }, "configSchema": { … } }
```

Flow (all on the `services` mount — `services.md`):

- `GET /catalogue/available` — the selectable list: built-in service types + built-in adapters + every registered catalogue's items, each annotated `installed` and a `ref` (`code:<name>@<version>` or `builtin:<name>`).
- `POST /catalogue/install` `{catalogue, name, version}` — the host fetches the bundle (allowlisted host only), **verifies its content hash equals `version`** (so a swapped/compromised mirror is refused), compile-checks, and stores it into `/code/`. Returns `{ref: "code:<name>@<version>"}`.

Install is **deploy only** — it never mounts or grants. Mount the returned `code:` ref (or set it as a `store.adapter`) with `PUT /raw`, supplying the `grants` the item's `capabilities` call for — exactly as for a locally deployed bundle. Re-installing the same version is idempotent.

## Scheduled triggers (polling)

A mount can declare a `schedule`; the host then fires a synthetic **internal** request at it on cadence — the basis for polling connectors (Sheets/Postgres/Slack-Twilio fallback) that wake, fetch changes since a cursor, and act. A schedule is one of three ways to launch a flow — webhook, schedule, or connector all land a **pipeline** (`services.md` → "Triggers: launching a pipeline from an event").

```json
{ "path": "/sheets-sync", "service": "code:sheets@v1",
  "config": {
    "schedule": { "every": "60s" },           // or { "cron": "0 9 * * *" } (5-field, UTC)
    "grants": { "sheets": { "type": "httpOut", "hosts": ["sheets.googleapis.com"] },
                "out": { "prefix": "/data/rows" } } } }
```

- The tick is a **`POST` to the mount root** with header **`x-rs2-trigger: schedule`** and no body — distinguish it from real traffic by that header. It runs as a trusted internal call (passes `access`, no principal), counts against the tenant's concurrency/circuit-breaker, and is logged `rs2.source: "internal"`. A `pipeline` mount can be scheduled too (its `.root` spec runs).
- `every`: `"500ms" | "30s" | "5m" | "2h"`. `cron`: standard 5-field (minute hour day-of-month month day-of-week), evaluated in **UTC**. Exactly one of the two; a bad value is a 400 at `PUT /raw`.
- **State across ticks is the connector's job**: read/write your cursor with the `state-get`/`state-put` host calls (e.g. the last-seen row id / updatedAt), so each run only processes new changes — there is **no catch-up** for missed ticks (a restart resumes from "now").
- **Single-node by default.** The scheduler is in-process; running multiple nodes would double-fire. HA fire-once is a node-config swap (a shared `ScheduleStore`, e.g. Redis), not a code change — see `cli.md`.

## Capability grants (default deny)

A service can reach **only** what its mount grants. Grant kinds, keyed by the capability name the code passes to `ctx.request` (or `"fetch"` for the global `fetch`):

- **`{"prefix": "/data/orders"}`** — internal dispatch scoped under a URL prefix. The guest's request path is appended to the prefix and re-enters full dispatch (authz, limits, idempotency apply). The guest cannot escape the prefix.
- **`{"type": "httpOut", "hosts": ["api.stripe.com", "*.stripe.com"]}`** — outbound HTTP for `fetch`/the named capability. Host allowlist is exact or `*.suffix` (matching the apex too); a disallowed host fails with `capability_denied` **before any I/O**. Requires the deployment to wire an outbound HTTP adapter (the standard server does); otherwise 501.
  - Add **`"inject"`** to attach auth host-side, so the secret never lives in the bundle or config: `"inject": "infra:<name>"` (operator infra supplies strategy + secret) or an inline strategy object whose `secret:<name>` leaves draw on the mount's granted tenant secrets, e.g. `{"auth":"bearer","token":"secret:apiKey"}`. Strategies: `bearer`/`header`/`basic`/`query`/`hmac`/`awsSigV4` (see `services.md` → `proxy`). Applied just before the request leaves the host; the guest never sees the credential. (For a pure forward-with-auth mount with no code, use the `proxy` service instead.)
  - `httpOut` grants are also honored on **`pipeline`/`wrapper` mounts**: a `call` step with an absolute `http(s)://` URL egresses through them, same allowlist and inject semantics (see `pipelines.md` → external calls).
- **`{"type": "socket", "hosts": ["db.internal:5432", "*.upstash.io:6379"]}`** — raw TCP/TLS sockets for non-HTTP wire protocols (Postgres/Mongo/Redis), **JS engine only**. Patterns are `host:port`, host-only (any port), or `*.suffix[:port]` (matching the apex too); a disallowed target fails with `capability_denied` **before connecting**. The guest uses `RS2Socket.connect(host, port, { tls })` → `{ write(bytes|string), read(max?) → Uint8Array|null on EOF, close() }`; calls are synchronous from the guest's view. In a per-invocation service the connection lives for the request; in a **resident data adapter** (below) the runtime is kept alive, so a socket cached in a module-level var pools across requests — on the Rust host. The Cloudflare host scopes I/O objects to the request, so a pooled socket is dead on the next invocation and the adapter must reconnect (see "Loadable adapters on the Cloudflare host").
- **`{"type": "store", "root": "img-cache"}`** — **service-private storage**: a full file-store surface over a private tree (`.rs2-store/<root>`, tenant-scoped), never routed through a mount. Because no dispatch is involved there is **no principal and no access check** — the operator-configured grant *is* the authority — so a service can persist derived/cache/working data even when its own callers are anonymous (a `prefix` grant, by contrast, re-enters dispatch under the caller's identity and needs the target mount to authorize it). The guest speaks the store contract to it via `ctx.request`: `GET`/`HEAD`/`PUT`/`DELETE` on `/{path}`, listings on `/{path}/` (dir+json), keyless `POST /{dir}/`, `If-Match`/`If-None-Match: *` conditional writes (412 on failure), `DELETE /{dir}/?confirm=` for recursive delete; errors come back as status responses (`path_unsafe` for traversal attempts). `root` must be a non-empty relative path; two mounts granting the same root deliberately share the tree. Bodies cross the sandbox boundary raw, so binary content wants the **Wasm engine** (JS bundle bodies are strings).

Rotating code = deploy (new version ref) + update the mount's `service` ref via `PUT /services/raw`. Old versions remain stored and addressable for rollback.

## Selecting a backend: `store.adapter`

A `data`, `query`, or `file` mount's `store.adapter` chooses its storage backend. Two forms, dispatched by prefix (absent ⇒ the node default for that service kind):

- **`builtin:<name>`** — a built-in Rust adapter compiled into the node. Current names: data `builtin:file` (durable, file-backed — **the server's default**) and `builtin:mem` (in-memory, ephemeral — its own scratch store, *not* the default), file `builtin:local`, query `builtin:reference`. No JS engine required; the name must be appropriate to the service kind (a file adapter on a data mount is a config 400). `builtin:file` stores each record as a JSON file under the node's `dataRoot` (`cli.md`), kept separate from `fileRoot` so records aren't browsable through a `file` mount. Since it's the default, a plain `data` mount already persists; name `builtin:mem` explicitly for throwaway/ephemeral data.
- **`code:<name>@<version>`** — a deployed JS loadable adapter (next section).

An unknown built-in name, a wrong-kind name, or a value with neither prefix is rejected at config time (`PUT /services/raw` → 400), not at first request.

## Loadable adapters (bring-your-own backend)

A `data`, `query`, or `file` mount can back its capability with a deployed JS bundle instead of the node's built-in adapter — connect a custom backend (Postgres/Mongo/Redis/S3 over the socket grant) **without recompiling the runtime**. Set the mount's `store.adapter` to a `code:` ref; the bundle is kept **resident** (pooled isolates per mount, evaluated once) so its connections pool across requests:

```json
{ "path": "/data", "service": "data", "config": { "store": {
  "adapter": "code:my-redis@v1",
  "host": "cache.internal", "port": 6379,
  "grants": { "backend": { "type": "socket", "hosts": ["cache.internal:6379"] } }
}}}
```

- **The bundle implements a message surface, not the trait**: it is a normal JS service whose default export handles messages the host sends it. Return `{ status, body }`; the runtime maps responses back.
  - **`data` adapter** — the store pattern: `GET /{dataset}/{key}`, `PUT/DELETE /{dataset}/{key}`, container listings `GET /{dataset}/` and root `GET /`, schema at `/{dataset}/.schema.json`, dataset delete `DELETE /{dataset}/?confirm=`. 201/200 = created/updated, 404 = missing, dir+json listings → keys/datasets. Optional feature handshake: export `const features = ["list-records"]` to take **projected listings natively** — the runtime then forwards `GET /{dataset}/?$select=…&$sort=…&$take=…&$skip=…` and expects `{"entries": [{"name": key, "fields": {…}}], "total": n}` (matching the pinned sort/projection contract in `services.md`); without it, `$select`/`$sort` are never forwarded and the host serves them by walking keys through the adapter's plain surface.
  - **`query` adapter** — a single `POST /query` with body `{query, params, take, skip}`, returning `{rows, total}`. The query service still substitutes JSON templates and validates params **before** calling the adapter, so the bundle receives the resolved query and just executes it (e.g. push it down to the backend). `store.adapter` (the execution backend) and `store.root` (the spec authoring prefix) are independent keys.
  - **`file` adapter** — `HEAD`/`GET`/`PUT`/`DELETE`/`MOVE` on `/{path}`, container listings on `/{path}/`. File **contents cross base64-encoded** (`{contentBase64, mediaType}` on write; the same back on read) since the envelope is JSON. `HEAD` returns `{size, isDir}`; listings return `{entries:[{name,dir,size,contentType}], total}`. The host rebuilds a versioned body so ETags/304 and `Range` (sliced host-side) keep working — large files materialize (a streaming/presigned mode is a future option).
  - **`message` adapter** (a typed *provider* capability, not storage) — `POST /send` with the channel-tagged body (`{channel:"email"|"sms", …}`, exactly what `POST /<mount>/send` accepts) → `{ id }` (201); `GET /status/{id}` → provider-shaped delivery status (200), 404 unknown. Back the mount with `{ "service": "message", "config": { "store": { "adapter": "code:twilio@v1", "channels": ["sms"], "deliveryStatus": true } } }`. Declare `channels` in the store block (default: all) — it is read at build time, so a mis-routed adapter is a config error rather than a first-send failure; set `deliveryStatus: false` if the provider has no per-message status lookup. The bundle maps the canonical request to the provider's API and uses an `httpOut` grant (with `inject`) under `store.grants` for the provider's auth. This is the reference for swapping one external provider for another behind a stable interface — future domains (signing, LLM) follow the same shape.
  - `ctx.config` is the `store` block in every case (read connection params from it) — note the injected credential is **not** in `ctx.config` (it stays host-side).
- **The stock service runs unchanged on top** — for `data`, schema validation / ETags / `.schemas` / PATCH / the store contract stay the host's; for `query`, template substitution / param schemas / pagination stay the host's. The adapter only does the backend I/O.
- **Grants** live under `store.grants` (same kinds as above — typically one `socket` grant). The bundle is loaded lazily on first request from `.rs2-code/<name>/<version>.js`; a `code:` ref that was never deployed → 404. Requires a **JS-engine build** (`--features js`); a non-JS node rejects the mount at config time with 501.
- **Auth caveat**: an adapter speaking a binary wire protocol (e.g. MongoDB via OP_MSG/BSON) works, but handshakes needing HMAC/PBKDF2 (Mongo's SCRAM-SHA-256) aren't possible in-bundle yet — the sandbox `crypto` has no WebCrypto `subtle`. Use an unauthenticated/network-trusted backend, or a protocol whose auth fits the available primitives.
- **Ready-made MongoDB adapters** ship with the runtime source (`guest-adapters/` in the rs2-runtime repo): `mongo-data.js` (a `data` adapter — datasets = collections, keys = string `_id`, schemas in a `__rs2_schemas__` collection; BSON codec covers doubles/strings/docs/arrays/bools/null/int32/int64/UTC-datetime→ISO-string/ObjectId→hex) and `mongo-query.js` (a `query` adapter — stored query shape `{"collection": "...", "pipeline": [...]}`; executes one `aggregate` with an appended `$facet` for rows + total, so `$take`/`$skip`/`X-Total-Count` work in a single round-trip). Deploy each with `rs2 deploy`, then set `store.adapter` to the returned `code:` ref with config `{host, port, db}` and a socket grant. No-auth Mongo only (see the auth caveat below).
- **Pool + lifecycle**: each mount runs a small pool of resident runtimes. It is spawned on first use and grows lazily under concurrent load up to `store.maxRuntimes` (default 4) — each runtime serializes its own jobs, so calls dispatch to the least-busy one and a serial workload stays at a single runtime. A runtime idle longer than `store.idleMs` (or `store.idleSeconds`, default 60 s; `0` disables) is evicted, closing its isolate and pooled connections; the next call re-spawns. A config change (new `code:` ref) rebuilds the tenant, dropping the whole pool.

### Loadable adapters on the Cloudflare host

`store.adapter: "code:<name>@<version>"` works there too — on `data`, `file`, `query` and `message` mounts and on a `specStore` block — with the same `{"type": "socket", "hosts": [...]}` grant in the store block, the same message surfaces, the same error identities, and the same lazy `features` handshake (`listProjection` reads `"fallback"` until the bundle's first use and never forwards `$select`/`$sort` unadvertised, exactly as on Rust). Two things differ, both consequences of the platform:

- **No pool knobs.** One isolate runs per mount and the platform owns eviction, so `store.maxRuntimes`, `store.idleMs` and `store.idleSeconds` are accepted (a config carrying them is still valid) and **ignored**. Don't tune them expecting an effect there.
- **No connection pooling across requests.** I/O objects are request-scoped on Workers: a socket cached in a module-level var dies at the invocation boundary, so a portable adapter must **detect the dead socket and reconnect** rather than assuming its pooled connection survives (the shim fails a cross-invocation socket use deterministically instead of hanging). On the Rust host the resident isolate really does pool the connection for the mount's lifetime and that retry path never runs. The shipped `guest-adapters/mongo-data.js` / `mongo-query.js` bundles await every socket call, serialize exchanges with a module-level lock, and reconnect-and-retry once per command — so they run on both hosts. Write your own the same way.

The 501 `engine_unavailable` for an adapter mount remains there only when the deployment has no Dynamic Worker (`worker_loaders`) binding.

## Ready-made image transform service

`guest-services/image` in the rs2-runtime repo is a deployable Wasm component giving any file mount query-string resize/crop for responsive design: mount `code:image@<version>` with a `source` prefix grant (originals; caller authz preserved) and a `cache` store grant (derivatives). `GET /img/photo.jpg?w=640` — params `w`/`h` (px), `dpr` (1–3), `fit` (`scale-down` default | `contain` | `cover` | `fill`), `g` (cover gravity: compass or `x,y` fractions), `rect=x,y,w,h` (pre-crop), `f` (`auto`|`jpeg`|`png`|`webp`-lossless), `q` (1–100); `?$info` returns `{width,height,mediaType,bytes}`; no params = passthrough; `DELETE /<mount>/.cache?confirm=` purges (guarded by the mount's `delete` access). Unknown params are 400. Derivatives carry a strong ETag keyed on the source ETag + canonical params (304s work; edits auto-invalidate); cache hits and passthrough are served via `x-rs2-body-ref` (no bytes through the sandbox); config `widths: [320, 640, …]` snaps width-only requests up a ladder to bound cache cardinality, `maxSourcePixels` (default 16 MP) guards decode. Build `cargo build --target wasm32-wasip2 --release`, deploy with `rs2 deploy`, add mount `caching` config for Cache-Control. Full config shape: the crate's README.

## Diagnosing a failing custom service

- 502 `contract_violation` with "bundle error: ..." — the module failed to evaluate; the JS exception text is included. Usually a missing global (check the supported-API list) or top-level I/O.
- 502 with "handle rejected: ..." — the handler threw; the rejection text is included.
- 403 `capability_denied` — the grant is missing, misnamed, or the host is not allowlisted; the `capability` field names which.
- 503 `limit_exceeded` (`wall_clock_ms` / `memory_bytes`) — runaway loop or allocation; the isolate was terminated cleanly.
- 501 `engine_unavailable` — the server build lacks the engine for that bundle type, or no HTTP adapter is wired for an `httpOut` grant. On the Cloudflare host it also means a Wasm bundle (never supported there), or an adapter mount on a deployment with no Dynamic Worker binding.
- 404 "deployed code ... not found" — the mount's `code:` ref names a version that was never deployed to this tenant (refs are per-tenant).
