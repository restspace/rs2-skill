# The `rs2` CLI, server config, and v1 migration

The `rs2` CLI covers both the **developer loop** (scaffold, run, validate, deploy, migrate) and a small set of **admin/ops** commands that drive a running server (`login`, `send`, `service add`, `service set-access`, `auth …`, `pull`, `push`, `run`). The admin commands read a saved server identity from `rsconfig.json` (see below); for anything they don't cover, call tenants over HTTP directly (`http-api.md`).

## Verbs

| Command | Does |
| --- | --- |
| `rs2 new <name> [--js]` | Scaffold a custom service project. Default: Rust/Wasm against the published WIT (compiles as-is with `cargo build --target wasm32-wasip2 --release`). `--js`: single-file ESM scaffold with `manifest.json` |
| `rs2 dev [serverConfig.json]` | Run a local node (same code as `rs2-server`) |
| `rs2 test [projectDir] [--component <path>]` | Validate `manifest.json` (name/engine/effect classes/capabilities) and the built component (wasm header; engine compile check when built with `--features wasm`) |
| `rs2 deploy <file> --name <n> [--server <url>] [--token <t>] [--bundle]` | Keyless upload to `POST <server>/code/<n>/` (the content-addressed store derives the version; a `PUT` needs an explicit `<name>/<version>`). `.js`/`.mjs` deploys as a JS bundle; `\0asm` files as components. `--bundle` first runs `npx esbuild <file> --bundle --format=esm --platform=browser` (npm deps resolve at build time; native addons fail there). Both `--server` and `--token` default from `rsconfig.json` — `host` + `/services` (else `http://127.0.0.1:3100/services`), and the unexpired token `rs2 login` saved for that host |
| `rs2 migrate <services.json> [-o tenant.json]` | Convert a v1 Restspace config to an RS2 tenant config |
| `rs2 catalogue-dump` | Print the service config catalogue — the same document a running node serves at `GET /<services>/catalogue` — as pretty JSON on stdout. No server, no arguments: it dumps the catalogue compiled into the CLI. Use it to diff or check in the config schemas offline; the Cloudflare host checks the output in as a fixture so both hosts serve byte-identical schemas |
| `rs2 login [--host <url>] [--email <e>] [--password <p>]` | Authenticate against `POST {host}/auth/login` and save the returned token to `rsconfig.json`. Missing flags fall back to `rsconfig.json` (`host`, `login.email`, `login.password`); the password also reads from `RS2_PASSWORD` |
| `rs2 send <path> --file <local> [--content-type <ct>]` | `PUT` a local file to `{host}{path}`, sending the saved bearer token if one is valid (it is not required — the server enforces access, so an open mount accepts an anonymous send; a 401/403 hints to `rs2 login`). Content-type is inferred from the file extension unless `--content-type` is given. Prints `created` (201) or `overwritten` (200) |
| `rs2 service add <mount.json> [--path <p>]` | Add a mount to the running tenant via the self-config API. Reads `GET /services/raw` (with its ETag), appends the mount spec, and `PUT`s it back `If-Match`. The path is `--path` or the file's `path`; **fails if a mount already occupies that exact path** (nothing changes). Sends the saved token if valid but doesn't require it (so an open `/services` can be configured before any admin exists) |
| `rs2 service set-access <path> --access <json> [--set k=v]…` | Set the `access` policy on an **existing** mount in place (the GET→merge→`PUT If-Match` dance, like `service add` but editing not adding). `--access` is the policy JSON (e.g. `'{"read":"A","write":"A"}'`); each `--set key=value` adds a `config` key (value parsed as JSON, so `enforceSchema=true` works). Used to tighten an open bootstrap mount |
| `rs2 auth init --admin-email <e> [--admin-password <p>] [--operator-roles A] [--user-dataset users] [--data-mount /data] [--show-secret]` | One-shot bootstrap of auth on a **fresh, open** node: generate a `jwtSecret`, set `operatorRoles`, mount `/auth`, create the first admin (password hashed locally), log in as them, then lock the user store and `/services` to the operator role. Password falls back to `RS2_ADMIN_PASSWORD` / `RS2_PASSWORD` / `login.password`. For a self-hashing `/users` pipeline + schema, use the granular verbs (see `examples/seed-auth`) |
| `rs2 auth enable [--operator-roles A] [--user-dataset users] [--session-minutes N] [--data-mount /data] [--show-secret]` | Turn auth on over HTTP: ensure a `jwtSecret` (generated once if absent — never rotated), `operatorRoles`, an `/auth` mount, and a temporarily write-open user-store mount. Idempotent |
| `rs2 auth create-admin --email <e> [--password <p>] [--roles A] [--data-mount /data] [--user-dataset users]` | Seed the first operator: hash the password locally (argon2id) and write `{passwordHash, roles, kind:"user"}` straight to the user dataset. **Seed-if-absent** (skips a visible existing record). Must run while the data mount is write-open and **before** any field-authz schema is installed |
| `rs2 pull [--host <url>] [--dir <d>]` | Mirror the tenant's **instruction plane** (config + every spec store + code pins) into a local directory (default `./rs2`, or the nearest existing `rs2/` walking up) for git-based editing. Discovers what to pull from `/.well-known/rs2/services` — config from the `control` block, every mount with a `specSubtree`. Records baseline ETags in `rs2/mirror.json`. Remote is source of truth (overwrites local specs — commit first) |
| `rs2 push [--dir <d>] [--dry-run] [--allow-secret-rotation]` | Push local instruction-plane edits back: config via `PUT /services/raw` (server `If-Match`), specs via store writes (`If-Match` baseline; `If-None-Match: *` for creates). Aborts on a remote change (config 409 / spec 412) with *run `rs2 pull` to reconcile* rather than clobbering. `--dry-run` prints the diff + planned requests. Refuses to push a real secret value where the `"<secret>"` marker belongs unless `--allow-secret-rotation`. Code bundles are **not** pushed — deploy with `rs2 deploy` and repoint the mount in `tenant.json` |
| `rs2 run <script>` | Run a script of `rs2` commands — one per line, with `rs2` omitted (e.g. `send /files/x --file ./x`). Blank lines and `#` comments are skipped; each line is echoed then run **in order, aborting on the first failure**. `dev` is rejected (it never returns) |

