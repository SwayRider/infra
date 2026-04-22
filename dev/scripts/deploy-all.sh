#!/bin/bash
#
# deploy-all.sh - Deploy all data-pipeline output to the dev server
#
# Runs all deploy scripts in dependency order.
#
# Usage:
#   ./deploy-all.sh --input /path/to/pipeline-output [options]
#
# Options:
#   --input DIR          Directory containing pipeline output (required)
#   --es-host HOST       Elasticsearch host (default: localhost)
#   --es-port PORT       Elasticsearch port (default: 39200)
#   --password PASSWORD  Sudo password for ownership changes (prompted if not provided)
#   --clean-es           Remove all pelias indices, aliases, and snapshots before restore
#   --clean-es-unused    Remove pelias indices without aliases after restore
#   --skip-es            Skip all Elasticsearch operations (extract, restore, clean)
#   --skip-es-extract    Skip ES snapshot tar extraction (assumes files on disk from previous run)
#   --dry-run            Show what would be done without executing
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Parse our own args ---
INPUT_DIR=""
DRY_RUN=""
ES_ARGS=""
_SUDO_PASS=""
PELIAS_FLAGS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input)
            INPUT_DIR="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN="--dry-run"; shift ;;
        --es-host)
            ES_ARGS="$ES_ARGS --es-host $2"; shift 2 ;;
        --es-port)
            ES_ARGS="$ES_ARGS --es-port $2"; shift 2 ;;
        --password)
            _SUDO_PASS="$2"; shift 2 ;;
        --clean-es)
            PELIAS_FLAGS="$PELIAS_FLAGS --clean-es"; shift ;;
        --clean-es-unused)
            PELIAS_FLAGS="$PELIAS_FLAGS --clean-es-unused"; shift ;;
        --skip-es)
            PELIAS_FLAGS="$PELIAS_FLAGS --skip-es"; shift ;;
        --skip-es-extract)
            PELIAS_FLAGS="$PELIAS_FLAGS --skip-es-extract"; shift ;;
        -h|--help)
            awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1 && /^[^#]/{exit}' "$0"
            exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1 ;;
    esac
done

if [[ -z "$INPUT_DIR" ]]; then
    echo "Error: --input is required" >&2
    echo "Run with --help for usage" >&2
    exit 1
fi

# Prompt for sudo password if not provided
if [[ -z "$_SUDO_PASS" ]]; then
    echo -n "Sudo password (needed for snapshot ownership): "
    read -s _SUDO_PASS
    echo ""
fi

# Clear password on exit
trap '_SUDO_PASS=""' EXIT

PASSWORD_ARG="--password $_SUDO_PASS"
COMMON_ARGS="--input $INPUT_DIR $DRY_RUN"

echo "========================================="
echo "  Deploying All Data"
echo "========================================="
echo ""
echo "Input:   $INPUT_DIR"
echo "Dry-run: ${DRY_RUN:-no}"
echo ""

# --- Run in dependency order ---

echo "========================================="
echo "  1/5 OSM Data"
echo "========================================="
"$SCRIPT_DIR/deploy-osm.sh" $COMMON_ARGS

echo ""
echo "========================================="
echo "  2/5 Border Data"
echo "========================================="
"$SCRIPT_DIR/deploy-border.sh" $COMMON_ARGS

echo ""
echo "========================================="
echo "  3/5 Valhalla Data"
echo "========================================="
"$SCRIPT_DIR/deploy-valhalla.sh" $COMMON_ARGS

echo ""
echo "========================================="
echo "  4/5 Pelias Data + ES Snapshots"
echo "========================================="
"$SCRIPT_DIR/deploy-pelias.sh" $COMMON_ARGS $ES_ARGS $PASSWORD_ARG $PELIAS_FLAGS

echo ""
echo "========================================="
echo "  5/5 Tiles Data"
echo "========================================="
"$SCRIPT_DIR/deploy-tiles.sh" $COMMON_ARGS

# --- Summary ---
echo ""
echo "========================================="
echo "  Deployment Complete"
echo "========================================="
echo ""

if [[ -n "$DRY_RUN" ]]; then
    echo "This was a dry run. No changes were made."
    echo "Run without --dry-run to apply."
else
    echo "Services that need restarting:"
    echo ""
    echo "  Layer 10 (valhalla + pelias):"
    echo "    cd infra/dev/layer-10 && docker compose restart"
    echo ""
    echo "  Layer 20 (regionservice + tilesservice):"
    echo "    cd infra/dev/layer-20 && docker compose restart"
fi
echo ""
