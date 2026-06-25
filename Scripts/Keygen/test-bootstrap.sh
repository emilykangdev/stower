#!/usr/bin/env bash
# One-shot local verification of the Keygen CE harness + bootstrap script.
#
# This path is deliberately webhook-free and Railway-free: it boots the throwaway
# Keygen CE, runs the REAL bootstrap script against it (prints the created ids),
# then runs the real-CE integration suite (the regression net). It NEVER touches
# the Supabase webhook (handlers.ts handleWebhook / index.ts) or Railway — the
# integration suite imports only bootstrap-keygen.ts + harness.ts.
#
# Always tears the harness down — even on failure — so no containers/volumes leak.
# Requires Docker running. On Apple Silicon the keygen/api image is amd64, so the
# first boot runs emulated and is slow (minutes). Fails loudly on any step.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

cleanup() {
  echo "==> Tearing down the Keygen CE harness"
  Scripts/Keygen/down.sh || true
}
trap cleanup EXIT

echo "==> [1/3] Booting the Keygen CE harness (Scripts/Keygen/up.sh)"
Scripts/Keygen/up.sh

echo "==> [2/3] Running the bootstrap script standalone against local Keygen CE"
echo "         (no Supabase webhook, no Railway — just Keygen structures)"
# Absolute --env-file path: `deno run` resolves a relative --env-file against the
# CWD (here supabase/functions/license), NOT against the deno.json dir the way
# `deno task` does — so a relative `../../Scripts/Keygen` would miss. The absolute
# path from $REPO_ROOT is robust regardless of CWD.
( cd supabase/functions/license &&
  deno run --allow-net=localhost --allow-env \
    --env-file="$REPO_ROOT/Scripts/Keygen/.runtime.env" \
    scripts/bootstrap-keygen.ts )

echo "==> [3/3] Running the real-CE integration suite (the regression net)"
( cd supabase/functions/license && deno task test:integration )

echo "==> All green. Harness teardown runs next via the EXIT trap."
