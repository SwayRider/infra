#!/bin/bash
#
# deploy.sh - List available tags or deploy a specific one from a geodata store
#
# The geodata store is the directory produced by the data-pipeline's publish step:
# each sub-directory is a tag (e.g. 2026-04-29) containing the five archive files.
#
# Usage:
#   ./deploy.sh list   --geodata-store PATH
#   ./deploy.sh deploy --geodata-store PATH --tag TAG [options]
#
# deploy options:
#   --geodata-store PATH     Directory where published tags live (required)
#   --tag TAG                Tag to deploy, e.g. 2026-04-29 (required)
#   --infra PATH             Infra dir containing layer-{00,10,20}/ .env files
#                            (default: parent of this script)
#   --dry-run                Show what would be done without executing
#   --es-host HOST           Elasticsearch host (default: localhost)
#   --es-port PORT           Elasticsearch port (default: 39200)
#   --clean-es               Remove all pelias indices and snapshots before restore
#   --clean-es-unused        Remove pelias indices without aliases after restore
#   --skip-es                Skip all Elasticsearch operations
#   --skip-es-extract        Skip ES snapshot tar extraction
#   --password PASSWORD      Sudo password for privileged file operations (prompted if absent)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_SCRIPTS="$(cd "$SCRIPT_DIR/../../dev/scripts" && pwd)"

# --- Logging ---

log_section() {
    echo ""
    echo "========================================="
    echo "  $1"
    echo "========================================="
}

log_error() { echo "  ERROR: $1" >&2; }

show_help() {
    awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1 && /^[^#]/{exit}' "$0"
}

# --- list ---

cmd_list() {
    local geodata_store=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --geodata-store) geodata_store="$2"; shift 2 ;;
            -h|--help) show_help; exit 0 ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    if [[ -z "$geodata_store" ]]; then
        log_error "--geodata-store is required"
        exit 1
    fi
    if [[ ! -d "$geodata_store" ]]; then
        log_error "Geodata store not found: $geodata_store"
        exit 1
    fi

    local archives=("osm.tar.bz2" "border.tar.bz2" "valhalla.tar.bz2" "pelias-es-snapshot.tar.bz2" "pelias-data.tar.bz2" "tiles.tar")
    local labels=("osm" "border" "valhalla" "pelias-es" "pelias-data" "tiles")

    printf "%-20s" "TAG"
    for label in "${labels[@]}"; do printf "  %-11s" "$label"; done
    echo ""
    printf "%-20s" "-------------------"
    for _ in "${labels[@]}"; do printf "  %-11s" "-----------"; done
    echo ""

    local found=false
    while IFS= read -r tag_dir; do
        [[ -d "$tag_dir" ]] || continue
        found=true
        local tag
        tag=$(basename "$tag_dir")
        printf "%-20s" "$tag"
        for archive in "${archives[@]}"; do
            if [[ -f "$tag_dir/$archive" ]]; then
                printf "  ✓%-10s" ""
            else
                printf "  %-11s" "-"
            fi
        done
        echo ""
    done < <(find "$geodata_store" -maxdepth 1 -mindepth 1 -type d | sort -r)

    if ! $found; then
        echo "  No tags found in $geodata_store"
    fi
}

# --- deploy ---