## Admin/ops config (`rsconfig.json`)

The admin commands (`login`, `send`, `service add`, `deploy`, `run`) read their server identity from `rsconfig.json`. The CLI walks **up from the current directory** to the nearest one, so a project or working directory carries its own server target — no global flag plumbing.

```json
{
  "host": "https://api.acme.com",
  "login": { "email": "admin@acme.com" },
  "auth": { "token": "<jwt>", "exp": 1799999999, "host": "https://api.acme.com" },
  "caFile": "corp-root.pem"
}
```

- `host` — server base URL (trailing slash trimmed); the `--host` flag overrides it.
- `login` — optional saved credentials so `rs2 login` needs no flags. Prefer leaving the password out and supplying it via `RS2_PASSWORD` or `--password` so it isn't stored at rest.
- `auth` — written by `rs2 login`: the JWT, its `exp` (unix seconds), and the `host` it was issued for. Commands that need auth fail with *run `rs2 login`* if it's missing, expired, or issued for a different host. (This is distinct from the server-side `auth` **service**; see `http-api.md` for the login/token contract.)

A typical flow: `rs2 login` once (writes the token), then `send` / `service add` / `deploy` / `run` reuse it until it expires.

- `caFile` — optional PEM bundle of extra certificate authorities to trust when reaching `host` (see TLS below). A relative path resolves against the `rsconfig.json` that holds it.

**Gitignore `rsconfig.json`.** It holds a live bearer token, and often the password it was minted from — it is CLI state, not project config.

## TLS, private CAs, and proxies

The CLI trusts the **union** of the machine's OS trust store and a bundled copy of the Mozilla root list. A private CA — corporate proxy, CI TLS-inspection appliance, internal PKI — normally just needs installing in the OS store. Both sources are kept because some environments have no OS trust store (a scratch container without `ca-certificates`) and Windows populates its store lazily; using either alone would break hosts that work today.

When installing the CA system-wide isn't possible, name a PEM bundle — `--ca-file` is global, so it works on any verb:

```bash
rs2 --ca-file /etc/ssl/corp-root.pem send /files/report.pdf --file report.pdf
```

