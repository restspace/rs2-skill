# Pipelines: spec, conditions, transforms, retries, segments

## Two input forms, one stored form

The stored format is the **typed spec**. The v1-style terse string DSL is accepted anywhere a spec is (the envelope's `pipeline` field on `PUT /<mount>/.pipelines/<name>`, `rs2 migrate`) and canonicalized on the way in — author in either, read back typed.

The PUT'd document is an **envelope** — `{pipeline, retry?, access?, description?, x-…?}` — and may also carry optional **`input`** / **`output`** JSON Schemas describing the pipeline's request/response shape. These are **advisory** (a pipeline doesn't validate its own body) but are surfaced on discovery: as the action's `inputSchema`/`outputSchema` on `/.well-known/rs2/agent-surface`, and bound to the execute path's request/response on `/.well-known/rs2/openapi` (the `.root` spec governs the mount-root execute path).

Typed spec:

```json
{
  "mode": "serial",
  "onFail": "stop",
  "concurrency": 12,
  "steps": [
    { "call": { "method": "GET", "url": "/data/orders/${id}" }, "as": "$order" },
    { "if": "$order.status == 'open'",
      "call": { "method": "POST", "url": "/payments/charge", "effect": "keyed" },
      "try": true },
    { "transform": { "total": "$sum($order.lines.price)", "charged": "$_ok" } },
    { "pipeline": {
        "mode": "parallel",
        "steps": [
          { "call": { "method": "GET", "url": "/data/customers/${order.customerId}" }, "name": "customer" },
          { "call": { "method": "GET", "url": "/stock/check" }, "name": "stock" }
        ],
        "join": "jsonObject" } }
  ]
}
```

Equivalent DSL (array form):

```json
[
  "GET /data/orders/${id} :$order",
  "try if ($order.status == 'open') POST /payments/charge",
  { "total": "$sum($order.lines.price)", "charged": "$_ok" },
  [ "parallel",
    "GET /data/customers/${order.customerId} :customer",
    "GET /stock/check :stock",
    "jsonObject" ]
]
```

DSL element kinds: a leading mode token (`"serial"`, `"parallel"`, `"conditional"`, `"tee"`, `"teeWait"`, optionally with fail/succeed actions: `"serial stop end"`); step strings `try? if (cond)? METHOD url ( :$var | :name)?`; JSON objects = transforms; nested arrays = subpipelines; `"jsonSplit"` = splitter; `"jsonObject"` = joiner. `zip`/`unzip`/`multipart` are not supported in RS2 v1.

## Step semantics

Exactly one of `call` / `transform` / `pipeline` / `split` per step, plus optional `if`, `try`, `as`, `name`, `retry`, `elevate`.

- **call** — the in-flight message is sent to the (interpolated) URL through full dispatch: authz, limits, idempotency all apply to internal calls — **the call is authorized as the original caller** (their principal is forwarded). GET/HEAD send no body; other methods forward the in-flight body. The response becomes the in-flight message.
- **External calls** — an absolute `http(s)://` call URL **leaves the node** through the mount's `httpOut` grants (same vocabulary as code mounts, declared on the pipeline/wrapper mount config): `"grants": {"stripe": {"type": "httpOut", "hosts": ["api.stripe.com"], "inject": "infra:stripe-key"}}`. The host allowlist (exact or `*.suffix`, apex-inclusive) is checked after interpolation and **before any I/O** — no matching grant (or no grants at all) is a 403 `capability_denied`; no outbound adapter on the node is a 501. The matching grant's `inject` credential is applied host-side (first matching grant in grant-name order wins); the external request is **built fresh** — only the step's declared `headers` plus the auto idempotency key go out, never the caller's `Authorization`/`Cookie` or principal, and `elevate` is inert. Header values `${...}`-interpolate like the URL (`"authorization": "Bearer ${conn.accessToken}"` with `$conn` captured earlier) — resolved once before the retry loop, so every attempt sends identical headers; an unresolvable placeholder or invalid resolved value fails the step with a 400 **before any I/O** (never a silently missing header), and header names/patterns are validated when the spec is stored. Standard headers are defaulted when the spec doesn't set them: `Content-Type` from the outgoing body's media type (so a `$response`-shaped or forwarded body isn't sent untyped), `Accept: */*`, and `User-Agent: rs2/<version>`; declared headers always win, and `Host`/`Content-Length` come from the transport. Retry policy applies unchanged (statuses, `retryOnNetworkError`, backoff, `Retry-After`); a keyed external POST sends its stable auto-derived `Idempotency-Key` to the provider. `?$plan` warns about literal external hosts no grant covers.
- **`elevate: true`** (DSL: a leading `elevate` token, e.g. `"elevate GET /secret/${id}"`) — **add the pipeline mount's operator-configured `elevate` role** to this call's principal, so it can reach a mount that grants that role while keeping the caller's identity (an anonymous caller gets a synthetic principal carrying just that role — the login gateway). This is the **gateway pattern** — lock a service (e.g. `"access": {"read": "svc"}`), set `"elevate": "svc"` on a caller-accessible pipeline mount, and a step that elevates gives non-`svc` callers *mediated* access (the pipeline can validate/transform/restrict). Authority is the mount config, never the flag: without a configured `elevate` role the flag is inert, and the role may **not** be an operator role. Guard the `.pipelines/` authoring surface with `write`; a spec's inline `access` is operator-only. Applies to `call` steps only.
- **`as: "$var"`** — capture the call/transform result into a variable instead (converted by media type, as for a transform input); the in-flight message keeps its prior body and a failed captured call becomes `{"_errorStatus", "_errorMessage"}` in the variable while the pipeline continues.
- **`try: true`** — a failure becomes the body `{"_errorStatus", "_errorMessage"}` with status 200, and the pipeline continues.
- **transform** — JSONata over the body. Template object → evaluate each string leaf as an expression (recursively; non-string scalars pass through); bare string template → whole-body expression. Variables: `$name` (captures), `$_status`, `$_ok`, `$_headers`, `$_rawBody`; `$_user` / `$principal` (the original caller: `{email, roles, ...extra JWT claims}` — e.g. `$_user.accountId` with `jwtUserProps`; **unbound for anonymous callers**, so guard with `$exists`); `$_url` (the triggering request: `$_url.path` = array of segments beyond the mount, `$_url.query.<k>`). The body is the JSONata input (`$`), **converted by media type** (as v1 did): a JSON body parses to a value, a text body (`text/*`, `application/xml`, `application/xhtml+xml`, `application/javascript`, `application/typescript`) arrives as a string, and anything else arrives as a standard base64 string — so transforming an HTML, CSV or binary body is normal, not an error. The one media-type failure left is a body typed `application/json` that does not parse: that stays a 400. The same conversion applies wherever a body becomes a value: `as:` captures (a text response captures as its string, not `null`), `jsonObject` joins, and the request/response bodies a code service sees. **Host functions** beyond stock JSONata: `$hmac(algo, key, msg)` → hex MAC and `$hmacVerify(algo, key, msg, sigHex)` → bool (`sha256`/`sha512`; constant-time; webhook gating — see `services.md`); `$hashPassword(password)` → argon2id PHC string (the scheme `auth` mints, so a provisioning pipeline can seed a user record that logs in unchanged) and `$verifyPassword(password, hash)` → bool (argon2id or legacy bcrypt). All fail closed (`""`/`false`) on bad input. Every string leaf is **parse-checked when the spec is stored** — an unparseable expression anywhere in the template (including steps behind an untaken `if` and nested subpipelines) fails the PUT with a 422 `validation_failed` instead of surfacing as a runtime 400. Parse-only: semantic errors (an unbound variable, a misspelled function) still surface at evaluation.
- **pipeline** — nested spec; its `end`/`stop` are local to it. `mode: "tee"` runs the branch fire-and-forget over a copy (original continues immediately); `"teeWait"` completes the branch first, discarding its result.
- **split** (`jsonSplit`) — array/object body → one message per element; the **remaining steps** of the pipeline run per element in parallel (fan-out cap 1000, concurrency default 12), then results join (`jsonObject` keyed by element name/index, errors as `{"_errorStatus", ...}`).
- **parallel mode** — every step runs concurrently over a copy of the input; results join into one object keyed by each step's `name` (or index). Each branch holds a full copy of the input body, so a wide fan-out over a large body is bounded by an aggregate footprint cap (branch count × body bytes, default 256 MB) — exceeding it is a 503 `limit_exceeded` (`pipeline_fanout_bytes`).
- **conditional mode** — the first step whose `if` passes runs and its result ends the pipeline; no match passes the message through.
- **`${...}` interpolation** in step URLs and call `headers` values has two planes. **Data plane**: variables, then input-body JSON fields, then query params; dot-paths allowed (`${order.customerId}`). **URL plane** (reserved `url` root): the incoming request's path/query, indexing the *peeled* sub-path (segments beyond the matched spec prefix; for `.root`, the whole sub-path) — `${url.path[0]}`, `${url.path[-1]}`, `${url.path[1:]}` (Python-style slices, `/`-joined), `${url.path}`, `${url.base[0]}`, `${url.full}`, `${url.name}`, `${url.query.id}`, `${url.query}`. `${url.rest}` is the **byte-exact** service-path remainder (leading slash, exact trailing slash; mount root → `/`) — unlike segment-joined `${url.path}` it preserves the path verbatim, so `/wrapped${url.rest}` transparently forwards the path beyond the mount (see the `wrapper` service in `services.md`). Mark a selector optional with `?` (elides, collapsing a neighbouring `/`) or give a default with `|| 'x'`; otherwise an unresolvable placeholder is a 400 (and a malformed pattern is rejected when the spec is stored). This is what lets a `.root` pipeline transparently wrap a store: `GET /data/users/${url.path[0]}` / `PUT /data/users/${url.path[0]}`. A data field named `url` is shadowed by the URL root.

Fail actions (`onFail`, default `next`; parallel forces `stop`): `stop` aborts with the failing message; `next` continues with it; `end` exits the pipeline with it. `onSucceed: "end"` exits after the first success.

## Response shaping (`$response`)

A (non-captured) transform whose output is an object with the **single key `$response`** shapes the response instead of becoming the body:

```json
{ "$response": { "status": 201, "headers": { "Location": "/things/1" },
                 "mediaType": "text/html", "body": "<p>made</p>" } }
```

All fields optional. `status` replaces the transform default of 200; a **string `body` becomes the raw text body** (default `text/plain` — v1's `to-text`), other JSON stays JSON; `mediaType` retypes the body (with no `body`, retypes the existing one); `headers` set response headers. Omitted `body` keeps the pre-transform body (v1's `set-status`). Invalid directives (bad status, non-scalar header) are 400s. A **captured** (`as:`) envelope is plain data — capture stays orthogonal to shaping. Error shaping stays with `$error('msg')` (a 400).

The caller/URL vars also interpolate in step URLs: `GET /dbdata/location/${_user.accountId}_${locationId}` — data-plane variables like any capture.

## Conditions (`if`)

A small checked grammar — not JavaScript. Parse errors surface at config time.

- Builtins: `status`, `ok`, `method`, `mime`, `isJson`, `isText`, `isBinary`, `name`, `isDirectory`
- `header("x-thing")`; variables `$var.path.to.field`
- Literals: `'strings'`, numbers, `true`/`false`/`null`
- Operators: `== != < > <= >=`, `&& || !`, parentheses. Numeric equality is by value.

Example: `(header("x-mode") == 'manage') && status < 300 && $order.total > 100`

## Retry policies and effect classes

Effect classes govern what may auto-retry: `pure` (GET/HEAD/OPTIONS default), `idempotent` (PUT/DELETE default), `keyed` (retry only with an idempotency key — pipelines auto-derive stable per-step keys), `unsafe` (POST/PATCH default; never auto-retried). Declare on a call: `"call": {..., "effect": "keyed"}`.

Policy shape (camelCase), resolved per-call `retry` → mount `retry` → tenant `retry` → runtime default (no retry):

```json
{ "enabled": true, "maxAttempts": 4, "baseDelayMs": 250, "maxDelayMs": 5000,
  "backoffMultiplier": 2, "jitter": "full",
  "retryStatuses": [408, 429, 500, 502, 503, 504],
  "retryOnNetworkError": true, "respectRetryAfter": true }
```

Unlike v1 there is no `$_retry` pipeline variable — retry is declarative on the step (`"retry": {...}`), the mount, or the tenant.

## Segments (why `?$plan` matters)

The executor partitions a serial pipeline into segments at materialization points (transforms and splits force boundaries). The **segment is the atomic retry unit**: a retryable failure mid-segment re-runs the whole segment from its materialized input. Keyed/unsafe calls inside a segment get auto-derived idempotency keys that are stable across attempts, so effects do not duplicate.

`GET <mount>/.pipelines/<spec>?$plan` shows `{segments: [{start, end, checkpointEligible}], warnings}`. A warning like *"unsafe-effect step is not the last in its segment"* means a segment retry would re-execute that step: mark it `"effect": "keyed"`, move it to a segment end (e.g. put a transform before it), or accept the duplication risk knowingly. *"external host '…' is not covered by any httpOut grant"* means a literal absolute call URL would be 403'd at execution — add a matching `httpOut` grant to the mount (interpolated hosts can't be checked statically).

Large/unknown-size streaming bodies are not snapshotted (default threshold 1 MB): such a segment runs at most once — streaming is preserved at the cost of that segment's retryability.

## Triggered by a socket message (Cloudflare host only)

A pipeline mount with `"webSocket": true` in its config (see `services.md`
→ "WebSocket-enabled mounts") runs its pipeline **per inbound socket
message**, not just per HTTP request: the frame arrives as the in-flight
message body (JSON or text per the mount's `text` config), the pipeline's
result is sent back as the reply frame, and a `204`/no body means no reply
is sent. This is the same execution model as a webhook or scheduled
trigger — an event lands as a request and the pipeline processes it — just
with the socket connection as the event source instead of an inbound POST
or a timer.

By default only `message` events reach the pipeline. Opt a `pipeline` mount
into `open`/`close` events too with `"webSocket": {"events": ["open",
"message", "close"]}`; the three are distinguishable by the
`x-rs2-socket-event` header on the synthetic request, testable in a step's
`if` with the ordinary `header()` builtin:

```json
{ "if": "header(\"x-rs2-socket-event\") == 'open'",
  "call": { "method": "PUT", "url": "/data/presence/${url.query.id}" } }
```

**Sending from a pipeline.** A pipeline anywhere in the tenant — not just the
one attached to the socket — can push a frame to connected sockets with an
ordinary `call` step against the target mount's `.sockets/` subtree:

```json
{ "call": { "method": "POST", "url": "/chat/.sockets/room/${roomId}/" } }
```

The call carries the in-flight body as the frame and needs `write` role on
that mount (or `elevate`, same as any other internal call — see "elevate"
above) since it's an ordinary internal dispatch, not a special socket op.

## Debugging a pipeline

1. `GET <mount>/.pipelines/<spec>?$plan` — confirm the stored typed form is what you meant (especially after DSL input) and check the warnings.
2. Run with `?$to-step=0`, `1`, … to bisect.
3. On failure, the problem body's `pipeline.steps` lists each executed step's status; `failedStep` is the index path (`"/2"`, nested `"/3/steps..."` paths appear for subpipelines).
4. Remember conditions skip silently — a step that "didn't run" usually has a false `if` or sits after an `end`.
