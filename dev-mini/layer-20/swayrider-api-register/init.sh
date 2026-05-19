#!/bin/sh
set -e

CREDS_FILE="/credentials/swayrider-api.env"
SCOPES_FILE="/credentials/swayrider-api.scopes"
CLIENT_NAME="swayrider-api"

# REQUIRED_SCOPES and FORCE_REREGISTER come from container environment.
# REQUIRED_SCOPES — space-separated, must be sorted for stable comparison.
# FORCE_REREGISTER — set to "true" to always delete and re-register.
: "${REQUIRED_SCOPES:?REQUIRED_SCOPES env var is required}"
: "${FORCE_REREGISTER:=false}"

# ── Fast path ─────────────────────────────────────────────────────────────────
if [ "$FORCE_REREGISTER" != "true" ] && [ -f "$CREDS_FILE" ] && [ -f "$SCOPES_FILE" ]; then
    REGISTERED="$(cat "$SCOPES_FILE")"
    if [ "$REGISTERED" = "$REQUIRED_SCOPES" ]; then
        echo "Service client '$CLIENT_NAME' already registered with correct scopes. Skipping."
        exit 0
    fi
    echo "Scope mismatch: registered='$REGISTERED', required='$REQUIRED_SCOPES'"
elif [ "$FORCE_REREGISTER" = "true" ]; then
    echo "FORCE_REREGISTER=true — re-registering regardless of current state."
fi

# ── Clean up old client ───────────────────────────────────────────────────────
if [ -f "$CREDS_FILE" ]; then
    CLIENT_ID="$(grep '^SWAYRIDER_API_CLIENT_ID=' "$CREDS_FILE" | cut -d= -f2)"
    if [ -n "$CLIENT_ID" ]; then
        echo "Deleting old service client '$CLIENT_ID'..."
        /app/swctl auth delete-service-client "$CLIENT_ID" \
            || echo "Warning: could not delete client '$CLIENT_ID' (may already be gone)"
    fi
    rm -f "$CREDS_FILE" "$SCOPES_FILE"
fi

# ── Register with correct scopes ──────────────────────────────────────────────
echo "Registering '$CLIENT_NAME' with scopes: $REQUIRED_SCOPES"
# shellcheck disable=SC2086  — intentional word-splitting for variadic scopes
/app/swctl auth ensure-service-client \
    --output "$CREDS_FILE" \
    --retries 15 \
    "$CLIENT_NAME" \
    $REQUIRED_SCOPES

echo "$REQUIRED_SCOPES" > "$SCOPES_FILE"
echo "Registration complete."
