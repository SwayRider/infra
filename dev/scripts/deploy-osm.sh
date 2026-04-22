#!/bin/bash
#
# deploy-osm.sh - Deploy OSM data to geodata directory
#
# Usage:
#   ./deploy-osm.sh --input /path/to/pipeline-output [options]
#
# Options:
#   --input DIR          Directory containing pipeline output (required)
#   --geodata-path PATH  Override GEODATA_PATH
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

log_section "OSM Data Deployment"

ARCHIVE=$(find_tar "$INPUT_DIR" "osm.tar.bz2")
log_step "Archive: $ARCHIVE"

DEST="$GEODATA_PATH/osm"

if $DRY_RUN; then
    log_step "DRY RUN: Would extract to $DEST"
else
    extract_tar "$ARCHIVE" "$DEST"
    log_step "Done"
fi

echo ""
echo "No service restart needed."
