#!/bin/sh
# Tests init.sh against a fake swctl. Run: sh test-init.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
checks=0

# The fake swctl logs every call to $WORK/calls and behaves according to FAKE_* variables:
#   FAKE_CLIENTS   output of list-service-clients (success)
#   FAKE_LIST_FAIL=1  list-service-clients fails (authservice unreachable)
#   FAKE_ENSURE_FAIL=1  ensure-service-client fails
cat > "$WORK/swctl" <<'EOF'
#!/bin/sh
echo "$*" >> "$WORK/calls"
case "$2" in
  list-service-clients)
    [ "${FAKE_LIST_FAIL:-0}" = 1 ] && { echo "connection refused" >&2; exit 1; }
    printf '%s\n' "${FAKE_CLIENTS:-}"
    ;;
  delete-service-client) ;;
  ensure-service-client)
    [ "${FAKE_ENSURE_FAIL:-0}" = 1 ] && exit 1
    while [ $# -gt 0 ]; do
      [ "$1" = "--output" ] && out="$2"
      shift
    done
    printf 'SWAYRIDER_API_CLIENT_ID=new-id\nSWAYRIDER_API_CLIENT_SECRET=new-secret\n' > "$out"
    ;;
esac
EOF
chmod +x "$WORK/swctl"

SCOPES="region:query routing:execute search:execute tiles:serve"

# run <name> [VAR=value ...] — a fresh credentials dir with a stored client old-id, then init.sh.
run() {
    name="$1"; shift
    export WORK
    CREDS_DIR="$WORK/creds-$name"
    mkdir -p "$CREDS_DIR"
    : > "$WORK/calls"
    if [ "${NO_FILES:-0}" != 1 ]; then
        printf 'SWAYRIDER_API_CLIENT_ID=old-id\nSWAYRIDER_API_CLIENT_SECRET=old-secret\n' > "$CREDS_DIR/swayrider-api.env"
        printf '%s' "${STORED_SCOPES:-$SCOPES}" > "$CREDS_DIR/swayrider-api.scopes"
    fi
    env CREDS_DIR="$CREDS_DIR" SWCTL="$WORK/swctl" REQUIRED_SCOPES="$SCOPES" RETRY_DELAY=0 "$@" \
        sh "$HERE/init.sh" > "$WORK/out-$name" 2>&1
    status=$?
    CREDS="$CREDS_DIR"
    return $status
}

check() {
    checks=$((checks + 1))
    if ! eval "$2"; then
        failures=$((failures + 1))
        echo "FAIL: $1  [$2]"
        echo "  --- output ---"
        sed 's/^/  /' "$WORK/out-$CURRENT" 2>/dev/null
        echo "  --- calls ---"
        sed 's/^/  /' "$WORK/calls"
    fi
}

calls() { cat "$WORK/calls"; }
called() { calls | grep -q "$1"; }
stored_id() { grep '^SWAYRIDER_API_CLIENT_ID=' "$CREDS/swayrider-api.env" | cut -d= -f2; }

# 1. stored client exists in authservice -> skip, no registration
CURRENT=present
run present FAKE_CLIENTS="| swayrider-api | old-id | $SCOPES |"; rc=$?
check "present: exits 0" '[ $rc -eq 0 ]'
check "present: skips" 'grep -q "Skipping" "$WORK/out-present"'
check "present: does not register" '! called ensure-service-client'
check "present: does not delete" '! called delete-service-client'
check "present: keeps the stored id" '[ "$(stored_id)" = old-id ]'

# 2. authservice has no clients (the incident) -> delete, re-register, new credentials
CURRENT=missing
run missing FAKE_CLIENTS="+------+----------+"; rc=$?
check "missing: exits 0" '[ $rc -eq 0 ]'
check "missing: says why" 'grep -q "not known to authservice" "$WORK/out-missing"'
check "missing: deletes the old id" 'called "delete-service-client old-id"'
check "missing: registers" 'called ensure-service-client'
check "missing: new id stored" '[ "$(stored_id)" = new-id ]'
check "missing: scopes file rewritten" '[ "$(cat "$CREDS/swayrider-api.scopes")" = "$SCOPES" ]'
check "missing: reminds to restart the gateway" 'grep -q "restart swayrider-api" "$WORK/out-missing"'

# 3. a different client is listed, not ours -> missing
CURRENT=other
run other FAKE_CLIENTS="| tilesservice | some-other-id | tiles:serve |"; rc=$?
check "other client only: re-registers" 'called ensure-service-client'

# 5. authservice unreachable -> keep the stored credentials, warn, exit 0 (old behaviour)
CURRENT=unknown
run unknown FAKE_LIST_FAIL=1; rc=$?
check "unreachable: exits 0" '[ $rc -eq 0 ]'
check "unreachable: warns" 'grep -q "could not ask authservice" "$WORK/out-unknown"'
check "unreachable: does not register or delete" '! called ensure-service-client && ! called delete-service-client'
check "unreachable: keeps the stored id" '[ "$(stored_id)" = old-id ]'
check "unreachable: tried several times" '[ "$(calls | grep -c list-service-clients)" -eq 5 ]'

# 6. scope mismatch -> re-register without asking for the list
CURRENT=scopes
STORED_SCOPES="region:query"
run scopes FAKE_CLIENTS="| swayrider-api | old-id |"; rc=$?
STORED_SCOPES=""
check "scope mismatch: says so" 'grep -q "Scope mismatch" "$WORK/out-scopes"'
check "scope mismatch: re-registers" 'called ensure-service-client'
check "scope mismatch: new id" '[ "$(stored_id)" = new-id ]'

# 7. FORCE_REREGISTER -> re-register even if the client exists
CURRENT=force
run force FORCE_REREGISTER=true FAKE_CLIENTS="| swayrider-api | old-id |"; rc=$?
check "force: re-registers" 'called ensure-service-client'
check "force: deletes the old one" 'called "delete-service-client old-id"'
check "force: new id" '[ "$(stored_id)" = new-id ]'

# 8. first install (no files) -> register, nothing to delete, no list call
CURRENT=fresh
NO_FILES=1
run fresh; rc=$?
NO_FILES=0
check "fresh: exits 0" '[ $rc -eq 0 ]'
check "fresh: registers" 'called ensure-service-client'
check "fresh: nothing to delete" '! called delete-service-client'
check "fresh: does not list" '! called list-service-clients'
check "fresh: id stored" '[ "$(stored_id)" = new-id ]'

# 9. credentials file without a client id -> treated as missing
CURRENT=noid
mkdir -p "$WORK/creds-noid"
printf 'SOMETHING_ELSE=1\n' > "$WORK/creds-noid/swayrider-api.env"
printf '%s' "$SCOPES" > "$WORK/creds-noid/swayrider-api.scopes"
: > "$WORK/calls"
env CREDS_DIR="$WORK/creds-noid" SWCTL="$WORK/swctl" REQUIRED_SCOPES="$SCOPES" RETRY_DELAY=0 WORK="$WORK" \
    sh "$HERE/init.sh" > "$WORK/out-noid" 2>&1
check "no id in file: re-registers" 'called ensure-service-client'
check "no id in file: nothing to delete" '! called delete-service-client'

# 10. registration fails -> non-zero exit, and the old files stay removed (not half-written)
CURRENT=ensurefail
run ensurefail FAKE_CLIENTS="" FAKE_ENSURE_FAIL=1; rc=$?
check "ensure fails: exits non-zero" '[ $rc -ne 0 ]'
check "ensure fails: no scopes file claims success" '[ ! -f "$CREDS/swayrider-api.scopes" ]'

echo "$((checks - failures))/$checks checks passed"
[ "$failures" -eq 0 ]
