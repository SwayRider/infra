#!/bin/sh
set -e

# CREDS_DIR and SWCTL are overridable for testing (test-init.sh); in the container they are the defaults.
CREDS_DIR="${CREDS_DIR:-/credentials}"
SWCTL="${SWCTL:-/app/swctl}"
CREDS_FILE="$CREDS_DIR/swayrider-api.env"
SCOPES_FILE="$CREDS_DIR/swayrider-api.scopes"
CLIENT_NAME="swayrider-api"

# REQUIRED_SCOPES and FORCE_REREGISTER come from container environment.
# REQUIRED_SCOPES — space-separated, must be sorted for stable comparison.
# FORCE_REREGISTER — set to "true" to always delete and re-register.
: "${REQUIRED_SCOPES:?REQUIRED_SCOPES env var is required}"
: "${FORCE_REREGISTER:=false}"

# stored_client_id prints the client id from the credentials file (empty if there is none).
stored_client_id() {
    grep '^SWAYRIDER_API_CLIENT_ID=' "$CREDS_FILE" 2>/dev/null | cut -d= -f2 || true
}

# client_status asks authservice whether the stored client still exists and prints
#   present  — authservice knows the client id
#   missing  — authservice does not (database reset, client deleted, or no id in the file)
#   unknown  — authservice could not be asked (not reachable after a few tries)
# The files on disk alone prove nothing: the credentials volume outlives the authservice database.
client_status() {
    id="$(stored_client_id)"
    if [ -z "$id" ]; then
        echo missing
        return
    fi
    attempt=1
    while [ "$attempt" -le 5 ]; do
        if clients="$("$SWCTL" auth list-service-clients)"; then
            if printf '%s\n' "$clients" | grep -qF "$id"; then
                echo present
            else
                echo missing
            fi
            return
        fi
        attempt=$((attempt + 1))
        sleep "${RETRY_DELAY:-3}"
    done
    echo unknown
}

# ── Fast path ─────────────────────────────────────────────────────────────────
if [ "$FORCE_REREGISTER" != "true" ] && [ -f "$CREDS_FILE" ] && [ -f "$SCOPES_FILE" ]; then
    REGISTERED="$(cat "$SCOPES_FILE")"
    if [ "$REGISTERED" = "$REQUIRED_SCOPES" ]; then
        case "$(client_status)" in
            present)
                echo "Service client '$CLIENT_NAME' already registered with correct scopes. Skipping."
                exit 0
                ;;
            unknown)
                echo "Warning: could not ask authservice whether the stored client exists; keeping the stored credentials." >&2
                echo "Skipping."
                exit 0
                ;;
            *)
                echo "Stored service client is not known to authservice (database reset or client deleted) — re-registering."
                ;;
        esac
    else
        echo "Scope mismatch: registered='$REGISTERED', required='$REQUIRED_SCOPES'"
    fi
elif [ "$FORCE_REREGISTER" = "true" ]; then
    echo "FORCE_REREGISTER=true — re-registering regardless of current state."
fi

# ── Clean up old client ───────────────────────────────────────────────────────
if [ -f "$CREDS_FILE" ]; then
    CLIENT_ID="$(stored_client_id)"
    if [ -n "$CLIENT_ID" ]; then
        echo "Deleting old service client '$CLIENT_ID'..."
        "$SWCTL" auth delete-service-client "$CLIENT_ID" \
            || echo "Warning: could not delete client '$CLIENT_ID' (may already be gone)"
    fi
    rm -f "$CREDS_FILE" "$SCOPES_FILE"
fi

# ── Register with correct scopes ──────────────────────────────────────────────
echo "Registering '$CLIENT_NAME' with scopes: $REQUIRED_SCOPES"
# shellcheck disable=SC2086  — intentional word-splitting for variadic scopes
"$SWCTL" auth ensure-service-client \
    --output "$CREDS_FILE" \
    --retries 15 \
    "$CLIENT_NAME" \
    $REQUIRED_SCOPES

echo "$REQUIRED_SCOPES" > "$SCOPES_FILE"
echo "Registration complete."
# The gateway reads these credentials once, when its container starts.
echo "NOTE: restart swayrider-api so it picks up the new credentials (docker compose -f layer-30/compose.yml up -d --force-recreate swayrider-api)."