| Setting | Where | Effect |
| --- | --- | --- |
| `--ca-file <pem>` | flag, any verb | **Adds** the bundle's authorities to the roots |
| `RS2_CA_FILE` | environment | Same, for a shell session or CI job |
| `"caFile"` | `rsconfig.json` | Same, carried with the repo's server identity |
| `SSL_CERT_FILE` / `SSL_CERT_DIR` | environment | Conventional OpenSSL meaning — they **replace** the OS trust store rather than adding to it |
| `RS2_CA_ROOTS` | environment | `native` = OS store only (so a root distrusted there stays distrusted); `webpki` = bundled roots only. Default uses both |

A rejected certificate reports which roots were loaded and how to add one, rather than a bare `UnknownIssuer`.

**Proxies.** An explicit forward proxy is read from `ALL_PROXY`, `HTTPS_PROXY`, or `HTTP_PROXY` (either case); `NO_PROXY` is honoured as a comma-separated list of hosts and domain suffixes, or `*`. Loopback is never proxied, so a global proxy setting doesn't cut off `rs2 dev` on localhost. Transparent interception needs no proxy config — only the CA above.

The same trust roots apply server-side to `httpOut` capability grants and to JS `RS2Socket` TLS connections, so a service calling an internal host behind a private CA works once that CA is in the node's OS trust store. The server does **not** read proxy environment variables.

## The instruction-plane mirror (`pull` / `push`)

`rs2 pull`/`push` version-control **how a tenant behaves** in git, without dragging its data in. The mirror is a single directory (default `rs2/`) so a monorepo can hold the back end beside a front end:

```
repo/
  frontend/                 # SPA source → built assets (deployed separately)
  services/                 # rs2 new source projects (built → rs2 deploy)
  rs2/                      # THE MIRROR
    tenant.json             # GET /services/raw body (secrets shown as "<secret>")
    specs/<mount>/<subtree>/…   # stored pipeline/query/template specs
    code.lock               # pinned code name → version (informational)
    mirror.json             # sync state: host, tenant, baseline ETags — don't edit
    README.md
```

What's mirrored is **discovered, not hardcoded**: `pull` reads `/.well-known/rs2/services`, takes the config from the `control` block, and walks every mount that advertises a `specSubtree` (pipelines, queries, templates, and any future spec store — they join automatically). The local path for a spec is `specs/<mountSlug>/<specSubtree>/<rel>`, where `<mountSlug>` is the mount path with `/`→`__` (root mount → `root`).

`mirror.json` shape:

```json
{ "version": 1, "host": "http://127.0.0.1:3100", "tenant": "main",
  "control": { "config": "/services/raw", "code": "/services/code/" },
  "config": { "etag": "\"…\"" },
  "specs": { "specs/q/.queries/top": { "etag": "\"…\"", "hash": "fnv1a-…" } },
  "code": { "lock": { "stripe": { "version": "abc123", "mountedAt": ["/pay"] } } } }
```

**Workflow / decision rule.** Edit the instruction plane through the mirror when you want history/review or are changing several things; use the one-shot `GET → PUT /services/raw` loop (or `service add`/`set-access`) for a single quick edit:

- mirror present in the tree → edit files, `rs2 push`;
- no mirror + multi-file/versioned change → `rs2 pull` first;
- single quick edit → the `/services/raw` round-trip is fine without a mirror.

**Concurrency & safety.** Both planes use one model: config writes carry the server-enforced `If-Match`; spec writes carry `If-Match` against the recorded baseline (the `conditional-write` facet). A remote change since your pull aborts the push (config 409 / spec 412) with *run `rs2 pull` to reconcile* — it never clobbers. The new baseline ETag comes straight from the PUT response. Secrets stay write-only: `tenant.json` holds `"<secret>"` markers (the server restores real values on PUT), and push refuses a real value in a secret slot unless `--allow-secret-rotation`.

**Boundary.** The mirror is the instruction plane only. Front-end assets and `data` records are the **data plane** — deploy those separately (`rs2 send`, store writes), not via `push`. Custom-code bundles aren't pushed either: `rs2 deploy` uploads them (content-addressed) and `tenant.json` pins `code:<name>@<version>`.

## Server config (`serverConfig.json`)

