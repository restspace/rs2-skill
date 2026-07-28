# Prebuilt services

Host-native services cover storage, composition, queries, identity, and management. A mount is `{"path": "/prefix", "service": "<name>", "config": {...}}` in the tenant config. Standard config keys on any mount: `access` (role spec), `retry` (policy, see `pipelines.md`), `caching` (universal cache headers — see `http-api.md`; default is `no-store` everywhere), and the agent-surface metadata keys `x-agent`, `x-policy`, `x-expose`, `x-render`, `x-context`, `description`. A mount's `access` can be edited in place over HTTP with `rs2 service set-access <path> --access <json>` (not only by hand-editing `tenants/<name>.json`) — handy for tightening an open bootstrap mount; see `cli.md`.

## Agent-surface metadata (set these by default)

The discovery surface has two layers. The **structural** fields — `kind` (`entity` for a data mount, `action` for a pipeline spec, `query` for a query spec), `effect`, `pattern`, `facets`, `params`/`inputSchema`/`outputSchema`, `idempotency` — are **auto-derived** by the runtime from the mount and stored spec; you do not (and cannot) set them by hand. What you add is the **advisory** layer: six optional keys the host copies *verbatim* onto `GET /.well-known/rs2/services`, the `OPTIONS` descriptor, and `GET /.well-known/rs2/agent-surface`. The runtime does not constrain their shape (only `x-expose` is parsed); they are signal for agents and UIs.

**Default practice: set `description` on every mount and stored spec you create, and the others where they add signal.** A mount with no `description` is opaque on the agent surface — fix that by default.

- `description` — one-line human/agent summary of what this mount or spec is for. **Always set it.**
- `x-agent` — advisory hints for how an agent should treat the mount/action, merged onto the auto-derived entry as a nested object, e.g. `{"kind": "action", "safe": true}`. On a pipeline, set `safe` from the spec's effect class (`pure`/`idempotent`/`keyed` → `true`; `unsafe` → `false`) so an agent knows what it may retry. (`kind`/`effect` are still auto-derived at the top level; `x-agent` only annotates.)
- `x-expose` — restricts which surfaces include this mount's entry under `?surface=<name>`: a string or array of surface names (`"mcp"`, `"ui"`, `"cli"`). **Absent = every surface.** Filtering applies to **`GET /.well-known/rs2/agent-surface` and `GET /.well-known/rs2/services`** alike (`OPTIONS` is *not* filtered); on the services catalogue the `control` block derives from the same filtered list, so a `services` mount scoped off a surface takes its control entries with it. On the **agent surface** it reaches only mounts that appear there at all — data mounts (`entity`), pipeline specs (`action`), and query specs (`query`); **file mounts never appear on the agent surface**, so `x-expose` on a `file` mount is inert *there* (it still prunes the file mount from a filtered `/services` catalogue). Use it e.g. to limit an internal action to `["mcp","cli"]` (off the `ui` surface), a query to `["mcp"]`, or `[]` to hide a machine-written mount (such as a publish target) from every named surface while leaving it directly addressable.
- `x-policy`, `x-render`, `x-context` — free-form passthrough objects, opaque to the runtime, for caller-defined policy / rendering / context hints. A good place to record intent the structural surface can't express (e.g. an access note on a write-only public mount).

Placement: on a **pipeline/query/template**, these go in the **stored spec envelope** alongside `pipeline`/`query`/`source` (for pipelines, `x-agent`/`x-policy`/`description` are the ones surfaced on the action). On every other mount they go in the mount **`config`**. Remember the surface is **permission-filtered**: a mount the caller can't read is omitted entirely (and file mounts are never `entity`s), so metadata only shows where the mount is already visible.

## The store pattern (one client codepath for every store)

