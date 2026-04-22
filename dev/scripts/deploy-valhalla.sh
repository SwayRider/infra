#!/bin/bash
#
# deploy-valhalla.sh - Deploy Valhalla routing data
#
# Usage:
#   ./deploy-valhalla.sh --input /path/to/pipeline-output [options]
#
# Options:
#   --input DIR            Directory containing pipeline output (required)
#   --valhalla-path PATH   Override VALHALLA_DATA_PATH
#   --dry-run              Show what would be done without executing
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

log_section "Valhalla Data Deployment"

ARCHIVE=$(find_tar "$INPUT_DIR" "valhalla.tar.bz2")
log_step "Archive: $ARCHIVE"
log_step "Destination: $VALHALLA_DATA_PATH"

if $DRY_RUN; then
    log_step "DRY RUN: Would extract to $VALHALLA_DATA_PATH"
else
    extract_tar "$ARCHIVE" "$VALHALLA_DATA_PATH"

    # Rename tiles.tar to valhalla_tiles.tar in each region directory
    for region_dir in "$VALHALLA_DATA_PATH"/*/; do
        if [[ -f "${region_dir}tiles.tar" ]]; then
            mv "${region_dir}tiles.tar" "${region_dir}valhalla_tiles.tar"
            log_step "Renamed tiles.tar -> valhalla_tiles.tar in $(basename "$region_dir")"
        fi
    done

    log_step "Done"
fi

print_restart_instructions "valhalla-iberian-peninsula,valhalla-west-europe" "layer-10"