```json
{
  "listen": "127.0.0.1:3100",
  "tenancy": { "mode": "single", "tenant": "main" },
  "fileRoot": "./data",
  "dataRoot": "./data-store",
  "tenantsDir": "./tenants",
  "logging": { "sink": "file", "level": "info",
               "file": { "path": "./logs", "maxBytes": 8388608, "backups": 5 } },
  "bootstrapAdmin": { "email": "admin@acme.com" },
  "catalogueHosts": ["catalogues.acme.com", "*.cdn.acme.com"],
  "infrasPath": "./infras.json"
}
```

Multi-tenant: `{"mode": "multi", "domainMap": {"api.acme.com": "acme"}, "mainDomain": "rs2.example.com"}` — explicit map first, then `{tenant}.{mainDomain}` subdomains. `fileRoot` is the local-fs file store root (tenant-prefixed subdirectories); `tenantsDir` holds `<tenant>.json` configs. **Relative paths (`fileRoot`, `dataRoot`, `tenantsDir`, `logging.file.path`, `infrasPath`) are resolved against the config file's own directory, not the process working directory** — so `rs2 dev serverConfig.json` finds the sibling `tenants/` regardless of where you launch it from; use absolute paths to point elsewhere. `dataRoot` (default `./data-store`) is the root for the file-backed data store (`builtin:file`), which is the node's **default** data adapter — so `data` mounts persist across restarts out of the box. It's kept separate from `fileRoot` so records (which may hold secrets like password hashes) aren't browsable through a `file` mount. A mount opts into ephemeral storage with `{"store": {"adapter": "builtin:mem"}}` — a single **shared** in-memory store (it ignores `root`, so it gives no per-mount isolation). For a durable but **isolated** store, select `builtin:file` (data) / `builtin:local` (file) **and name a `store.root`** — required for an explicit built-in store, so two mounts can't silently collide on the shared default (`services.md` → per-mount storage isolation). `catalogueHosts` is the operator allowlist of catalogue/bundle hosts the node may fetch from when a tenant installs a service/adapter from a registered catalogue (wildcard `*.suffix` patterns; empty ⇒ external catalogues are off regardless of what tenants register) — it bounds SSRF, since the fetch is a host action. See `custom-services.md` → "Catalogues" and `services.md`. `GET /healthz` and `/readyz` confirm the node is up.

## Infras (operator-managed adapters)

`infrasPath` (default `./infras.json`) points at the node's **infras**: named, partial storage-adapter configs with baked-in credentials that tenants reference as `infra:<name>` without seeing the keys (see `services.md` → "Infras"). A missing file is fine (no infras); malformed JSON fails startup. Each infra names a real backend (`builtin:`/`code:`), pre-baked config, and optional policy:

```json
{
  "s3-prod": {
    "adapter": "builtin:s3",
    "description": "Production S3 (eu-west-2), keys managed by ops",
    "allowedTenants": ["acme"],
    "config": { "region": "eu-west-2", "bucket": "rs-prod", "accessKeyId": "…", "secretAccessKey": "…" },
    "infraOnly": ["tenantDirectories"],
    "requires": ["prefix"]
  }
}
```

- `config` is overlaid over the tenant's fields (**infra wins**), so secrets stay operator-side. `allowedTenants` (empty ⇒ all) gates who may reference it; `requires` are fields the tenant must supply; `infraOnly` are fields the tenant may not set.
- **Reload without restart:** `POST /admin/reload-infras` re-reads `infras.json`, swaps the live set, and rebuilds every tenant on its next request. Gate it with a node admin token — `RS2_ADMIN_TOKEN` (preferred) or `serverConfig.adminToken`; **with neither set the endpoint is disabled (503)**. Present the token as `Authorization: Bearer <token>` or `X-Admin-Token: <token>`:

```bash
curl -X POST http://127.0.0.1:3100/admin/reload-infras -H "Authorization: Bearer $RS2_ADMIN_TOKEN"
# → 200 {"loaded": 3, "names": ["pg-shared","s3-prod","spec-bucket"]}
```

Removing an in-use infra makes the depending tenants fail (400) on their next request until repointed — an intentional forcing function. `GET /healthz` and `/readyz` confirm the node is up.

## Bootstrap admin (seeding the first `A`-role user)

A locked-down `services` mount (`write: "A"`, with `operatorRoles` including `A`) needs an operator/admin principal to manage it, but you can't create that user over a locked HTTP surface — a chicken-and-egg (the first operator can't come from the API). `bootstrapAdmin` breaks it: at startup the node seeds **one `A`-role user** straight into the tenant's user dataset (single-tenant `mode: "single"` only), so the admin can immediately log in and drive `PUT /services/raw`.

