#!/bin/bash
#
# fix-border-tar.sh - Fix manifest paths and repack border.tar.bz2
#
# Strips the leading /YYYY-MM-DD/ tag prefix from remote-file values
# in all manifest files, then repacks border.tar.bz2 with the corrected
# manifest.
#
# Usage:
#   ./fix-border-tar.sh --result-dir /path/to/pipeline/result
#

set -euo pipefail

RESULT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --result-dir)
            RESULT_DIR="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/s/^# \?//p;3,$s/^# \?//p;/^$/{q}' "$0"
            exit 0 ;;
        *)
            echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$RESULT_DIR" ]]; then
    echo "Error: --result-dir is required" >&2
    exit 1
fi

echo "========================================="
echo "  Fixing Manifest Paths"
echo "========================================="
echo ""
echo "Result dir: $RESULT_DIR"
echo ""

# Fix all manifest files in the result dir
for manifest in "$RESULT_DIR"/manifest-*.yml; do
    if [[ ! -f "$manifest" ]]; then
        continue
    fi
    echo "Fixing $(basename "$manifest")..."
    # Strip leading /YYYY-MM-DD/ from remote-file values
    # Handles both /2026-03-16/contours/... and tiles/2026-03-06/tiles/... patterns
    sed -E -i '' 's|(remote-file: )/?[0-9]{4}-[0-9]{2}-[0-9]{2}/(.+)|\1\2|' "$manifest"
    # Also handle tiles prefix with tag: tiles/2026-03-06/tiles/... → tiles/...
    sed -E -i '' 's|(remote-file: )tiles/[0-9]{4}-[0-9]{2}-[0-9]{2}/(.+)|\1tiles/\2|' "$manifest"
done

echo ""

# Repack border.tar.bz2 with corrected manifest
BORDER_TAR="$RESULT_DIR/border.tar.bz2"
if [[ ! -f "$BORDER_TAR" ]]; then
    echo "Warning: border.tar.bz2 not found at $BORDER_TAR, skipping repack"
    exit 0
fi

echo "Repacking border.tar.bz2 with corrected manifest..."

WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

# Extract existing tar
echo "  Extracting..."
tar -xjf "$BORDER_TAR" -C "$WORK_DIR"

# Replace manifest with corrected one
cp "$RESULT_DIR/manifest-border.yml" "$WORK_DIR/manifest.yml"
echo "  Replaced manifest.yml"

# Repack
echo "  Repacking..."
tar -cjf "$BORDER_TAR" -C "$WORK_DIR" .

echo ""
echo "Done. border.tar.bz2 now contains corrected manifest paths."
echo ""
echo "Next steps:"
echo "  1. Re-transfer border.tar.bz2 and manifest-border.yml to the server"
echo "  2. Run deploy-border.sh on the server"
echo "  3. Restart regionservice"
