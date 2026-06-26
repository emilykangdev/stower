# Local Keygen CE test harness

A throwaway, self-hosted **Keygen Community Edition** instance the licensing
integration tests run against. It gives Stower's licensing code a *real* Keygen to
prove its JSON:API payloads against — closing the gap that let a `page[number]` bug
ship past 13 stub-based unit tests (the stubs proved our logic, not that real Keygen
accepts our requests).

Zero production, zero Keygen Cloud. Everything here is fake and ephemeral.

This folder is the single home for **everything Keygen**: the CE Docker harness,
the `bootstrap-keygen.ts` provisioning script, and its Deno tests (hermetic unit +
real-CE integration). It is a self-contained Deno project (`deno.json`).

## Usage

```bash
Scripts/Keygen/up.sh        # boot CE, provision, mint admin token → .runtime.env
( cd Scripts/Keygen && deno task test:integration )
Scripts/Keygen/down.sh      # tear down + wipe volumes + remove .runtime.env
```

`up.sh` writes `Scripts/Keygen/.runtime.env` (plain `KEY=val`):

```
KEYGEN_BASE_URL=http://localhost:8080
KEYGEN_ACCOUNT=<the account UUID from .env>
KEYGEN_TOKEN=admin-...        # minted fresh each run; gitignored, never committed
KEYGEN_PUBLIC_KEY=<64 hex>    # the account Ed25519 public key, for offline machine-file verify
```

The integration tests read it via `deno --env-file`. They **fail loudly** if it is
absent — a missing harness is a hard error, never a silent skip.

## What's in the box

| File | Role |
|------|------|
| `docker-compose.yml` | Postgres 15 + Redis 7 + `keygen/api:v1.6.0` (web) + Caddy proxy |
| `.env` | Throwaway config (fake account UUID, admin creds, encryption keys) — committed |
| `Caddyfile` | Injects `X-Forwarded-Proto: https` so Keygen's `force_ssl` serves 200 |
| `up.sh` | Boot → headless setup → mint admin token → write `.runtime.env` |
| `down.sh` | `docker compose down -v` + remove `.runtime.env` |
| `bootstrap-keygen.ts` | Idempotent Keygen structure provisioner (product / policies / entitlements); also the prod-ops tool |
| `bootstrap-keygen.test.ts` | Hermetic unit tests for the bootstrap script (fake `fetch`) — run by `precheck` every commit |
| `integration/` | Real-CE integration tests (bootstrap round-trip + offline machine path) — `deno task test:integration` |
| `deno.json` / `deno.integration.json` | Deno project config + exclude-free override that lets the integration task run |
| `test-bootstrap.sh` | One-shot local runner: up → bootstrap → integration → auto-teardown |

## Recipe notes (empirically verified by the 2026-06-24 Docker spike)

- **Pinned to `keygen/api:v1.6.0`** — the last release before ClickHouse became a
  hard dependency (v1.7.0+). v1.6.0 boots on **Postgres + Redis only**; ClickHouse
  powers request-log analytics we never use (prod gets analytics from Keygen Cloud).
- **`KEYGEN_DOMAIN` is required at runtime** in addition to `KEYGEN_HOST` — without
  it, boot crashes on a nil `Keygen::DOMAIN` (undocumented).
- **`force_ssl` is hardcoded** in v1.6.0; plain HTTP 301s. The Caddy proxy injects
  `X-Forwarded-Proto: https` so clients use plain HTTP on `:8080` unmodified. Always
  talk to `:8080`, never the API's `:3000` directly.
- **Headless `setup`** creates the account + admin **and runs migrations** in one
  step — no separate migrate. It needs the encryption keys + `KEYGEN_ACCOUNT_ID` +
  admin email/password (all in `.env`).
- **The admin token is minted at runtime**, not stored: `bundle exec rails runner
  "...admins.first.tokens.create(name:).raw"` (the entrypoint has no bare `rails`,
  and echoes `Running command:` to stdout — so `up.sh` greps the `admin-` prefix).
- **Architecture:** the `keygen/api` image is x86_64 (`platform: linux/amd64`):
  **native on CI's ubuntu runners, emulated (slower first boot) on Apple Silicon.**
  CI is the source of truth; local arm64 runs are on-demand under emulation.
- **`.env` is committed and throwaway** because the DB is ephemeral (`down.sh -v`
  wipes it). The only secret-bearing file is `.runtime.env`, which is gitignored.
