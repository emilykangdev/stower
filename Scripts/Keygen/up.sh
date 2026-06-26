#!/usr/bin/env bash
# Boots the throwaway Keygen CE harness and writes Scripts/Keygen/.runtime.env with
# the live { base URL, account, freshly-minted admin token } the integration tests
# read via `deno --env-file`. Idempotent enough to re-run; pair with down.sh to wipe.
#
# Fails loudly on any step — a half-up harness must not look ready. The token is
# minted at runtime and never committed (.runtime.env is gitignored).
set -euo pipefail
cd "$(dirname "$0")"

# Compose reads .env itself for interpolation; the script also needs KEYGEN_ACCOUNT_ID.
set -a
# shellcheck disable=SC1091
source ./.env
set +a

readonly BASE_URL="http://localhost:8080"
readonly RUNTIME_ENV=".runtime.env"
# The proxy returns 502/503 while the API is still booting; any other HTTP status
# (200/400/401/403/404) means Keygen is serving. 000 is curl's "no response yet".
readonly READY_TIMEOUT_SECONDS=180

compose() { docker compose "$@"; }

echo "==> Starting Postgres + Redis"
compose up -d pg redis

echo "==> Headless setup (account + admin + migrations)"
compose run --rm setup

echo "==> Starting Keygen web + proxy"
compose up -d api proxy

echo "==> Waiting for the proxy to serve Keygen (up to ${READY_TIMEOUT_SECONDS}s)"
deadline=$((SECONDS + READY_TIMEOUT_SECONDS))
status="000"
while :; do
  # On a connection failure curl prints "000" AND exits non-zero; the `|| status=…`
  # (not `|| echo`, which would CONCATENATE onto curl's "000") keeps the var clean
  # under `set -e`. A 404 here still means the stack is serving (CE singleplayer
  # 404s GET /v1/accounts/{id}), so only no-response / proxy-still-booting waits.
  status=$(curl -s -o /dev/null -w '%{http_code}' "${BASE_URL}/v1/accounts/${KEYGEN_ACCOUNT_ID}") || status="000"
  case "$status" in
    000 | 502 | 503) : ;;          # no response / proxy up but API still booting
    *) break ;;                     # any real HTTP status means Keygen is serving
  esac
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "ERROR: Keygen did not become ready within ${READY_TIMEOUT_SECONDS}s (last status: ${status})" >&2
    compose logs api proxy >&2 || true
    exit 1
  fi
  sleep 2
done
echo "==> Keygen is serving (HTTP ${status})"

echo "==> Minting an admin token + reading the account Ed25519 public key"
# Both come from one `bundle exec rails runner` (the entrypoint has no bare `rails`)
# — ONE Rails boot instead of two, which matters under arm64 emulation where each
# cold boot is slow. `-T` disables TTY so the captured output is clean in CI. The
# entrypoint echoes "Running command: ..." noise to stdout, so each value carries a
# sentinel prefix and is grepped by that, never by line position. CE does not expose
# the account over GET /v1/accounts/{id} (404 in singleplayer), so the key is read
# from the DB — the same key the Mac app embeds as a build-time constant.
provision="$(compose run --rm -T api bundle exec rails runner '
  a = Account.find(ENV["KEYGEN_ACCOUNT_ID"])
  STDOUT.puts "KGTOKEN=" + a.admins.first.tokens.create(name: "integration").raw
  STDOUT.puts "KGPUBKEY=" + a.ed25519_public_key
' 2>/dev/null)"

token="$(printf '%s\n' "${provision}" | grep -aoE 'KGTOKEN=admin-[A-Za-z0-9._-]+' | head -1 | cut -d= -f2-)"
public_key="$(printf '%s\n' "${provision}" | grep -aoE 'KGPUBKEY=[0-9a-f]{64}' | head -1 | cut -d= -f2-)"

if [ -z "${token}" ]; then
  echo "ERROR: failed to mint an admin token (empty result)" >&2
  exit 1
fi
if [ -z "${public_key}" ]; then
  echo "ERROR: failed to read the account Ed25519 public key (empty result)" >&2
  exit 1
fi

echo "==> Writing ${RUNTIME_ENV} (plain KEY=val for deno --env-file; gitignored)"
# Plain KEY=val, NO `export` — `deno --env-file` parses dotenv, not shell.
cat > "${RUNTIME_ENV}" <<EOF
KEYGEN_BASE_URL=${BASE_URL}
KEYGEN_ACCOUNT=${KEYGEN_ACCOUNT_ID}
KEYGEN_TOKEN=${token}
KEYGEN_PUBLIC_KEY=${public_key}
EOF

echo "==> Harness up. Creds in Scripts/Keygen/${RUNTIME_ENV}"
echo "    Run: ( cd Scripts/Keygen && deno task test:integration )"
