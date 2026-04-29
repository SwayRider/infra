#!/bin/bash
#
# deploy-pelias.sh - Deploy Pelias data and ES snapshots
#
# Handles both pelias-es-snapshot.tar.bz2 and pelias-data.tar.bz2.
# ES must be running for the snapshot restore step.
#
# Usage:
#   ./deploy-pelias.sh --input /path/to/pipeline-output [options]
#
# Options:
#   --input DIR              Directory containing pipeline output (required)
#   --pelias-path PATH       Override PELIAS_DATA_PATH
#   --es-snapshots-path PATH Override ES_SNAPSHOTS_PATH
#   --es-host HOST           Elasticsearch host (default: localhost)
#   --es-port PORT           Elasticsearch port (default: 39200)
#   --repo-name NAME         Snapshot repository name (default: pelias_repo)
#   --regions REGIONS        Comma-separated regions (default: auto-detect)
#   --clean-es               Remove all pelias indices, aliases, and snapshots before restore
#   --clean-es-unused        Remove pelias indices without aliases after restore
#   --skip-es                Skip all Elasticsearch operations (extract, restore, clean)
#   --skip-es-extract        Skip ES snapshot tar extraction (assumes files on disk from previous run)
#   --password PASSWORD      Sudo password for ownership changes (prompted if not provided)
#   --dry-run                Show what would be done without executing
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

show_help() {
    awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1 && /^[^#]/{exit}' "$0"
}

CLEAN_ES=false
CLEAN_ES_UNUSED=false
SKIP_ES=false
SKIP_ES_EXTRACT=false

source_env_files

# Parse pelias-specific flags before passing to parse_common_args
_PARSED_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean-es)        CLEAN_ES=true; shift ;;
        --clean-es-unused) CLEAN_ES_UNUSED=true; shift ;;
        --skip-es)         SKIP_ES=true; shift ;;
        --skip-es-extract) SKIP_ES_EXTRACT=true; shift ;;
        *)                 _PARSED_ARGS+=("$1"); shift ;;
    esac
done
set -- "${_PARSED_ARGS[@]}"

parse_common_args "$@"

if [[ -z "$INPUT_DIR" ]]; then
    log_error "--input is required"
    echo "Run with --help for usage"
    exit 1
fi

ES_SNAPSHOT_ARCHIVE=$(find_tar "$INPUT_DIR" "pelias-es-snapshot.tar.bz2" 2>/dev/null || true)
DATA_ARCHIVE=$(find_tar "$INPUT_DIR" "pelias-data.tar.bz2" 2>/dev/null || true)

if [[ -z "$ES_SNAPSHOT_ARCHIVE" && -z "$DATA_ARCHIVE" ]]; then
    log_error "Neither pelias-es-snapshot.tar.bz2 nor pelias-data.tar.bz2 found in $INPUT_DIR"
    exit 1
fi

ES_URL="http://${ES_HOST}:${ES_PORT}"

# Prompt for sudo password if needed and not provided
if [[ (-n "$ES_SNAPSHOT_ARCHIVE" || $CLEAN_ES) && -z "$SUDO_PASS" && ! $SKIP_ES ]]; then
    echo -n "Sudo password (needed for snapshot ownership): "
    read -s SUDO_PASS
    echo ""
fi

# Temp directory for pelias data (extracted under target disk, cleaned up on exit)
_DATA_TMP_DIR=""
_cleanup() {
    [[ -n "$_DATA_TMP_DIR" && -d "$_DATA_TMP_DIR" ]] && sudo_cmd rm -rf "$_DATA_TMP_DIR"
    SUDO_PASS=""
}
trap _cleanup EXIT

