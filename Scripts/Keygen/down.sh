#!/usr/bin/env bash
# Tears the harness down and wipes its data: `-v` removes the Postgres/Redis
# volumes so the next `up.sh` provisions a clean account from scratch. Also removes
# the minted-token file. Safe to run when nothing is up.
set -euo pipefail
cd "$(dirname "$0")"

# --env-file: compose interpolates ${...} in the compose file on `down` too, and only
# auto-loads a file literally named ".env" — point it at the renamed fake config so it
# resolves cleanly instead of warning about unset variables.
docker compose --env-file .env.docker.fake --profile setup down -v --remove-orphans
rm -f .runtime.env
echo "==> Harness down, volumes wiped, .runtime.env removed"
