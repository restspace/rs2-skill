# rs2-skill

The user-facing [Claude Code](https://claude.com/claude-code) / [Codex](https://openai.com/index/introducing-codex/)
skill for operating an [RS2](https://github.com/restspace/rs2-runtime) server —
Restspace 2, the Rust runtime for sandboxed composable HTTP services.

Load this skill and an agent can inspect a running RS2 tenant, author and debug
pipeline specs, drive the `rs2` CLI, deploy custom sandboxed services, and
migrate a v1 Restspace `services.json` — all from terse, lookup-oriented
reference docs rather than re-deriving the HTTP surface each session.

This is a *skill*, not the runtime itself. To run an RS2 server, see
[rs2-runtime](https://github.com/restspace/rs2-runtime).

## Install

Requires PowerShell (Windows, or PowerShell 7+ on Linux/macOS).

```powershell
git clone https://github.com/restspace/rs2-skill.git
cd rs2-skill
.\deploy.ps1
```

This copies `SKILL.md` and `references/` into:

- `%USERPROFILE%\.claude\skills\rs2` (Claude Code)
- `%USERPROFILE%\.codex\skills\rs2` (Codex)

Re-run `.\deploy.ps1` after pulling updates — it replaces the target
directories cleanly so removed files don't linger. Use `.\deploy.ps1 -WhatIf`
to preview without writing.

No PowerShell available? Copy `SKILL.md` and `references/` by hand into your
agent's skills directory under a `rs2` folder.

## Contents

| File | Covers |
| --- | --- |
| `SKILL.md` | Orientation, auth, errors, idempotency, composition, extension — the entry point |
| `references/services.md` | The prebuilt services (`file`, `data`, `pipeline`, `query`, `template`, `auth`, `services`, `log`) |
| `references/http-api.md` | Exact endpoint shapes for discovery, auth, errors, idempotency, limits |
| `references/pipelines.md` | Authoring/debugging pipeline specs, conditions, transforms, retry policies |
| `references/custom-services.md` | Writing, validating, and deploying custom JS/Wasm services and capability grants |
| `references/cli.md` | The `rs2` CLI, `serverConfig.json`/tenant configs, v1 migration |
| `references/v1-patterns.md` | Mapping Restspace v1 pattern vocabulary onto RS2 |

## License

AGPL-3.0-only — see [`LICENSE`](LICENSE).