- **Credentials resolve env-first**, then the config block: `RS2_ADMIN_EMAIL` overrides `bootstrapAdmin.email`, `RS2_ADMIN_PASSWORD` overrides `bootstrapAdmin.password`. Set **both** an email and a password (in either place) or **neither** — a half-specified admin is a startup error. Prefer env for the password so it never sits in `serverConfig.json` at rest; a typical setup puts the email in config and the password in `RS2_ADMIN_PASSWORD`.
- **Requires `auth.jwtSecret`** in the tenant config (otherwise login can't mint tokens — startup fails with that message). The seeded record is `{passwordHash, roles: "A", kind: "user"}` keyed by email in the `auth.userDataset` (default `users`).
- **Seed-if-absent**: an existing record for that email is left untouched. The seed writes through the node's **default** data store — the same store `auth` reads `userDataset` from — which is file-backed (`builtin:file`) by default, so the seeded admin and any runtime change to it **persist across restarts**; on later boots the seed sees the existing record and does nothing. (Point the default at the in-memory store and the admin is instead re-seeded each boot from the env/config credentials.)

```sh
# email in serverConfig.json, password from the environment
RS2_ADMIN_PASSWORD='…' rs2 dev serverConfig.json
```

### Seeding the first admin over HTTP (no startup admin)

`bootstrapAdmin` is a *startup* mechanism. The alternative is to bootstrap a **fresh, no-auth node entirely over HTTP** — the node starts with just an open `/services` mount (no `auth` block, no `bootstrapAdmin`), and the CLI does the rest. This needs no restart and no on-disk secret. `rs2 auth init` is the one-liner; it works because (a) on an open node an anonymous caller may `PUT /services/raw` to set `auth.jwtSecret` / `operatorRoles` and add mounts, and (b) the CLI hashes the admin password locally and writes the first `A`-role record straight to the user store **while it's briefly write-open and schema-free** (a data write is only field-authz/schema-gated once a schema is installed). It then logs in and tightens `/services` + the user store to the operator role.

```sh
rs2 auth init --admin-email admin@acme.com --admin-password '…' --operator-roles A
```

The granular verbs (`auth enable` → `auth create-admin` → `login` → … → `service set-access`) do the same in visible steps and let you interleave a self-hashing `/users` pipeline + schema — see `examples/seed-auth`. **Security caveat:** between enabling auth and locking down, the user-store mount is briefly write-open to anonymous callers (unavoidable — the very first operator can't be created *by* an operator). Bind the node to `127.0.0.1` for the bootstrap and lock down immediately; don't bootstrap against a publicly reachable address.

`logging` is optional (operator-level — *where logs physically go* is node infra, not tenant config; defaults to a `file` sink at `./logs`). `sink`: `"file"` writes per-tenant NDJSON (`<path>/<tenant>.ndjson`, size-rotated with `backups`), `"none"` disables. `level` is the boundary-log floor (`debug\|info\|warn\|error`); 5xx always emit regardless. Expose them per tenant with a `{"service":"log"}` mount (see `services.md`); the `X-Trace-Id` response header correlates a response to its log line.

Server feature builds matter: the standard server wires the outbound HTTP adapter; engines are compile-time features (`wasm`, `js`) — a build without one serves `code:` mounts of that type as 501 `engine_unavailable` at request time (config stays valid). The Cloudflare host has no Wasm engine at all, so a Wasm bundle is always that 501 there (`http-api.md` → "Hosts").

## Production deployment (Ubuntu + Apache)

`rs2-server` listens for **plain HTTP on a loopback port** (default `127.0.0.1:3100`) with no built-in TLS — the production model is a reverse proxy (Apache/nginx) terminating TLS and forwarding to it. The repo's `deploy/` directory ships a one-liner installer, a hardened systemd unit, a production `serverConfig.json`, and an Apache vhost template:

```bash
# native+wasm build; add --js for the V8 build, --apache <domain> to wire the proxy
curl -fsSL https://github.com/restspace/rs2-runtime/releases/latest/download/install.sh \
  | sudo bash -s -- --js --apache api.example.com
sudo certbot --apache -d api.example.com   # issue the cert (interactive)
```

A release ships **server binaries only** — there is no prebuilt `rs2` CLI to download. Build it from the workspace: `cargo build --release -p rs2-cli`, binary at `target/release/rs2`.

The installer runs the node as a dedicated `rs2` system user with config under `/etc/rs2`, data under `/var/lib/rs2`, and logs under `/var/log/rs2`; it never overwrites an existing config on re-install (re-running just upgrades the binary). Two release variants exist — `rs2-server` (wasm) and `rs2-server-js` (adds V8) — picked with `--js`. **The Apache vhost must set `ProxyPreserveHost On`**: RS2 resolves tenancy from the `Host` header, so a proxy that rewrites Host sends every request to the wrong tenant. WebSockets are out of scope, so no ws-tunnel module is needed. Details and manual steps: `deploy/README.md` in the runtime repo.

## The Cloudflare host (`rs2-worker/`)

The second host of the same API (see `http-api.md` → "Hosts") is a TypeScript Worker in `rs2-worker/` in the runtime repo; **that directory's `README.md` is the operator's card** and this is the short version. It has no `serverConfig.json`, no `tenantsDir` and no disk: everything `serverConfig.json` holds is either a wrangler var or the admin API.

```sh
cd rs2-worker
npm ci
npm run dev                              # wrangler dev on http://127.0.0.1:8787 (local R2, SQLite, alarms, cron)
npx wrangler secret put RS2_ADMIN_TOKEN  # gates /admin/* — required for the admin API
npm run deploy                           # wrangler deploy
```

- **Vars** (in `wrangler.jsonc`, overridable per environment): `RS2_DEFAULT_TENANT` (single-tenant/local mode — any host resolves to it; **unset it in multi-tenant production**), `RS2_MAIN_DOMAIN` (the `<sub>.<mainDomain>` tenancy rule), `RS2_LOG_LEVEL`, `RS2_CATALOGUE_HOSTS` (the comma-separated equivalent of `serverConfig.catalogueHosts`).
- **Secrets**: `RS2_ADMIN_TOKEN` (the same gate as `POST /admin/reload-infras` on the Rust node), plus optional `CF_API_TOKEN` (a token with Zone → SSL and Certificates: Edit) and `CF_ZONE_ID` for customer domains. With both set, `PUT /admin/domains/<host>` provisions a Cloudflare for SaaS custom hostname and the customer's whole side of it is one CNAME to `RS2_CNAME_TARGET`; without them the same endpoints prove control with a self-check challenge instead and leave TLS to whatever sits in front (`http-api.md` → "Attaching a customer's domain"). The Worker repo's `npm run saas:setup` does the one-time zone wiring and `npm run domain -- add <host> --tenant <name>` the per-customer step.
- **Provision a tenant** with `PUT /admin/tenants/<name>` — `{"config": {…the same tenant config document…}, "domains": [...], "bootstrapAdmin": {"email","password"}}` — the replacement for dropping a `tenants/<name>.json` on disk. Infras go in with `PUT /admin/infras` instead of `infras.json`. Full endpoint list: `http-api.md` → "Hosts".
- Once a tenant exists, everything else is the ordinary HTTP API: `rs2 login`, `send`, `service add`, `deploy`, `pull`/`push` all work against a Worker host unchanged — point `rsconfig.json` `host` at it.

## Tenant config (`tenants/<name>.json` or `PUT /services/raw`)

```json
{
  "auth": { "jwtSecret": "...", "sessionMinutes": 60, "maxAttempts": 5,
            "lockMinutes": 10, "userDataset": "users",
            "allowedLoginOrigins": [] },
  "cors": { "trustedOrigins": [], "allowedOrigins": [] },
  "retry": { "maxAttempts": 3 },
  "mounts": [
    { "path": "/files", "service": "file" },
    { "path": "/data", "service": "data", "config": { "enforceSchema": true } },
    { "path": "/auth", "service": "auth" },
    { "path": "/orders", "service": "pipeline" },
    { "path": "/q", "service": "query" },
    { "path": "/services", "service": "services",
      "config": { "access": { "read": "all", "write": "A" } } },
    { "path": "/pay", "service": "code:stripe-wrapper@a1b2c3d4",
      "config": { "grants": { "fetch": { "type": "httpOut", "hosts": ["api.stripe.com"] } } } }
  ]
}
```

Top-level keys: `mounts` (required), `auth` (enables token verification + the auth service), `cors` (browser clients — see `http-api.md`), `retry` (tenant-default policy), `catalogues` (`[{name, url}]` external catalogues to browse/install services and adapters from — see `custom-services.md` → "Catalogues"; the host only fetches from operator-allowlisted `catalogueHosts`), `secrets` (`{name: value}` named secrets like webhook signing keys — **write-only**: redacted as `"<secret>"` on `GET /raw`. A mount opts into specific names with a `secrets: [names]` grant in its `config`; the host binds them for inline use (e.g. a `pipeline` exposes each as `$<name>` for `$hmacVerify` — `services.md` → "Triggers"). Never exposed to sandboxed guests). Mount keys: `path`, `service` (`file` | `data` | `pipeline` | `query` | `auth` | `services` | `code:<name>@<version>`), `config`. The shared `config` envelope (`baseSchema`) carries `access`, `caching`, `retry`, and `schedule` (`{ "every": "60s" }` or `{ "cron": "0 9 * * *" }`, UTC) — a scheduled mount is fired periodically by a synthetic internal `POST` (`custom-services.md` → "Scheduled triggers"). Duplicate paths are rejected; routing is longest prefix on segment boundaries.

Editing the file on disk requires a tenant reload (restart, or any `PUT /services/raw` round-trip); editing through `PUT /services/raw` validates and hot-swaps atomically and is the preferred path on a running server.

The scheduler that drives `schedule` mounts is **in-process and single-node by default** (multiple nodes would double-fire). It's HA-ready by construction: configuring a shared coordination store (`ScheduleStore`, e.g. Redis) makes firing cluster-exactly-once with no config change to tenants — an embedding/operator concern, swapped via `Adapters::with_schedule_store`.

## Migrating from v1 Restspace

`rs2 migrate services.json -o tenant.json` converts a v1 config:

**Carried over**: `basePath` → `path`; service sources mapped to RS2 prebuilts (`file`/`files`→file, `data`/`dataset`→data, `pipeline`→pipeline, `query`→query, `auth`/`user-data`/`user-filter`→auth, `services`→services); `access` role-spec strings unchanged (same grammar); `retry` policies unchanged (same shape); `caching` translated (`{cache, maxAge}` → `{mode, maxAgeSeconds}`; `sendETag` dropped — RS2 stores always emit ETags); the mount list is **validated by dry-building the tenant**. Pipeline specs are converted from the string DSL to typed envelopes and printed with instructions to `PUT` each to `<path>/.pipelines/.root` (a v1 single-pipeline mount maps to the `.root` spec, preserving its any-verb surface exactly).

**Warned and skipped/adjusted**: services with no RS2 equivalent (static-site, email, timers, webhooks, proxy, templates, …) — re-implement as custom services or pipelines; `prePipeline`/`postPipeline`/`caching`/`infraName`/`adapterSource` are not carried; `dataset` single-dataset mode becomes a plain data mount (client paths change); `userUrlPattern` → RS2 resolves users from the `users` dataset instead; v1 query files live in the query service's private store and must be re-PUT to the new mount as RS2 envelopes (`${name}` placeholders carry over, now structural in JSON templates; `$0` subpath params carry over as trailing URL segments).

**Does not carry over by design**: v1 Deno/TS service implementations (re-bundle against the RS2 contract — the message API is intentionally similar; `rs2 new --js` + `rs2 deploy --bundle`); JWTs (users re-authenticate; bcrypt password hashes verify as-is, new hashes are argon2id); chords (expand to explicit mounts); the `()` outer-service mechanism.

Review every printed warning before deploying the result, then seed `auth.jwtSecret` (the migrator cannot invent one) and the users dataset.

## Windows notes

`rs2 deploy --bundle` shells to `npx` (`npx.cmd`); Node.js must be on PATH. JSON files read by the CLI (including `rsconfig.json` and `service add` mount specs) and `rs2 run` scripts tolerate UTF-8 BOMs (PowerShell's `-Encoding utf8` adds one). When scripting HTTP against the server, prefer `Invoke-RestMethod` with `ConvertTo-Json` bodies or `curl.exe` — see `http-api.md`.