# =====================
# Clean ES: remove all pelias indices, aliases, and snapshots
# =====================
_clean_es_all() {
    log_section "Cleaning All Pelias ES Data"

    if $DRY_RUN; then
        log_step "DRY RUN: Would remove all pelias aliases, indices, and snapshots"
        return 0
    fi

    # Remove all pelias aliases
    echo "  Removing pelias aliases..."
    local aliases
    aliases=$(curl -s "${ES_URL}/_cat/aliases?h=alias" | grep '^pelias_' || true)
    if [[ -n "$aliases" ]]; then
        while IFS= read -r alias; do
            log_step "  Removing alias: $alias"
            es_request "$ES_HOST" "$ES_PORT" DELETE "/*/_alias/${alias}" > /dev/null || true
        done <<< "$aliases"
    fi

    # Delete all pelias indices
    echo "  Deleting pelias indices..."
    local indices
    indices=$(curl -s "${ES_URL}/_cat/indices?h=index" | grep '^pelias_' || true)
    if [[ -n "$indices" ]]; then
        while IFS= read -r index; do
            log_step "  Deleting index: $index"
            es_request "$ES_HOST" "$ES_PORT" DELETE "/${index}" > /dev/null || true
        done <<< "$indices"
    fi

    # Unregister repository (clears ES's cached snapshot state)
    echo "  Unregistering snapshot repository..."
    es_request "$ES_HOST" "$ES_PORT" DELETE "/_snapshot/${REPO_NAME}" > /dev/null || true

    # Clear snapshot files from disk
    log_step "Clearing snapshot files from disk..."
    sudo_cmd rm -rf "${ES_SNAPSHOTS_PATH:?}/"*

    log_step "Clean complete"
}