Every mount declares a `pattern` on the discovery surface (`store`, `store-view`, `transform`, `api`) — the conversation shape, so polymorphic clients drive all mounts sharing a pattern with one codepath. `file` and `data` are both **stores** and obey one normative contract (enforced by the runtime's store-conformance suite; future S3/SQL/custom stores join by passing it):

| Request | Behavior (identical on every store) |
| --- | --- |
| `GET <container>/` (trailing slash; works at every level incl. the mount root) | Listing `application/vnd.rs2.dir+json`: `{path, entries: [{name, dir, size?, lastModified?, contentType?}], total}` + `X-Total-Count`; paginate `$take` (default 1000, max 10000) / `$skip`; sub-containers have `dir: true`. File entries carry `contentType` (the media type) so a client can pick an icon/editor without a `HEAD`; data record entries are `application/json` |
| `GET <child>` | The resource, with a version `ETag` |
| `PUT <child>` | Upsert: 201 created / 200 overwritten, empty body, `ETag`. Send `If-Match: <etag>` for optimistic concurrency (mismatch → **412**), or `If-None-Match: *` for create-only (exists → **412**) |
| `POST <container>/` | Keyless create under a server-generated name → 201 + `Location` |
| `POST <child>` | Upsert and return the stored representation (stores with the `echo` facet) |
| `DELETE <child>` | 204 |
| `DELETE <container>/` | 204 if empty/unguarded; non-empty → **409**; retry with `?confirm=<container name>` → 204 |

The generic client loop: walk containers by trailing-slash GETs, recurse on `dir: true`, read/write children, and on a 409 container delete retry with `?confirm=`. Real differences are **facets** declared next to the pattern (`/.well-known/rs2/services` → `{"pattern": "store", "facets": [...]}`) — feature-detect, never special-case the service name. Every store declares the `conditional-write` facet: it honours `If-Match`/`If-None-Match: *` on writes (server-side, so it's race-free where the adapter has atomic compare-and-swap and best-effort otherwise — the client behaviour, send the header and handle 412, is identical either way). The generated OpenAPI expresses this structurally: all store paths `$ref` the same `#/components/pathItems/StoreContainer|StoreChild` shapes.

## file — streamed file storage (`store`; facets: `range`, `confirm-delete`, `move`, `meta-sort`, + `static-site` when configured)

**Metadata sort** (`meta-sort` facet — also on every spec store's authoring subtree): directory listings accept `$sort` over `@`-prefixed listing metadata, no content reads: `GET <dir>/?$sort=-@lastModified&$take=25` (keys: `@name`, `@size`, `@lastModified`, `@contentType`, `@dir`; `-` = descending, comma-separated multi-key; entry name breaks ties; missing values sort first ascending; page is cut after the sort, `total`/`X-Total-Count` stay the full count; unknown or unprefixed keys → 400). `-@lastModified` gives "recently modified first" over any folder.

Beyond the store contract: single `Range:` on GET → 206 (`Accept-Ranges`); `Last-Modified`; `HEAD` for metadata headers. A GET/HEAD whose path names a directory **without** the trailing slash answers **301** to the slash form (query preserved, `DirectorySlash` style — relative URLs in a served default doc need the slash form); what the slash form yields (default doc, listing, or 404) follows the rules below. Writes stream end-to-end (no materialization), atomically (temp + rename). Keyless POST names the file `<uuid><ext>` with the extension inferred from the request `Content-Type`. Media types come from the extension map, never sniffed; unknown → `application/octet-stream`. Storage is host-scoped per tenant.

**Per-mount storage isolation.** A `file` mount with **no** `store` block shares the node default file store (the `fileRoot`). To give a mount its own physical subtree, select the built-in local backend and **name a root**: `{"store": {"adapter": "builtin:local", "root": ".rs2-html"}}`. The `root` is **required** for an explicit `builtin:local` store (a missing/empty root, or one with `..`/an absolute path/a drive letter, is a 400 at `PUT /raw`) — otherwise two `file` mounts would collide on identical keys like `index.html`. Omit the `store` block entirely only when you actually want the shared default.

**Move/rename** (`move` facet): `MOVE <child>` with a `Destination` header carrying the target path (addressed within the same mount; cross-mount moves aren't supported) → 201 created / 200 overwritten, with `Location`. Source must be a file (not a directory); a missing source → 404, a directory destination → 409.

Note: deployed custom-service bundles live in the same tenant file store under `.rs2-code/<name>/<version>.{wasm,js}` — visible through a file mount, harmless, do not delete casually.

**Static-site mode** (no separate service — config on the file mount; declares the `static-site` facet on discovery):

```json
{ "service": "file", "spaFallback": true, "listings": false,
  "caching": { "mode": "cache", "maxAgeSeconds": 300, "public": true } }
```

- `defaultResource` — directory GETs serve this file from that directory instead of a listing (defaults to `index.html` when `spaFallback` is on; set it alone for classic default-document hosting). The default doc shadows the listing, so to enumerate files (tooling, discovery) send `Accept: application/vnd.rs2.dir+json` — that explicitly-named type (a wildcard `*/*` does **not** count, so browsers still get the doc) flips the same directory URL to the `dir+json` listing. Responses carry `Vary: Accept`. `listings: false` still wins: an explicit listing request there is a 404, never a leak.
- `spaFallback: true` — extension-less misses (client-side routes like `/users/42/profile`) serve the mount-root default resource with 200; misses **with** an extension (`/missing.js`) stay 404. A directory miss below the root also falls back to the root app shell.
- `listings: false` — suppresses dir+json listings (404), so a public site isn't browsable. Default `true`.
- `friendlyUrls: true` — serve any stored file at its path without the type suffix (`GET /docs/readme` → `docs/readme.md`), returning 200 with a `Content-Location` to the real path. Exact matches always win; on a stem collision (`page.md` and `page.html`) the variant is chosen by the request `Accept` header, falling back to the `extensionPriority` order. Probes by name, so it works with `listings: false`; tried before `spaFallback`. Default `false`.
- `extensionPriority: ["html", "md", …]` — preference order (extensions without dots) for friendly URLs. Its first entry is the **canonical slot**: with `friendlyUrls` on, `PUT /docs/readme` (extension-less) pins to `readme.html` **regardless of Content-Type**, so a no-`Accept` GET of `/docs/readme` always returns that write and no later sibling (`PUT readme.md`) can dislodge it. The PUT replies `Location: /docs/readme` + `Content-Location: /docs/readme.html`; `/docs/readme` and `/docs/readme.html` are one resource (`DELETE /docs/readme` removes the pinned file). An extension-less PUT with `friendlyUrls` on but no `extensionPriority` is a **400**. With `friendlyUrls` off, extension-less slugs are stored verbatim.

Typical setup: open `access` for GET, `caching` mode `cache` + `public` (the host clamps `public` to `private` automatically if the mount isn't openly readable). Content deploys are just store writes — `PUT /site/index.html`, etc.

## data — schema-validated JSON store (`store`; facets: `schema`, `patch`, `echo`, `confirm-delete`, `list-projection`)

Containers are datasets: the mount root lists datasets (`dir: true`); `GET /<dataset>/` lists record keys, plus `.schema.json` as a fixed child when a schema is installed. Config `{"enforceSchema": true}` validates writes — and PATCH results — against the dataset schema (422 `validation_failed` with an `errors` array).

**Default to installing a `.schema.json` for every dataset you create** (`PUT /<dataset>/.schema.json`, JSON Schema) and set `{"enforceSchema": true}` on the mount. The schema validates writes and PATCH results, and — installed or not for enforcement — publishes the dataset's shape on the agent surface and generated OpenAPI so clients and agents can discover it. Skip it only for deliberately free-form datasets, or when you genuinely cannot write one yet (e.g. an auth-less node where `.schema.json` writes need a role you can't obtain — add the schema once auth exists). Note both pieces are needed to *enforce*: a schema with no `enforceSchema` only documents; `enforceSchema` with no installed schema validates nothing.

**Field-level authz.** Config `{"fieldLevelAuthz": true}` makes the service honor per-field rules in the schema: a property's `x-rs-read` / `x-rs-write` (role specs, same grammar as mount `access`) restrict that field. Reads **redact** fields the caller can't read (ETag stays over the stored record); writes that **change** a field the caller can read but can't write return **403**; fields the caller can't read are preserved from the stored record (so read→edit→PATCH-back never drops them — PATCH is the natural edit path). Because the schema carries the policy, editing `.schema.json` on such a mount requires a tenant **operator**. This realizes role-assignment gating: annotate the `users` dataset's `roles` field `x-rs-write: "<operator role>"` so users can edit their own record but not self-promote. Top-level fields only; `query`-mount reads bypass field redaction.

**Editor/authoring annotations.** A schema may also carry advisory `x-…` keys that drive a generic editing client (validators pass them through; the runtime never reads them — feature-detect on the schema, never on a service name): field-level `format: "markdown"` (markdown editor shortcut) and `x-editor` (force a field editor by key, e.g. `"markdown"` | `"image"`); `x-media-mount` (field-level, implies the image picker, or schema-root as the form default: the file mount an image field browses/uploads into, e.g. `"/media"`); schema-root `x-preview` mapping a record to its rendered page for live preview — either a path template string (`"/site/{slug}"`, `{field}` tokens from top-level fields, GET, reflects last-saved state) or `{"path": ..., "method": "POST", "body": "self"}` to POST the live record for an unsaved-edits preview (`method` defaults to GET).

**Draft/publish (`x-publish`).** RS2 keeps no revision history — a record's version is its ETag. A preview/publish distinction is instead **two mounts of the same shape**: a draft store the editor writes, and a live twin the public site reads. Schema-root `x-publish` names the pair: `{"target": "/content-live", "via": "/publish"}` — `target` is the live twin (give it `"x-expose": []` so it isn't a second collection), `via` the publish endpoint, where `POST <via>/<dataset>/<key>` publishes and `DELETE` unpublishes (draft survives). **Publish state is derived, not stored:** a data ETag is a content hash, so live `404` = draft, ETags equal = published, ETags differ = unpublished edits pending. Do not add a `status` field — the comparison can't disagree with the content. `x-preview` resolves against the draft mount; the public site reads `target`. Wire the twin's `access` to `{"write": "<publisher role>"}` and make `via` a `wrapper` mount with `elevate: "<publisher role>"` and steps `GET /content${url.rest}` → `PUT /content-live${url.rest}` (`elevate: true`), so editors publish without holding write on live. **Gotcha:** open `delete` as well as `invoke` on the publish mount — access is gated by verb, and `DELETE` maps to `delete`, which defaults to `write`; with only `invoke` opened every unpublish is a 401. The twin needs no `.schema.json` (the draft already validated).

Beyond the store contract:

| Request | Behavior |
| --- | --- |
| `GET /<dataset>/<key>` | Record; `Content-Type: application/json; schema="<base>/<dataset>/.schema.json"` + `Link: ...; rel="describedby"` when a schema exists |
| `PATCH /<dataset>/<key>` | RFC 7386 JSON merge patch; merged result re-validated; returns the result |
| `GET` / `PUT /<dataset>/.schema.json` | Read/install the dataset schema (`application/schema+json`); PUT compile-checks first |
| `GET /.schemas` | Mount-level schema index: `{schemas: {<dataset>: {schemaUrl, schema}}}` for every dataset with an installed schema — discover all shapes in one call |
| `GET /<dataset>/?$select=title,meta.date` | **Projected listing** (`list-projection` facet): each entry gains a `fields` object holding the selected dot-path values (nested shape preserved; absent paths omitted; the `.schema.json` fixed entry is excluded). Add `$sort=-meta.date,title` (`-` = descending) to field-sort; `$sort` without `$select` is a 400. `$take`/`$skip` page **after** the sort; `total`/`X-Total-Count` stay the full count. Field-level `x-rs-read` rules redact projected fields exactly as record GETs. Built for record tables (admin/CMS UIs) in one round trip |
| `DELETE /<dataset>/?confirm=<dataset>` | Dataset delete always requires the confirm token (409 without) |

Projected-listing sort order is pinned and backend-independent: strings compare by **binary UTF-8 code points** (case-sensitive, no locale — `"Zebra"` < `"apple"`); cross-type order missing < null < false < true < numbers < strings < arrays < objects; record key is the final tiebreak. Contractual for homogeneous scalar fields — for human alphabetization, materialize a sort-key field (e.g. lowercased title) at write time and sort on that. The mount's services-doc entry carries `listProjection: "native" | "fallback"` — native pushes projection/sort down to the backing engine; fallback is a host key-walk that reads the **whole dataset** under a `$sort` (only the page without one).

Record `ETag`s are content hashes. Stores cannot filter by field — listings project and sort, they don't query; use a `query` mount (or a pipeline) to select records by content.

A `data` mount can back its persistence with a deployed JS adapter bundle instead of the built-in store — `{"store": {"adapter": "code:my-redis@v1", ...}}` connects a custom backend (Redis/Mongo/Postgres) kept resident with pooled connections. Everything above (schema, ETags, store contract) stays the host's. See `custom-services.md` → "Loadable data adapters".

**Per-mount storage isolation.** A `data` mount with **no** `store` block shares the node default data store (the file-backed `dataRoot`) — the same store `auth` reads its `users` dataset from. To give a mount its own physical store, select the built-in file backend and **name a root**: `{"store": {"adapter": "builtin:file", "root": ".rs2-signups"}}`. The `root` is **required** for an explicit `builtin:file` store (a missing/empty root, or one with `..`/an absolute path/a drive letter, is a 400 at `PUT /raw`). This matters for security: a low-privilege, public-write mount (e.g. `{"access": {"invoke": "all"}}`) **must** set its own `root`, or a forged record (`{passwordHash, roles: "A", kind: "user"}`) posted to it would land in the shared store `auth` trusts — an auth bypass. `{"store": {"adapter": "builtin:mem"}}` is a single **shared** in-memory store (ephemeral, ignores `root`): use it for throwaway data, not for isolation.

## pipeline — a pipeline store (`store-transform`; facets: `any-verb`, `meta-sort`)

Pipelines are **authored like files** under the reserved subtree `/<mount>/.pipelines/…` (full store contract: PUT/GET/DELETE, listings, ETags, keyless POST, `?confirm=` guard — guard authoring with `write`). A spec's optional inline `access` (`read`/`write`/`delete`/`invoke`) gates its execution per-path (overriding the mount floor) and is **operator-only** to set. The stored document is an envelope, validated and canonicalized (string DSL → typed spec) at write time:

```json
{ "pipeline": <typed spec | string-DSL array>,
  "retry"?: <policy>, "description"?: "...", "x-agent"?: {...} }
```

**Execution owns everything else, on every HTTP verb**: the request's path resolves longest-prefix against the stored specs, and the matched pipeline processes the request with verb and URL intact — so a pipeline can transparently wrap another service (custom security context, unchanged API). A spec named **`.root`** governs the mount root and all otherwise-unmatched subpaths (wrap-the-whole-mount). No match and no `.root` → 404 pointing at `.pipelines/`. The peeled sub-path (segments beyond the matched spec prefix) is addressable in call URLs via the `${url.path[…]}` plane (like the positionals `query`/`template` expose), so a `.root` spec can forward the addressed key: `GET /data/users/${url.path[0]}` (see `pipelines.md` → interpolation).

- `GET /<mount>/.pipelines/<spec>?$plan` → `{pipeline, plan: {segments, warnings}}` — retry/checkpoint boundaries; warnings flag `unsafe` steps mid-segment and literal external hosts no `httpOut` grant covers.
- `?$to-step=N` on an execution request runs only through top-level step N (debugging).
- Retry resolution: envelope `retry` → mount `retry` → tenant default.
- Failures carry `pipeline.failedStep` + per-step statuses in the problem body.
- Mount config: optional `retry`, metadata keys, `"grants"` (`httpOut` grants enabling **external `call` steps** — absolute `http(s)://` URLs, allowlisted and credential-injected host-side; see `pipelines.md` → external calls), and `"store": {"root": "..."}` to relocate the spec storage prefix (default `.rs2-pipelines<mount base>`). To store the specs themselves in an operator infra-backed file store (e.g. S3), use `specStore` (→ "Infras").

Spec syntax, conditions, transforms, retries: `pipelines.md`.

### Triggers: launching a pipeline from an event

Because a pipeline executes on **any verb from any source**, "an event starts a flow" needs no queue or event bus — point the trigger at a pipeline mount and its `.root` (or a named spec) runs with the event as the request. Three trigger sources:

- **Webhook (inbound HTTP).** The provider POSTs straight to the pipeline mount; `POST /hooks/stripe` runs the `stripe` spec (or `.root`) with the event body and returns the flow's result. Open the mount for the unauthenticated provider — `{"access": {"invoke": "all"}}` — and end the flow with a 2xx so the provider doesn't retry (a non-2xx makes the provider **re-send**, giving at-least-once delivery for free). Example flow that stores the event then acks: `{"pipeline": ["PUT /data/events/incoming", {"received": true}]}`.
- **Schedule (timer/cron).** Put `schedule` on the pipeline mount (`{"schedule": {"every": "60s"}}` or `{"cron": "0 9 * * *"}`); the host fires a synthetic internal `POST` on cadence (`custom-services.md` → "Scheduled triggers"). The polling connector reads its cursor (`state-get`/`state-put`) and fans out.
- **Connector (a `code:` service in front).** When you must parse the payload in custom code before dispatching, a custom service receives the webhook and invokes the pipeline via a `prefix` grant to its mount (`custom-services.md` → "Capability grants").

**Verifying the signature (`$hmacVerify`).** A pipeline can verify a provider's HMAC signature inline, so an unauthenticated webhook mount is still safe. The signing secret lives in the tenant `secrets` block (write-only, redacted on `GET /raw`); the mount grants it by name with `"secrets": ["stripe"]`, and the host binds it as `$stripe`. Two JSONata functions are available in transforms: `$hmac(algorithm, key, message)` → hex MAC, and `$hmacVerify(algorithm, key, message, signatureHex)` → bool (constant-time; `algorithm` ∈ `sha256`|`sha512`). The signature is over the **raw** request bytes, exposed as `$_rawBody`; request headers are `$_headers`. Gate as the **first** step (before anything rewrites the body) with a whole-body `transform`:

```json
{ "path": "/hooks", "service": "pipeline",
  "config": { "access": { "invoke": "all" }, "secrets": ["stripe"] } }
```
```json
{ "pipeline": { "steps": [
  { "transform": "$hmacVerify('sha256', $stripe, $_rawBody, $substringAfter($_headers.\"x-hub-signature-256\", 'sha256=')) ? $ : $error('invalid signature')" },
  { "call": { "method": "PUT", "url": "/data/events/incoming" } },
  { "received": true }
] } }
```
A failed gate (`$error`) returns 400. Notes: covers SHA-256/512 hex signatures (Stripe `v1=`, GitHub `sha256=`, Slack `v0=`); SHA-1/base64 (e.g. Twilio) are follow-ups; the secret is bound only for mounts that grant it (default-deny) and never reaches a sandboxed guest.

This is synchronous fan-out (the trigger waits for the flow). **Decoupled** delivery — absorbing bursts, retrying processing independently of the inbound request, surviving a mid-flow restart — would be a durable queue capability, a future addition.

## wrapper — one inline pipeline fronting a mount (config-declared pattern)

A `wrapper` mount carries **one** pipeline spec inline in its config (`config.pipeline`, typed or string-DSL) and runs it for **every verb and sub-path** — the lightweight alternative to the `pipeline` service's authored spec store when you just want a single fixed transform/proxy in front of another mount. No `.pipelines/` subtree, no `.root`: the inline spec governs the whole mount.

```json
{ "path": "/users", "service": "wrapper", "config": {
    "access": { "read": "authenticated", "write": "A" },
    "pattern": "store",
    "facets": ["schema", "patch"],
    "pipeline": ["GET /data/users${url.rest}"]
} }
```

- **`pattern` / `facets`** — unlike every other service (whose discovery `pattern` is fixed by type), a wrapper **declares** the shape it presents, so clients in `/.well-known/rs2/services` and `OPTIONS` treat `/users` like the `store` it fronts. One of `store` / `store-transform` / `store-view` / `view` / `api` (validated at config time; default `store-transform`). `facets` are advertised verbatim and drive the `OPTIONS` `Allow` set (e.g. `patch` → PATCH).
- **`${url.rest}`** — the byte-exact path beyond the mount (see `pipelines.md`): `GET /users/ada@x.com` → a step `GET /data/users${url.rest}` calls `/data/users/ada@x.com`; `/users/` → `/data/users/`. This is how a wrapper transparently forwards every path.
- **`inputSchema` / `outputSchema`** — declare the facade's own request/response contract (distinct from the wrapped store's schema, since the pipeline transforms the shape). `inputSchema` is **enforced**: a PUT/POST/PATCH body that fails it is rejected `422` before the pipeline runs. `outputSchema` is **advisory** (not enforced — a facade's responses vary between a keyed record and a store listing, and field-authz may redact fields). Both are compile-checked at config time (400 on a malformed schema) and surfaced in `/.well-known/rs2/services`, `OPTIONS`, the OpenAPI doc (`requestBody`/`200`), and the agent surface.
- **Access is host-enforced** against the wrapper's own mount `access` (fail-closed — no `access` ⇒ 401/403), *not* per-spec like `pipeline`. Sub-calls are internal requests carrying the principal, so the wrapped mount still enforces its own `access` (and `elevate` adds a role to those calls, same as `pipeline`).
- **External calls** work here too: `httpOut` grants on the wrapper mount let its inline spec call absolute `http(s)://` URLs, same semantics as `pipeline` (see `pipelines.md` → external calls).

Use `pipeline` when you need many authored specs per mount or per-path `access`; use `wrapper` for a single fixed pipeline that should look and behave like the mount it wraps.

## proxy — forward to an external API with host-injected auth (`api`)

Forward every request on the mount to a fixed external `target`, attaching credentials **host-side** so the secret never lives in tenant config or reaches any guest. This is the no-code "proxy adapter": mount it, point it at an upstream, name a credential.

```json
{ "path": "/stripe", "service": "proxy",
  "config": { "target": "https://api.stripe.com", "inject": "infra:stripe-key" } }
```

`GET /stripe/v1/charges?limit=3` → `GET https://api.stripe.com/v1/charges?limit=3` with the credential applied; the client's headers are forwarded (minus the inbound `Host`), the response returned as-is. The host is fixed by `target` (the mount *is* the allowlist).

**`inject`** (also usable on a `code:` service's `httpOut` grant) names the credential, applied just before the request leaves the host:
- `"infra:<name>"` — an operator infra supplies the whole strategy + secret (`infras.json`, never tenant-visible). Recommended for operator-owned keys.
- an inline object — e.g. `{"auth":"bearer","token":"secret:apiKey"}`; any `secret:<name>` leaf draws on the mount's granted tenant secrets (`"secrets": ["apiKey"]` + the tenant `secrets` block). For tenant-owned keys.

Strategies: `bearer` (`token`), `header` (`name`,`value`), `basic` (`username`,`password`), `query` (`name`,`value`), `hmac` (`algorithm`,`secret`,`header` — signs the request body), `awsSigV4` (`accessKeyId`,`secretAccessKey`,`region`,`service`). Header/query/bearer/basic leave a streaming body untouched; `hmac`/`awsSigV4` materialize it to sign. The secret never appears in `GET /services/raw`.

## sms — outbound SMS over a swappable provider (`api`)

A typed provider capability: the canonical `POST /send {to, body}` / `GET /status/{id}` surface, backed by a provider adapter you pick per mount. Swapping Twilio for SNS is a `store.adapter` change — the service is unchanged.

```json
{ "path": "/sms", "service": "sms",
  "config": { "store": { "adapter": "code:twilio@v1" } } }
```

`POST /sms/send` with `{"to":"+1…","body":"…"}` → `201 {"id":…}`; `GET /sms/status/<id>` → provider-shaped delivery status. The provider is a deployed JS adapter (`code:<name>@<version>`, or `infra:<name>`); it maps the canonical request to the provider's wire format and uses an `httpOut`/socket grant (with `inject`, above) for the provider's auth — so the secret stays host-side. No first-party SMS providers ship yet, so `builtin:` is rejected; use a `code:` adapter (see `custom-services.md`). This is the reference pattern for typed provider capabilities (email, signing, … follow the same shape).

## query — stored parameterized queries (`store-view`; facets: `positional-params`, `url-params`, `any-verb`, `meta-sort`)

Queries are **authored like files** under the reserved subtree `/<mount>/.queries/…` (same store-contract authoring surface as pipelines — guard authoring with `write`). Every other path, on **any verb**, executes the longest-prefix-matched stored query — so a stored query can serve plain `GET`. Specs default to `.rs2-queries<mount path>/` in the tenant file store (`"store": {"root"}` relocates them; or a `specStore` block to put them in an infra-backed store — note `store.adapter` here selects the query **execution** backend, so spec storage uses the separate `specStore`, see "Infras"); nested query paths (`orders/by-status`) work.

The envelope (validated at PUT time — bad envelopes and non-compiling schemas are 400s at write, not at execution):

```json
{ "language": "json",
  "query": { "dataset": "orders",
             "where": { "status": "${status}",
                        "total": { "op": ">=", "value": "${min}" },
                        "name": "${name?}" },
             "orderBy": "total" },
  "params": { "type": "object", "required": ["status"],
              "properties": { "status": {"type": "string"},
                              "min": {"type": "number", "default": 0},
                              "name": {"type": "string"} } },
  "output": { "type": "array" } }
```

`language` is optional (inferred: JSON template → `"json"`, string template → `"sql"`). The envelope is agnostic to the backing query language — Mongo aggregates and Elastic DSL are JSON templates; SQL is a string template.

**Execution** — any verb on `/<spec-path>[/<extra>/<segments>]`:

- Params, later sources winning: URL segments beyond the stored spec path become positionals `"0"`, `"1"`, … → query-string pairs (non-`$`-prefixed; coerced to the `params` schema's declared types: number/integer/boolean parse, else string — so `GET /q/open-orders?status=open&min=20` works) → JSON object body (named) or array body (positional).
- Schema `default`s are applied for missing params, then the whole set validates against `params` → 422 with an `errors` array.
- **JSON templates substitute structurally**: a string node that is exactly `"${name}"` is replaced by the param's JSON value (numbers stay numbers — injection-safe by construction, and templates are valid JSON at rest). `"${name?}"` is optional: an absent param elides the enclosing object member or array element (language-agnostic optional clauses). Placeholders embedded in longer strings (`"name:${who}"`, `"$0"`) splice adapter-quoted. A missing required param is always a 400 — never a silent empty string.
- **Object keys may be placeholders**: a key that is exactly `"${name}"`/`"${name?}"` substitutes to the param's **string** value (non-string → 400); an absent optional key elides the member — the dynamic-sort idiom `{"$sort": {"${sortField?}": "${sortDir?}"}}`.
- **`"$if"` gates whole clauses**: an object carrying `"$if": "${flag?}"` is dropped from its parent array/object when the flag param is absent or empty (`null`, `false`, `""`, `[]`); otherwise the marker is stripped and the object substitutes normally. Use it for conditional `$match` stages toggled by a filter flag (v1 Mongo's `_include` pattern).
- **String (SQL) templates are never spliced by the service**: they pass to the adapter with the validated params intact so SQL adapters bind (prepared statements). The reference adapter is JSON-only and declines them with 501.
- Results: JSON array + `X-Total-Count`; `$take`/`$skip` page.

The reference adapter scans a data-store dataset: `where` clauses AND together; field names may be dot-paths; ops `==` (default), `!=`, `<`, `>`, `<=`, `>=`, `contains`; `orderBy` sorts; each row gains `_key`. Stored queries appear on the agent surface with their `params`/`output` schemas (read live from the store).

A `query` mount can run stored queries through a deployed JS adapter instead of the reference adapter — `{"store": {"adapter": "code:my-pg@v1", ...}}` pushes the resolved query down to a custom backend, kept resident with pooled connections. Template substitution and param schemas stay the host's. See `custom-services.md` → "Loadable adapters".

## template — JSX templates rendered to HTML (`store-view`; facets: `positional-params`, `url-params`, `json-props`, `any-verb`, `meta-sort`)

Renders **JSX templates** to HTML with request data as props — "data in, page out" (emails, server-rendered pages, fragments). Requires the JS engine: a `template` mount on a build without `--features js` is `501 Engine Unavailable`. Templates are **authored like files** under the reserved subtree `/<mount>/.templates/…` (guard authoring with `write`); every other path, on **any verb**, renders the longest-prefix-matched template — so a template can serve a plain `GET`. A `.root` template governs the mount root and unmatched subpaths. Templates default to `.rs2-templates<mount path>/` in the tenant file store (`"store": {"root"}` relocates).

**A stored template is a compiled bundle, not raw JSX.** The sandbox runs single-file ESM with no transpiler, so JSX is transpiled+bundled **CLI-side** with `rs2 template build` (esbuild + Preact), then PUT as a small JSON envelope:

```json
{ "source": "<compiled single-file ESM>", "contentType": "text/html; charset=utf-8" }
```

`contentType` is optional (default `text/html; charset=utf-8`). The envelope is validated at PUT time (a missing/empty `source` is a 400); a bundle that fails to evaluate surfaces its error at first render. The compiled bundle's default export is the render handler the engine calls — `rs2 template build` writes it for you from a component whose default export is a Preact component:

> **Discovery for generic clients.** Each spec-store entry in `GET /.well-known/rs2/services` (and the `OPTIONS` probe) carries `specSubtree` (the reserved authoring root: `.queries`/`.pipelines`/`.templates`) so a client finds where specs live without special-casing service names. Stores needing more than plain-JSON editing also carry an `authoring` object describing the round-trip: `pipeline` advertises `{"kind":"pipeline-dsl","compiledField":"pipeline","sourceField":"x-source"}` (the UI keeps the author's concise DSL in `x-source` — an `x-…` field the envelope validator passes through untouched — beside the canonicalized `pipeline`); `template` advertises `{"kind":"jsx","framework":"preact","compiledField":"source","sourceField":"jsxSource","render":"html"}` (edit JSX in `jsxSource`, compile to `source`). `query` omits `authoring` (edit JSON directly). Feature-detect; `authoring` for `template` only appears on `--features js` builds (pipeline needs no engine).

```jsx
// welcome.jsx — `props` is the merged request data
export default function Welcome(props) {
  return <html><body><h1>Hello, {props.name ?? "world"}!</h1></body></html>;
}
```

```sh
npm i preact preact-render-to-string         # once, in the project
rs2 template build welcome.jsx               # bundle → compile-check → write welcome.template.json
# PUT welcome.template.json to /<mount>/.templates/welcome
```

`rs2 template build` does bundle, verify, and write in one step: esbuild catches transpile/import errors, and a `js`-enabled CLI (`cargo build -p rs2-cli --features js`, or `rs2 --features…`) additionally runs the engine's compile check so a bundle that fails to load as ESM is rejected before it's written — the same smoke test the server applies to deployed code. The server-side validator on PUT only checks the envelope shape (non-empty `source`); a bundle that compiles but throws at render surfaces its error on first request.

**Render** — any verb on `/<template-path>[/<extra>/<segments>]`. Props, later sources winning: URL segments beyond the matched template path become positionals `"0"`, `"1"`, … → query-string pairs (non-`$`-prefixed) → JSON object body (named). The merged object reaches the component as its `props`. The response is the rendered HTML with the template's `contentType`. Compiled templates are built once into a resident isolate and cached **per content version**, so a PUT that changes a template's bytes transparently swaps in the new render on the next request.

Templates render pure output — they get no host capabilities (no data/file/fetch). Compose with the data services upstream (e.g. a pipeline that fetches a record, then POSTs it to the template mount) to fill a page from stored data. See `custom-services.md` for the JS toolchain.

## auth — authentication & RBAC

Endpoints and the role model are in `http-api.md`. Config notes: the tenant-level `auth` object holds the signing key and lockout policy; `"jwtUserProps": ["accountId", ...]` names user-record fields copied into the token as **extra claims** — they ride the JWT, come back from `GET /auth/user`, and bind into pipelines as `$_user.<field>` / `${_user.<field>}` (see `pipelines.md`). Extra claims are bearer authority for the whole session: only name fields that are **operator-writable-only** in the user dataset (enforce with the data mount's field-level authz — never a self-writable field), and remember a change to the record takes effect on next login, not on existing tokens. The mount itself usually needs no config beyond `access` (keep `login` reachable: `read` is irrelevant — these are POSTs, which map to `invoke` — so leave the auth mount access open or `invoke: "all"`). The service reads user records through the data capability (`userDataset`, default `users`). Seed users by PUTting records with an argon2id `passwordHash` into the dataset; a pipeline can compute the hash inline with `$hashPassword(password)` in a transform (see `pipelines.md`), so a provisioning pipeline can create login-ready users without hashing out of band.

## services — self-configuration API

The tenant's control surface; protect it with `write": "A"`. Changing authorization config is **operator-only** — set the tenant's `operatorRoles` to the role(s) you trust to reconfigure (5.0). To get the first operator/admin that can edit a locked-down mount, seed one at node startup with `bootstrapAdmin` / `RS2_ADMIN_EMAIL`+`RS2_ADMIN_PASSWORD` (see `cli.md` → "Bootstrap admin").

| Request | Behavior |
| --- | --- |
| `GET /catalogue` | Available **built-in** service types, each with a full JSON Schema for its config (`{services: [{name, description, configSchema}], baseSchema, tenantSchema}`). `configSchema` covers the service's own fields; `baseSchema` is the common mount envelope (`access`, `caching`, `retry`) every mount shares; `tenantSchema` is the top-level `auth`/`cors`/`retry`/`catalogues`. Schemas are derived from the runtime's config types, so they never drift from what `PUT /raw` accepts — a config UI can build forms straight from them. Secret fields (e.g. `auth.jwtSecret`) are marked `"writeOnly": true, "format": "password"` so a UI renders them masked and never expects the value back |
| `GET /catalogues` | The tenant's registered external catalogues (`tenantSchema.catalogues`), each `{name, url, host, allowlisted}` — `allowlisted` reflects the operator host-allowlist (`cli.md`). `enabled` is false when the node has no allowlist (the feature is off) |
| `GET /catalogue/available` | The **selectable** items for a config UI: built-in service types, built-in adapters (`{kind:"adapter", adapterKind, ref:"builtin:<name>"}`), and items fetched from each registered catalogue (`{kind:"service"\|"adapter", engine, version, ref:"code:<name>@<version>", installed, source:"catalogue", catalogue}`). `installed` reflects whether that `code:` ref is already in the `/code/` store. A catalogue that fails to fetch degrades to an `{error}` entry, not a whole failure |
| `POST /catalogue/install` | Install one item: body `{catalogue, name, version}` → the host fetches the bundle from the catalogue (operator-allowlisted hosts only), **verifies the content hash equals `version`**, compile-checks, and stores it into `/code/` → 201 `{name, version, ref, validated}`. **Deploy only — it does not mount or grant.** Mount the returned `code:` ref (or set it as a `store.adapter`) with `PUT /raw`. Idempotent. Unknown catalogue → 404; hash mismatch → 400; non-allowlisted host → 403; feature off → 501 |
| `GET /services` | Mount summary `{mounts: [{path, service, access}]}` |
| `GET /services/infras` | The operator **infras** this tenant may consume (`{infras: [{name, description, adapterKind, providedKeys, requires, infraOnly}]}`), filtered by each infra's `allowedTenants`. `providedKeys` lists the field names the operator pre-baked — **never their values** (secrets stay hidden). `requires` are the fields the tenant must supply; `infraOnly` the fields it may not set. See "Infras" below |
| `GET /raw` | Tenant config + `ETag` (version). **Secrets are write-only** (PRD §9.2): `auth.jwtSecret` and everything under a top-level `secrets` block read back as `"<secret>"` |
| `PUT /raw` | Replace the config: parsed, **dry-built** (every mount validated), persisted, hot-swapped atomically → 204 + new `ETag`. Invalid → 400 with the reasons, running tenant untouched. `If-Match: "<etag>"` enforces optimistic concurrency (mismatch → 409). `"<secret>"` markers are replaced with the stored values, so the GET → edit → PUT cycle never destroys a secret (a marker with no stored counterpart → 400); supply a real value to rotate |
| `/code/…` subtree | **A store** (editor UIs use the generic store client), with the `content-addressed` facet: child names derive from content. `GET /code/` lists bundle names (dir entries); `GET /code/<name>/` lists versions as dir+json children, each annotated `mountedAt: [paths]` where the live config references it; `GET /code/<name>/<version>` (bare version or listing child name) returns the bundle — correct content type, `ETag` = version, `Cache-Control: … immutable` |
| `POST /code/<name>/` | **Deploy** = the store contract's keyless create: body `application/wasm` or `application/javascript` (single-file ESM) → 201 + `Location` + `{name, version, ref, validated}`. Compile smoke test rejects broken bundles with 502 when the matching engine is in the build; identical bytes redeploy to the identical version |
| `PUT /code/<name>/<version>` | Accepted only when `<version>` equals the content's hash (idempotent re-upload for sync tools); otherwise 409 — a bundle can never be mislabeled |
| `DELETE /code/<name>/<version>`, `DELETE /code/<name>/?confirm=<name>` | Version / whole-bundle delete; **a version referenced by a live mount refuses with 409** (repoint first) |

Versions are immutable — redeploying identical bytes yields the same version; changed bytes yield a new ref that mounts must opt into. Mount deployed code as `{"path": "/x", "service": "code:<name>@<version>", "config": {"grants": {...}}}` — see `custom-services.md`.

## Infras — operator-managed adapters (PRD §9.1)

An **infra** is a named, *partial* storage-adapter config the **operator** defines once at the node level (in `infras.json`, see `cli.md`) and a tenant references by name — without ever seeing the operator's baked-in fields (region, bucket, **keys**). It's the managed-infrastructure seam: a tenant owner can use "the prod S3" or "the shared Postgres" while credentials and any locked-down limits stay with the operator.

A tenant points a store at an infra with the `infra:<name>` adapter scheme, supplying only the fields the operator left open:

```json
{ "path": "/files", "service": "file",
  "config": { "store": { "adapter": "infra:s3-prod", "prefix": "tenant-assets" } } }
```

At config time the runtime merges the infra's pre-baked config over the tenant's fields (**the infra always wins**), rewrites `adapter` to the real `builtin:`/`code:` backend, and validates. So an `infra:` ref is a 400 at `PUT /raw` (never a runtime surprise) when:
- the infra doesn't exist, or its `allowedTenants` doesn't include this tenant (403);
- the tenant omits a field the infra marks `requires`;
- the tenant sets a field the infra marks `infraOnly` (the operator's locked-down limitation, e.g. a multi-tenancy isolation toggle).

Infras never appear in `GET /raw` (they live in `infras.json`, not tenant config), so their secrets cannot leak. Discover the ones you may use with `GET /services/infras` (values redacted). The operator can change `infras.json` and apply it live with `POST /admin/reload-infras` (no restart; see `cli.md`).

**Credential infras (for `inject`).** The same `infra:<name>` mechanism supplies outbound credentials to a `proxy` mount or a `code:` service's `httpOut` grant: the operator defines an infra whose `config` is an auth strategy — e.g. `{"adapter":"credential","config":{"auth":"bearer","token":"sk_live_…"}}` — and the tenant references it with `"inject": "infra:<name>"`. The token stays operator-side; the tenant never sees it. (`adapter` is required by the infra schema but unused for a credential infra — only `config` is read.)

**Storing specs in an infra.** `pipeline`/`query`/`template` mounts can keep their *authoring specs* in an infra-backed file store (e.g. on S3, with operator keys) via a separate `specStore` block — independent of `store` (which, on a `query` mount, selects the *execution* backend):

```json
{ "path": "/p", "service": "pipeline",
  "config": { "specStore": { "adapter": "infra:spec-bucket", "root": "my-pipelines" } } }
```

`specStore.adapter` selects the spec file backend (`infra:`/`builtin:`/`code:`); `specStore.root` relocates the storage prefix (falling back to the legacy `store.root`, then the `.rs2-<kind><mount>` default). Absent ⇒ specs live in the node file store as before.

## log — structured log reader (`view`; facets: `url-params`, `time-range`, `trace-scoped`)

Reads back the node's structured logs (PRD §14), **scoped to the requesting tenant** (a tenant only ever sees its own). Read-only; the records are OTel LogRecords. Logs are operational — guard the mount with `access` like any other (`{"service":"log","config":{"access":{"read":"A"}}}`).

| Request | Behavior |
| --- | --- |
| `GET /<mount>` | Newest-first records as a JSON array (OTLP shape), or `text/plain` NDJSON via `Accept: text/plain`. `X-Total-Count` set. |
| `GET /<mount>/<traceId>` | All records for one trace (request-debugging view) — same as `?traceId=`. |

Query params (all optional): `$take` (default 100, max 10 000), `severity` (`debug\|info\|warn\|error` floor), `traceId`, `service` (matches a mount, or a request-path prefix for host boundary logs), `since`/`until` (Unix-ms integer or RFC 3339), `q` (case-sensitive body substring).

**What's logged** (no service config needed — the host produces it):

- **Boundary logs** — one per dispatch at the host's single choke point: external requests and internal pipeline hops alike, each its own `spanId` under a shared `traceId`. Severity from outcome: 5xx → `Error` (always emitted), 4xx → `Warn`, external success → `Info`, internal hop success → `Debug`. Attributes follow OTel semantic conventions: `http.request.method`, `url.path`, `http.response.status_code`, `duration_ms`, `rs2.source` (`external`/`internal`), `enduser.id`/`rs2.principal.kind`, and on failure `error.type`/`error.message`/`rs2.retryable`.
- **Service logs** — a prebuilt service's own application lines (e.g. `auth` logs failed logins), `rs2.source: "service"`, `rs2.service` fixed to the mount's service.
- **Sandbox logs** — a custom service's `console.log`/`console.warn`/… (and Wasm `log()`), `rs2.source: "custom"`, `rs2.service` = the code ref. Stamped with the invocation's trace, so they line up with that request's boundary log.

A record (OTLP-shaped, one NDJSON line at rest):

```json
{ "timeUnixNano": "1718200000000000000", "severityNumber": 13, "severityText": "WARN",
  "body": "GET /files/nope -> 404", "traceId": "…", "spanId": "…",
  "attributes": { "rs2.tenant": "acme", "http.response.status_code": 404,
                  "error.type": "not_found", "rs2.source": "external" } }
```

**Where logs go is operator config**, not tenant config — the node's `serverConfig.json` `logging` block (`cli.md`): default a local-file sink (`./logs/<tenant>.ndjson`, size-rotated), `"sink":"none"` to disable, `level` to set the boundary floor (5xx always emit). Swap the sink for a write-only exporter (OTLP/observability platform, follow-on) and the reader reports the logs aren't locally queryable (501) — they live in your platform. The `X-Trace-Id` response header on every request correlates a response to its log line.
