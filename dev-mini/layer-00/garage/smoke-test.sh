#!/bin/bash
# Smoke test for the Garage object store (needs the AWS CLI): put/get, ranged GET, multipart upload,
# pointer overwrite, read-only key. Leaves nothing behind (objects live under a temporary prefix).
#
#   ./garage/smoke-test.sh [size-in-MB]     # default 1100 MB (multipart, > 5 GB parts are not needed)
#
# Reads ./.env (or the environment): GARAGE_S3_PORT, GARAGE_TILES_BUCKET, GARAGE_RW_*, GARAGE_RO_*.
# Use GARAGE_ENDPOINT to test through another address (e.g. the WireGuard IP from the data-manager host).
set -euo pipefail

cd "$(dirname "$0")/.."
if [ -f .env ]; then set -a; . ./.env; set +a; fi

ENDPOINT="${GARAGE_ENDPOINT:-http://127.0.0.1:${GARAGE_S3_PORT:-39000}}"
BUCKET="${GARAGE_TILES_BUCKET:-swayrider-tiles}"
SIZE_MB="${1:-1100}"
PREFIX="smoke-test-$$"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; s3rw rm "s3://$BUCKET/$PREFIX/" --recursive >/dev/null 2>&1 || true' EXIT

s3rw() { AWS_ACCESS_KEY_ID="$GARAGE_RW_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$GARAGE_RW_SECRET_KEY" AWS_DEFAULT_REGION=garage \
  aws --endpoint-url "$ENDPOINT" s3 "$@"; }
apirw() { AWS_ACCESS_KEY_ID="$GARAGE_RW_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$GARAGE_RW_SECRET_KEY" AWS_DEFAULT_REGION=garage \
  aws --endpoint-url "$ENDPOINT" s3api "$@"; }
apiro() { AWS_ACCESS_KEY_ID="$GARAGE_RO_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$GARAGE_RO_SECRET_KEY" AWS_DEFAULT_REGION=garage \
  aws --endpoint-url "$ENDPOINT" s3api "$@"; }
ok() { echo "ok   $*"; }
fail() { echo "FAIL $*" >&2; exit 1; }

echo "Endpoint $ENDPOINT, bucket $BUCKET"

# 1. small put/get
echo "hello" > "$TMP/hello.txt"
s3rw cp "$TMP/hello.txt" "s3://$BUCKET/$PREFIX/hello.txt" >/dev/null
s3rw cp "s3://$BUCKET/$PREFIX/hello.txt" "$TMP/hello.out" >/dev/null
cmp "$TMP/hello.txt" "$TMP/hello.out" && ok "put/get"

# 2. pointer overwrite is visible immediately
echo '{"release":"a"}' > "$TMP/a.json"; echo '{"release":"b"}' > "$TMP/b.json"
s3rw cp "$TMP/a.json" "s3://$BUCKET/$PREFIX/current.json" >/dev/null
s3rw cp "$TMP/b.json" "s3://$BUCKET/$PREFIX/current.json" >/dev/null
s3rw cp "s3://$BUCKET/$PREFIX/current.json" - | grep -q '"b"' && ok "pointer overwrite"

# 3. multipart upload of a large file (the CLI switches to multipart above 8 MB), then ranged reads
echo "Creating ${SIZE_MB} MB test file ..."
dd if=/dev/urandom of="$TMP/big.bin" bs=1048576 count="$SIZE_MB" 2>/dev/null
s3rw cp "$TMP/big.bin" "s3://$BUCKET/$PREFIX/big.bin" >/dev/null
REMOTE_SIZE="$(apirw head-object --bucket "$BUCKET" --key "$PREFIX/big.bin" --query ContentLength --output text)"
[ "$REMOTE_SIZE" = "$(stat -f%z "$TMP/big.bin" 2>/dev/null || stat -c%s "$TMP/big.bin")" ] && ok "multipart upload size ($REMOTE_SIZE bytes)"

for r in "0-126" "1000000-1000999" "$(( (SIZE_MB * 1048576) - 100 ))-$(( SIZE_MB * 1048576 - 1 ))"; do
  apirw get-object --bucket "$BUCKET" --key "$PREFIX/big.bin" --range "bytes=$r" "$TMP/range.out" >/dev/null
  start="${r%-*}"; end="${r#*-}"; len=$(( end - start + 1 ))
  tail -c +"$((start + 1))" "$TMP/big.bin" | head -c "$len" | cmp - "$TMP/range.out" && ok "ranged GET bytes=$r"
done

# 4. conditional GET (ETag) — informational, tilesservice does not depend on it
ETAG="$(apirw head-object --bucket "$BUCKET" --key "$PREFIX/hello.txt" --query ETag --output text)"
if apirw get-object --bucket "$BUCKET" --key "$PREFIX/hello.txt" --if-none-match "$ETAG" "$TMP/x" >/dev/null 2>&1; then
  echo "info If-None-Match not honoured (200)"; else ok "If-None-Match returns 304"; fi

# 5. read-only key: can read, cannot write
apiro get-object --bucket "$BUCKET" --key "$PREFIX/hello.txt" "$TMP/ro.out" >/dev/null && ok "read-only key reads"
if apiro put-object --bucket "$BUCKET" --key "$PREFIX/denied.txt" --body "$TMP/hello.txt" >/dev/null 2>&1; then
  fail "read-only key could write"; else ok "read-only key cannot write"; fi

echo "All checks passed."