# =====================
# Clean unused: remove pelias indices without aliases
# =====================
_clean_es_unused() {
    log_section "Cleaning Unused Pelias Indices"

    local all_indices aliased_indices unaliased
    all_indices=$(curl -s "${ES_URL}/_cat/indices?h=index" | grep '^pelias_' || true)

    if [[ -z "$all_indices" ]]; then
        log_step "No pelias indices found"
        return 0
    fi

    aliased_indices=$(curl -s "${ES_URL}/_cat/aliases?h=index" | grep '^pelias_' | sort -u || true)

    unaliased=$(python3 -c "
all_idx = set('''$all_indices'''.strip().split('\n'))
aliased = set('''$aliased_indices'''.strip().split('\n')) if '''$aliased_indices'''.strip() else set()
for idx in sorted(all_idx - aliased):
    print(idx)
" 2>/dev/null || echo "")

    if [[ -z "$unaliased" ]]; then
        log_step "No unused pelias indices found"
        return 0
    fi

    local count
    count=$(echo "$unaliased" | wc -l | tr -d ' ')
    log_step "Found $count unused indices"

    if $DRY_RUN; then
        echo "$unaliased" | sed 's/^/    /'
        log_step "DRY RUN: Would delete $count indices"
        return 0
    fi

    while IFS= read -r index; do
        log_step "  Deleting: $index"
        es_request "$ES_HOST" "$ES_PORT" DELETE "/${index}" > /dev/null || true
    done <<< "$unaliased"

    log_step "Cleaned $count unused indices"
}

# =====================
# ES Snapshot Restore
# =====================
restore_es_snapshot() {
    local archive="$1"

    log_section "Elasticsearch Snapshot Restore"
    log_step "Archive:      $archive"
    log_step "ES:           $ES_URL"
    log_step "Snapshot dir: $ES_SNAPSHOTS_PATH"

    if $DRY_RUN; then
        log_step "DRY RUN: Would restore ES snapshots"
        return 0
    fi

    wait_for_es "$ES_HOST" "$ES_PORT"

    if $SKIP_ES_EXTRACT; then
        log_step "Skipping ES snapshot extraction (--skip-es-extract)"
    else
        echo "  Extracting ES snapshot archive..."
        mkdir -p "$ES_SNAPSHOTS_PATH"

        # Fix ownership so running user can write to the snapshots directory
        log_step "Fixing ownership for extraction..."
        sudo_cmd chown -R "$(id -u):$(id -g)" "$ES_SNAPSHOTS_PATH"

        log_step "Clearing old snapshot files..."
        rm -rf "${ES_SNAPSHOTS_PATH:?}/"*

        tar -xjf "$archive" -C "$ES_SNAPSHOTS_PATH"

        log_step "Fixing ownership for Elasticsearch..."
        sudo_cmd chown -R 1000:1000 "$ES_SNAPSHOTS_PATH"
    fi

    # Unregister repository (clears ES's cached state)
    log_step "Unregistering snapshot repository..."
    es_request "$ES_HOST" "$ES_PORT" DELETE "/_snapshot/${REPO_NAME}" > /dev/null || true

    # Re-register repository (ES reads fresh from disk)
    log_step "Registering snapshot repository '${REPO_NAME}'..."
    REPO_PAYLOAD="{\"type\":\"fs\",\"settings\":{\"location\":\"/usr/share/elasticsearch/snapshots\",\"compress\":true}}"
    if ! es_request "$ES_HOST" "$ES_PORT" PUT "/_snapshot/${REPO_NAME}" "$REPO_PAYLOAD" > /dev/null; then
        log_error "Failed to register snapshot repository"
        return 1
    fi
    log_step "Repository registered"

    echo "  Available snapshots:"
    SNAPSHOTS=$(es_request "$ES_HOST" "$ES_PORT" GET "/_snapshot/${REPO_NAME}/_all" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for s in data.get('snapshots', []):
    print(s['snapshot'])
" 2>/dev/null || echo "")

    if [[ -z "$SNAPSHOTS" ]]; then
        log_error "No snapshots found in repository"
        return 1
    fi
    echo "$SNAPSHOTS" | sed 's/^/    /'

    # Detect regions
    local regions
    if [[ -n "$REGIONS_OVERRIDE" ]]; then
        regions="$REGIONS_OVERRIDE"
    else
        regions=$(echo "$SNAPSHOTS" | sed 's/^pelias_//;s/-[^-]*$//' | sort -u | tr '\n' ',' | sed 's/,$//')
    fi
    log_step "Regions: $regions"

    IFS=',' read -ra REGION_LIST <<< "$regions"
    for region in "${REGION_LIST[@]}"; do
        echo ""
        log_step "Restoring region: $region"

        local snapshot_name=""
        while IFS= read -r snap; do
            if [[ "$snap" == pelias_${region}-* ]]; then
                snapshot_name="$snap"
                break
            fi
        done <<< "$SNAPSHOTS"

        if [[ -z "$snapshot_name" ]]; then
            log_warn "No snapshot found for region '$region', skipping"
            continue
        fi

        log_step "  Restoring snapshot: $snapshot_name"
        RESTORE_PAYLOAD="{\"indices\":\"*\",\"ignore_unavailable\":true,\"include_global_state\":false}"
        if ! es_request "$ES_HOST" "$ES_PORT" POST "/_snapshot/${REPO_NAME}/${snapshot_name}/_restore?wait_for_completion=true" "$RESTORE_PAYLOAD" > /dev/null; then
            log_warn "Restore may have had issues, continuing..."
        fi

        local alias_name="pelias_${region}"
        log_step "  Updating alias: $alias_name -> $snapshot_name"
        ALIAS_PAYLOAD="{\"actions\":[{\"remove\":{\"index\":\"*\",\"alias\":\"${alias_name}\"}},{\"add\":{\"index\":\"${snapshot_name}\",\"alias\":\"${alias_name}\"}}]}"
        if ! es_request "$ES_HOST" "$ES_PORT" POST "/_aliases" "$ALIAS_PAYLOAD" > /dev/null; then
            ALIAS_PAYLOAD="{\"actions\":[{\"add\":{\"index\":\"${snapshot_name}\",\"alias\":\"${alias_name}\"}}]}"
            es_request "$ES_HOST" "$ES_PORT" POST "/_aliases" "$ALIAS_PAYLOAD" > /dev/null || true
        fi
        log_step "  Alias updated"
    done

    log_step "ES snapshot restore complete"
}

# =====================
# Data Deployment
# =====================
deploy_data() {
    local archive="$1"

    log_section "Pelias Data Deployment (configs + WOF + placeholder)"
    log_step "Archive:       $archive"
    log_step "Pelias path:   $PELIAS_DATA_PATH"

    if $DRY_RUN; then
        log_step "DRY RUN: Would deploy pelias data"
        return 0
    fi

    echo "  Extracting data archive..."
    sudo_cmd mkdir -p "$PELIAS_DATA_PATH"
    _DATA_TMP_DIR=$(sudo_cmd mktemp -d -p "$PELIAS_DATA_PATH" .tmp-pelias-XXXXXX)
    sudo_cmd chown "$(id -u):$(id -g)" "$_DATA_TMP_DIR"

    tar -xjf "$archive" -C "$_DATA_TMP_DIR"
    log_step "Extracted to $_DATA_TMP_DIR"

    # Detect regions from directory structure (exclude 'placeholder' dir)
    local regions
    if [[ -n "$REGIONS_OVERRIDE" ]]; then
        regions="$REGIONS_OVERRIDE"
    else
        regions=$(find "$_DATA_TMP_DIR" -mindepth 1 -maxdepth 1 -type d \
            -not -name placeholder -exec basename {} \; | sort | tr '\n' ',' | sed 's/,$//')
    fi

    if [[ -z "$regions" ]]; then
        log_error "No regions found in data archive and none specified"
        return 1
    fi
    log_step "Regions: $regions"

    IFS=',' read -ra REGION_LIST <<< "$regions"
    for region in "${REGION_LIST[@]}"; do
        echo ""
        log_step "Region: $region"

        # Deploy config to API config path
        API_CONFIG_DIR="${PELIAS_DATA_PATH}/${region}/api/config"
        PROD_CONFIG_SRC="$_DATA_TMP_DIR/${region}/pelias.json"
        if [[ -f "$PROD_CONFIG_SRC" ]]; then
            sudo_cmd mkdir -p "$API_CONFIG_DIR"
            sudo_cmd cp "$PROD_CONFIG_SRC" "$API_CONFIG_DIR/pelias.json"
            log_step "  Deployed API config -> $API_CONFIG_DIR/pelias.json"
        else
            log_warn "Config not found: $PROD_CONFIG_SRC"
        fi

        # Deploy config to PIP config path
        PIP_CONFIG_DIR="${PELIAS_DATA_PATH}/${region}/pip/config"
        if [[ -f "$PROD_CONFIG_SRC" ]]; then
            sudo_cmd mkdir -p "$PIP_CONFIG_DIR"
            sudo_cmd cp "$PROD_CONFIG_SRC" "$PIP_CONFIG_DIR/pelias.json"
            log_step "  Deployed PIP config -> $PIP_CONFIG_DIR/pelias.json"
        fi

        # Extract WOF data for this region
        PIP_WOF_DIR="${PELIAS_DATA_PATH}/${region}/pip/whosonfirst"
        WOF_ARCHIVE="$_DATA_TMP_DIR/${region}/wof.tar.gz"
        if [[ -f "$WOF_ARCHIVE" ]]; then
            sudo_cmd mkdir -p "$PIP_WOF_DIR"
            log_step "  Extracting WOF data -> $PIP_WOF_DIR"
            sudo_cmd tar -xzf "$WOF_ARCHIVE" -C "$PIP_WOF_DIR"
        else
            log_warn "WOF archive not found: $WOF_ARCHIVE"
        fi
    done

    # Deploy placeholder data
    echo ""
    log_step "Deploying placeholder data"
    PLACEHOLDER_DEST="${PELIAS_DATA_PATH}/placeholder/data"
    PLACEHOLDER_SRC="$_DATA_TMP_DIR/store.sqlite3.gz"

    if [[ -f "$PLACEHOLDER_SRC" ]]; then
        sudo_cmd mkdir -p "$PLACEHOLDER_DEST"
        gunzip -c "$PLACEHOLDER_SRC" > "$_DATA_TMP_DIR/store.sqlite3"
        sudo_cmd cp "$_DATA_TMP_DIR/store.sqlite3" "$PLACEHOLDER_DEST/store.sqlite3"
        log_step "  Deployed -> $PLACEHOLDER_DEST/store.sqlite3"
    else
        log_warn "Placeholder data not found in archive"
    fi

    log_step "Data deployment complete"
}

# =====================
# Main
# =====================

if ! $SKIP_ES; then
    if $CLEAN_ES; then
        _clean_es_all
    fi

    if [[ -n "$ES_SNAPSHOT_ARCHIVE" ]]; then
        restore_es_snapshot "$ES_SNAPSHOT_ARCHIVE"
    fi

    if $CLEAN_ES_UNUSED; then
        _clean_es_unused
    fi
fi

if [[ -n "$DATA_ARCHIVE" ]]; then
    deploy_data "$DATA_ARCHIVE"
fi

echo ""
print_restart_instructions "pelias-placeholder,pelias-iberian-peninsula-pip,pelias-west-europe-pip,pelias-iberian-peninsula-api,pelias-west-europe-api" "layer-10"
