#!/bin/sh
# One-shot, idempotent setup of the Garage object store, run by the `garage-init` compose service
# (alpine + curl + jq) through Garage's admin API v2:
#   1. single-node cluster layout   2. the tiles bucket   3. two access keys imported from the
#   environment (read/write for the data-manager deploy, read-only for tilesservice).
# Safe to run on every `docker compose up`: existing layout, bucket and keys are left alone.
set -eu

API="${GARAGE_ADMIN_URL:-http://garage:3903}/v2"
BUCKET="${GARAGE_TILES_BUCKET:-swayrider-tiles}"
ZONE="${GARAGE_ZONE:-dc1}"
CAPACITY="${GARAGE_CAPACITY_BYTES:-1099511627776}"   # only a placement hint on a single node
: "${GARAGE_ADMIN_TOKEN:?GARAGE_ADMIN_TOKEN is not set}"
: "${GARAGE_RW_ACCESS_KEY_ID:?GARAGE_RW_ACCESS_KEY_ID is not set}"
: "${GARAGE_RW_SECRET_KEY:?GARAGE_RW_SECRET_KEY is not set}"
: "${GARAGE_RO_ACCESS_KEY_ID:?GARAGE_RO_ACCESS_KEY_ID is not set}"
: "${GARAGE_RO_SECRET_KEY:?GARAGE_RO_SECRET_KEY is not set}"

if ! command -v curl >/dev/null || ! command -v jq >/dev/null; then
  apk add --no-cache curl jq >/dev/null
fi

OUT="$(mktemp)"
# api <METHOD> <path[?query]> [json body]  -> body in $OUT, prints the HTTP status
api() {
  if [ "$#" -ge 3 ]; then
    curl -sS -o "$OUT" -w '%{http_code}' -X "$1" -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN" \
      -H 'Content-Type: application/json' -d "$3" "$API/$2"
  else
    curl -sS -o "$OUT" -w '%{http_code}' -X "$1" -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN" "$API/$2"
  fi
}
# must <METHOD> <path> [body]: fail with Garage's answer unless the status is 2xx
must() {
  code="$(api "$@")" || { echo "error: cannot reach $API" >&2; exit 1; }
  case "$code" in 2??) ;; *) echo "error: $1 $2 -> HTTP $code: $(cat "$OUT")" >&2; exit 1 ;; esac
}

echo "Waiting for the Garage admin API at $API ..."
i=0
until code="$(api GET GetClusterStatus 2>/dev/null || true)"; [ "$code" = "200" ]; do
  case "$code" in 401|403) echo "error: Garage rejected GARAGE_ADMIN_TOKEN (HTTP $code); it must match the token the garage container started with" >&2; exit 1 ;; esac
  i=$((i + 1)); [ "$i" -le 60 ] || { echo "error: Garage did not come up (last answer: $(cat "$OUT"))" >&2; exit 1; }
  sleep 2
done

# --- 1. layout (single node) ---
NODE_ID="$(jq -r '.nodes[0].id' "$OUT")"
if [ "$(jq -r '.nodes[0].role == null' "$OUT")" = "true" ]; then
  echo "Assigning the single-node layout to $(printf %.16s "$NODE_ID")…"
  must POST UpdateClusterLayout "{\"roles\":[{\"id\":\"$NODE_ID\",\"zone\":\"$ZONE\",\"capacity\":$CAPACITY,\"tags\":[]}]}"
  must GET GetClusterLayout
  # Garage ignores fields it does not know and answers 200, so check that the role really is staged
  [ "$(jq -r '(.stagedRoleChanges // []) | length' "$OUT")" -ge 1 ] \
    || { echo "error: UpdateClusterLayout was accepted but staged no role: $(cat "$OUT")" >&2; exit 1; }
  VERSION="$(jq -r '.version + 1' "$OUT")"
  must POST ApplyClusterLayout "{\"version\":$VERSION}"
  echo "Layout applied (version $VERSION)."
else
  echo "Layout already applied."
fi

# --- 2. bucket ---
code="$(api GET "GetBucketInfo?globalAlias=$BUCKET")"
if [ "$code" = "200" ]; then
  echo "Bucket $BUCKET exists."
else
  echo "Creating bucket $BUCKET"
  j=0
  until [ "$(api POST CreateBucket "{\"globalAlias\":\"$BUCKET\"}")" = "200" ]; do   # the layout needs a moment
    j=$((j + 1)); [ "$j" -le 15 ] || { echo "error: CreateBucket failed: $(cat "$OUT")" >&2; exit 1; }
    sleep 2
  done
  must GET "GetBucketInfo?globalAlias=$BUCKET"
fi
BUCKET_ID="$(jq -r '.id' "$OUT")"

# --- 3. keys, imported from the environment ---
ensure_key() { # <name> <id> <secret>
  code="$(api GET "GetKeyInfo?id=$2")"
  if [ "$code" = "200" ]; then
    echo "Key $1 exists."
  else
    echo "Importing key $1"
    must POST ImportKey "{\"name\":\"$1\",\"accessKeyId\":\"$2\",\"secretAccessKey\":\"$3\"}"
  fi
}
ensure_key swayrider-tiles-rw "$GARAGE_RW_ACCESS_KEY_ID" "$GARAGE_RW_SECRET_KEY"
ensure_key swayrider-tiles-ro "$GARAGE_RO_ACCESS_KEY_ID" "$GARAGE_RO_SECRET_KEY"

must POST AllowBucketKey "{\"bucketId\":\"$BUCKET_ID\",\"accessKeyId\":\"$GARAGE_RW_ACCESS_KEY_ID\",\"permissions\":{\"read\":true,\"write\":true}}"
must POST AllowBucketKey "{\"bucketId\":\"$BUCKET_ID\",\"accessKeyId\":\"$GARAGE_RO_ACCESS_KEY_ID\",\"permissions\":{\"read\":true}}"

echo "Garage ready: bucket $BUCKET, keys swayrider-tiles-rw (read/write) and swayrider-tiles-ro (read-only)."
