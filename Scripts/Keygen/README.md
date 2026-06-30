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

## Do NOT run this locally on Apple Silicon — it runs on CI

The `keygen/api` image is **x86_64 only** (`platform: linux/amd64`). On CI's
x86_64 ubuntu runners it boots natively; on an Apple Silicon (M-series) Mac it runs
under **QEMU emulation**, where the first boot is so slow it is effectively unusable
(it times out pulling + booting before the proxy serves). **CI is the source of
truth for the integration suite — don't try to boot the harness on a Mac.** When you
need to prove a Keygen wire-shape locally, ground it against the docs + the hermetic
unit tests and let CI's `keygen-integration` job run the real-CE assertions.

## Usage (CI, or x86_64 hosts only)

```bash
Scripts/Keygen/up.sh        # boot CE, provision, mint admin token → .runtime.env
( cd Scripts/Keygen && deno task test:integration )
Scripts/Keygen/down.sh      # tear down + wipe volumes + remove .runtime.env
```

`up.sh` writes `Scripts/Keygen/.runtime.env` (plain `KEY=val`):

```
KEYGEN_BASE_URL=http://localhost:8080
KEYGEN_ACCOUNT=<the account UUID from .env.docker.fake>
KEYGEN_TOKEN=admin-...        # minted fresh each run; gitignored, never committed
KEYGEN_PUBLIC_KEY=<64 hex>    # the account Ed25519 public key, for offline machine-file verify
```

The integration tests read it via `deno --env-file`. They **fail loudly** if it is
absent — a missing harness is a hard error, never a silent skip.

## What's in the box

| File | Role |
|------|------|
| `docker-compose.yml` | Postgres 15 + Redis 7 + `keygen/api:v1.6.0` (web) + Caddy proxy |
| `.env.docker.fake` | Throwaway config (fake account UUID, admin creds, encryption keys) — committed. Named `.docker.fake` (not `.env`) so it's unmistakably non-real to humans and AI; loaded via `--env-file`, since compose only auto-loads a file named `.env` |
| `Caddyfile` | Injects `X-Forwarded-Proto: https` so Keygen's `force_ssl` serves 200 |
| `up.sh` | Boot → headless setup → mint admin token → write `.runtime.env` |
| `down.sh` | `docker compose down -v` + remove `.runtime.env` |
| `bootstrap-keygen.ts` | Idempotent Keygen structure provisioner (product / policies / entitlements); also the prod-ops tool |
| `bootstrap-keygen.test.ts` | Hermetic unit tests for the bootstrap script (fake `fetch`) — run by `precheck` every commit |
| `integration/` | Real-CE integration tests (bootstrap round-trip + offline machine path + **paid-path: a `STOWER_V0` license validates and checks out a signed file carrying the entitlement, no Lemon Squeezy**) — `deno task test:integration` |
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
  admin email/password (all in `.env.docker.fake`).
- **The admin token is minted at runtime**, not stored: `bundle exec rails runner
  "...admins.first.tokens.create(name:).raw"` (the entrypoint has no bare `rails`,
  and echoes `Running command:` to stdout — so `up.sh` greps the `admin-` prefix).
- **Architecture:** the `keygen/api` image is x86_64 (`platform: linux/amd64`):
  **native on CI's ubuntu runners; on Apple Silicon it runs under QEMU emulation,
  where the first boot is too slow to be usable in practice (it times out before the
  proxy serves).** CI is the source of truth — do NOT boot the harness on an M-series
  Mac; ground local work against the docs + hermetic unit tests and let CI run the
  real-CE integration assertions.
  - **Untested arm64 lead (a spike, not a promise):** Docker Hub *does* publish
    `keygen/api:v1.6.0` for **`linux/arm64`** as well as amd64 — our
    `docker-compose.yml` explicitly pins `platform: linux/amd64`, which is what forces
    the slow emulation. BUT Keygen's self-hosting docs state the server **requires
    x86_64 + SSE 4.2**, so the arm64 image is published best-effort and **unverified**
    (it may fail at runtime). If fast *local* Mac runs ever matter: spike it — drop the
    `platform: linux/amd64` pin, `up.sh`, and see if the native arm64 image boots +
    passes `deno task test:integration`. If it works, local Mac runs become possible;
    if not (the SSE 4.2 dependency), we stay CI-only. Low priority — CI already covers
    it, and the integration tests run locally against a *real Keygen account* (env
    override) with no Docker at all.
- **`.env.docker.fake` is committed and throwaway** because the DB is ephemeral
  (`down.sh -v` wipes it). It's named `.docker.fake` rather than `.env` precisely so
  nobody (human or AI) mistakes it for real credentials. The only secret-bearing file
  is `.runtime.env`, which is gitignored.
