#!/bin/bash
#
# clean-es-indices.sh - Remove pelias indices not referenced by any alias
#
# Usage:
#   ./clean-es-indices.sh [options]
#
# Options:
#   --es-host HOST   Elasticsearch host (default: localhost)
#   --es-port PORT   Elasticsearch port (default: 39200)
#   --dry-run        Show what would be deleted without deleting
#   --force          Skip confirmation prompt
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

show_help() {
    awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1 && /^[^#]/{exit}' "$0"
}

FORCE=false
ES_HOST="${ES_HOST:-localhost}"
ES_PORT="${ES_PORT:-39200}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --es-host)  ES_HOST="$2"; shift 2 ;;
        --es-port)  ES_PORT="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --force)    FORCE=true; shift ;;
        -h|--help)  show_help; exit 0 ;;
        *)          echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

ES_URL="http://${ES_HOST}:${ES_PORT}"

log_section "Clean Unused Pelias Indices"

# Fetch all pelias indices
ALL_INDICES=$(curl -s "${ES_URL}/_cat/indices?h=index" | grep '^pelias_' | sort)

if [[ -z "$ALL_INDICES" ]]; then
    log_step "No pelias indices found"
    exit 0
fi

# Fetch pelias indices that have at least one alias
ALIASED_INDICES=$(curl -s "${ES_URL}/_cat/aliases?h=index" | grep '^pelias_' | sort -u)

# Compute unaliased indices
UNALIASED=$(python3 -c "
all_indices = set('''$ALL_INDICES'''.strip().split('\n'))
aliased = set('''$ALIASED_INDICES'''.strip().split('\n')) if '''$ALIASED_INDICES'''.strip() else set()
unaliased = sorted(all_indices - aliased)
for idx in unaliased:
    print(idx)
" 2>/dev/null || echo "")

if [[ -z "$UNALIASED" ]]; then
    log_step "No unused pelias indices found"
    echo ""
    echo "All pelias indices are referenced by aliases."
    exit 0
fi

COUNT=$(echo "$UNALIASED" | wc -l | tr -d ' ')

echo ""
echo "  Unused pelias indices ($COUNT):"
echo "$UNALIASED" | sed 's/^/    /'
echo ""

if $DRY_RUN; then
    log_step "DRY RUN: Would delete $COUNT indices"
    exit 0
fi

if ! $FORCE; then
    echo -n "  Delete $COUNT indices? (y/N) "
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "  Aborted"
        exit 0
    fi
fi

echo ""
DELETED=0
FAILED=0

while IFS= read -r index; do
    log_step "Deleting: $index"
    if es_request "$ES_HOST" "$ES_PORT" DELETE "/${index}" > /dev/null; then
        ((DELETED++))
    else
        log_warn "Failed to delete $index"
        ((FAILED++))
    fi
done <<< "$UNALIASED"

echo ""
log_step "Deleted $DELETED of $COUNT indices"
[[ $FAILED -gt 0 ]] && log_warn "$FAILED failures"