cmd_deploy() {
    local geodata_store=""
    local tag=""
    local infra_dir
    infra_dir="$(cd "$SCRIPT_DIR/.." && pwd)"
    local dry_run=false
    local es_host="localhost"
    local es_port="39200"
    local clean_es=false
    local clean_es_unused=false
    local skip_es=false
    local skip_es_extract=false
    local password=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --geodata-store)    geodata_store="$2";   shift 2 ;;
            --tag)              tag="$2";             shift 2 ;;
            --infra)            infra_dir="$2";       shift 2 ;;
            --dry-run)          dry_run=true;         shift   ;;
            --es-host)          es_host="$2";         shift 2 ;;
            --es-port)          es_port="$2";         shift 2 ;;
            --clean-es)         clean_es=true;        shift   ;;
            --clean-es-unused)  clean_es_unused=true; shift   ;;
            --skip-es)          skip_es=true;         shift   ;;
            --skip-es-extract)  skip_es_extract=true; shift   ;;
            --password)         password="$2";        shift 2 ;;
            -h|--help) show_help; exit 0 ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    if [[ -z "$geodata_store" || -z "$tag" ]]; then
        log_error "--geodata-store and --tag are both required"
        echo "  Run with --help for usage" >&2
        exit 1
    fi

    local input_dir="$geodata_store/$tag"
    if [[ ! -d "$input_dir" ]]; then
        log_error "Tag directory not found: $input_dir"
        exit 1
    fi

    # Source .env files from the infra layers
    for layer in layer-00 layer-10 layer-20; do
        local env_file="$infra_dir/$layer/.env"
        if [[ -f "$env_file" ]]; then
            set -a
            # shellcheck source=/dev/null
            source "$env_file"
            set +a
        fi
    done

    # Prompt for sudo password if needed
    if [[ -z "$password" ]]; then
        echo -n "Sudo password for privileged file operations (leave blank if not needed): "
        read -rs password
        echo ""
    fi
    trap 'password=""' EXIT

    log_section "Deploying tag: $tag"
    echo "  Store:   $geodata_store"
    echo "  Input:   $input_dir"
    echo "  Infra:   $infra_dir"
    echo "  Dry-run: $dry_run"

    local common=(--input "$input_dir")
    $dry_run && common+=(--dry-run)

    local pelias_flags=(--es-host "$es_host" --es-port "$es_port")
    $clean_es         && pelias_flags+=(--clean-es)
    $clean_es_unused  && pelias_flags+=(--clean-es-unused)
    $skip_es          && pelias_flags+=(--skip-es)
    $skip_es_extract  && pelias_flags+=(--skip-es-extract)
    [[ -n "$password" ]] && pelias_flags+=(--password "$password")

    local osm_args=("${common[@]}")
    [[ -n "${GEODATA_PATH:-}" ]] && osm_args+=(--geodata-path "$GEODATA_PATH")
    [[ -n "$password" ]]         && osm_args+=(--password "$password")

    local border_args=("${common[@]}")
    [[ -n "${GEODATA_PATH:-}" ]] && border_args+=(--geodata-path "$GEODATA_PATH")
    [[ -n "$password" ]]         && border_args+=(--password "$password")

    local valhalla_args=("${common[@]}")
    [[ -n "${VALHALLA_DATA_PATH:-}" ]] && valhalla_args+=(--valhalla-path "$VALHALLA_DATA_PATH")
    [[ -n "$password" ]]               && valhalla_args+=(--password "$password")

    local pelias_args=("${common[@]}" "${pelias_flags[@]}")
    [[ -n "${PELIAS_DATA_PATH:-}" ]]  && pelias_args+=(--pelias-path "$PELIAS_DATA_PATH")
    [[ -n "${ES_SNAPSHOTS_PATH:-}" ]] && pelias_args+=(--es-snapshots-path "$ES_SNAPSHOTS_PATH")

    local tiles_args=("${common[@]}")
    [[ -n "${TILES_DATA_PATH:-}" ]] && tiles_args+=(--tiles-path "$TILES_DATA_PATH")
    [[ -n "$password" ]]            && tiles_args+=(--password "$password")

    log_section "1/5 OSM Data"
    "$DEV_SCRIPTS/deploy-osm.sh" "${osm_args[@]}"

    log_section "2/5 Border Data"
    "$DEV_SCRIPTS/deploy-border.sh" "${border_args[@]}"

    log_section "3/5 Valhalla Data"
    "$DEV_SCRIPTS/deploy-valhalla.sh" "${valhalla_args[@]}"

    log_section "4/5 Pelias Data + ES Snapshots"
    "$DEV_SCRIPTS/deploy-pelias.sh" "${pelias_args[@]}"

    log_section "5/5 Tiles Data"
    "$DEV_SCRIPTS/deploy-tiles.sh" "${tiles_args[@]}"

    log_section "Deployment Complete"
    if $dry_run; then
        echo "  Dry run — no changes were made."
    else
        echo "  Services that need restarting:"
        echo ""
        echo "    Layer 10 (valhalla + pelias):"
        echo "      cd layer-10 && docker compose restart"
        echo ""
        echo "    Layer 20 (regionservice + tilesservice):"
        echo "      cd layer-20 && docker compose restart"
    fi
    echo ""
}

# --- Main ---

if [[ $# -eq 0 ]]; then
    show_help
    exit 1
fi

CMD="$1"; shift

case "$CMD" in
    list)      cmd_list   "$@" ;;
    deploy)    cmd_deploy "$@" ;;
    -h|--help) show_help; exit 0 ;;
    *)
        log_error "Unknown command: $CMD  (expected: list, deploy)"
        echo "  Run with --help for usage" >&2
        exit 1
        ;;
esac
