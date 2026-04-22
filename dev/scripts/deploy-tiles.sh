#!/bin/bash
#
# deploy-tiles.sh - Deploy vector tiles to tiles data directory
#
# Usage:
#   ./deploy-tiles.sh --input /path/to/pipeline-output [options]
#
# Options:
#   --input DIR          Directory containing pipeline output (required)
#   --tiles-path PATH    Override TILES_DATA_PATH
#   --dry-run            Show what would be done without executing
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

show_help() {
    awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1 && /^[^#]/{exit}' "$0"
}

source_env_files
parse_common_args "$@"

if [[ -z "$INPUT_DIR" ]]; then
    log_error "--input is required"
    echo "Run with --help for usage"
    exit 1
fi

log_section "Tiles Data Deployment"

ARCHIVE=$(find_tar "$INPUT_DIR" "tiles.tar")
log_step "Archive: $ARCHIVE"
log_step "Destination: $TILES_DATA_PATH"

DEST="$TILES_DATA_PATH"

if $DRY_RUN; then
    log_step "DRY RUN: Would extract to $DEST"
else
    extract_tar "$ARCHIVE" "$DEST"

    # Verify expected files
    if [[ -f "$DEST/L0.mbtiles" ]]; then
        log_step "Found L0.mbtiles"
    else
        log_warn "L0.mbtiles not found in $DEST"
    fi

    l1_count=$(find "$DEST/L1" -name "*.mbtiles" 2>/dev/null | wc -l)
    l2_count=$(find "$DEST/L2" -name "*.mbtiles" 2>/dev/null | wc -l)
    log_step "Found $l1_count L1 tiles, $l2_count L2 tiles"
    log_step "Done"
fi

print_restart_instructions "tilesservice" "layer-20"
