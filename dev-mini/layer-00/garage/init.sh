#!/bin/bash
# One-time (idempotent) setup of the Garage object store: single-node layout, the tiles bucket and
# two access keys (read/write for the data-manager deploy, read-only for tilesservice).
#
# Run on the dev-mini host after `docker compose -f compose.yaml up -d garage`:
#   ./garage/init.sh            # reads ./.env (or the current environment)
#
# Keys are taken from the environment, never generated here, so they stay in your secret store:
#   GARAGE_RW_ACCESS_KEY_ID / GARAGE_RW_SECRET_KEY   (id: GK + 24 hex chars, secret: 64 hex chars)
#   GARAGE_RO_ACCESS_KEY_ID / GARAGE_RO_SECRET_KEY
# Generate a pair with:  echo "GK$(openssl rand -hex 12)"; openssl rand -hex 32
set -euo pipefail

cd "$(dirname "$0")/.."
if [ -f .env ]; then set -a; . ./.env; set +a; fi

CONTAINER="${GARAGE_CONTAINER:-sw-dev-garage}"
BUCKET="${GARAGE_TILES_BUCKET:-swayrider-tiles}"
CAPACITY="${GARAGE_CAPACITY:-1T}"   # only a hint for data placement on a single node
ZONE="${GARAGE_ZONE:-dc1}"

for v in GARAGE_RW_ACCESS_KEY_ID GARAGE_RW_SECRET_KEY GARAGE_RO_ACCESS_KEY_ID GARAGE_RO_SECRET_KEY; do
  [ -n "${!v:-}" ] || { echo "error: $v is not set (see env.example, section 6)" >&2; exit 1; }
done

garage() { docker exec "$CONTAINER" /garage "$@"; }

echo "Waiting for $CONTAINER ..."
for _ in $(seq 1 30); do garage status >/dev/null 2>&1 && break; sleep 1; done
garage status >/dev/null

# --- layout (single node) ---
NODE_ID="$(garage node id -q 2>/dev/null | cut -d@ -f1)"
if garage status | grep -q "NO ROLE ASSIGNED"; then
  echo "Assigning layout to node ${NODE_ID:0:16}…"
  garage layout assign -z "$ZONE" -c "$CAPACITY" "$NODE_ID"
  garage layout apply --version 1
else
  echo "Layout already applied."
fi

# --- bucket ---
if garage bucket info "$BUCKET" >/dev/null 2>&1; then
  echo "Bucket $BUCKET exists."
else
  echo "Creating bucket $BUCKET"
  garage bucket create "$BUCKET"
fi

# --- keys (imported from the environment) ---
import_key() { # <name> <id> <secret>
  if garage key info "$1" >/dev/null 2>&1; then
    echo "Key $1 exists."
  else
    echo "Importing key $1"
    garage key import --yes -n "$1" "$2" "$3" >/dev/null
  fi
}
import_key swayrider-tiles-rw "$GARAGE_RW_ACCESS_KEY_ID" "$GARAGE_RW_SECRET_KEY"
import_key swayrider-tiles-ro "$GARAGE_RO_ACCESS_KEY_ID" "$GARAGE_RO_SECRET_KEY"

garage bucket allow --read --write "$BUCKET" --key swayrider-tiles-rw >/dev/null
garage bucket allow --read "$BUCKET" --key swayrider-tiles-ro >/dev/null

echo "Done. S3 endpoint: http://<host>:${GARAGE_S3_PORT:-39000}, region garage, bucket $BUCKET, path-style."
