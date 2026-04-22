#!/bin/bash
#
# lib.sh - Shared helpers for dev server data deployment scripts
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DEV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Logging ---

log_section() {
    echo ""
    echo "========================================="
    echo "  $1"
    echo "========================================="
}

log_step() {
    echo "  $1"
}

log_warn() {
    echo "  WARNING: $1" >&2
}

log_error() {
    echo "  ERROR: $1" >&2
}

# --- Environment ---

source_env_files() {
    for layer in layer-00 layer-10 layer-20; do
        local env_file="$INFRA_DEV_DIR/$layer/.env"
        if [[ -f "$env_file" ]]; then
            set -a
            # shellcheck source=/dev/null
            source "$env_file"
            set +a
        fi
    done

    ES_DATA_PATH="${ES_DATA_PATH:-/mnt/ssd1/swayrider/dev/elasticsearch/data}"
    ES_SNAPSHOTS_PATH="${ES_SNAPSHOTS_PATH:-/mnt/hdd-pool/swayrider/dev/elasticsearch/snapshots}"
    VALHALLA_DATA_PATH="${VALHALLA_DATA_PATH:-/mnt/ssd2/swayrider/dev/valhalla}"
    GEODATA_PATH="${GEODATA_PATH:-/mnt/ssd2/swayrider/dev/geodata}"
    PELIAS_DATA_PATH="${PELIAS_DATA_PATH:-/mnt/ssd2/swayrider/dev/pelias}"
    TILES_DATA_PATH="${TILES_DATA_PATH:-/mnt/ssd2/swayrider/dev/tilesdata}"
}

# --- File finding ---

find_tar() {
    local input_dir="$1"
    local pattern="$2"
    local found
    found=$(find "$input_dir" -maxdepth 1 -name "$pattern" -type f 2>/dev/null | head -1)
    if [[ -z "$found" ]]; then
        log_error "No file matching '$pattern' in $input_dir"
        return 1
    fi
    echo "$found"
}

find_manifest() {
    local input_dir="$1"
    local pattern="$2"
    local found
    found=$(find "$input_dir" -maxdepth 1 -name "$pattern" -type f 2>/dev/null | head -1)
    if [[ -z "$found" ]]; then
        echo ""
        return 0
    fi
    echo "$found"
}

# --- Tag detection ---

detect_tag_from_manifest() {
    local manifest_file="$1"
    if [[ -z "$manifest_file" || ! -f "$manifest_file" ]]; then
        echo ""
        return 0
    fi
    grep -E '^tag:' "$manifest_file" | head -1 | sed 's/^tag:[[:space:]]*//' | tr -d '\r\n'
}

# --- Extraction ---

extract_tar() {
    local archive="$1"
    local dest="$2"
    echo "  Extracting $(basename "$archive") -> $dest"
    mkdir -p "$dest"
    if [[ "$archive" == *.bz2 ]]; then
        tar -xjf "$archive" -C "$dest"
    else
        tar -xf "$archive" -C "$dest"
    fi
}

# --- Elasticsearch helpers ---

es_request() {
    local es_host="$1"
    local es_port="$2"
    local method="$3"
    local path="$4"
    local data="${5:-}"
    local url="http://${es_host}:${es_port}${path}"

    local args=(-s -w "\n%{http_code}" -X "$method" -H "Content-Type: application/json")
    if [[ -n "$data" ]]; then
        args+=(-d "$data")
    fi

    local response
    response=$(curl "${args[@]}" "$url" 2>/dev/null)
    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        echo "$body"
        return 0
    else
        log_error "ES request failed: $method $path (HTTP $http_code)"
        echo "$body" >&2
        return 1
    fi
}

wait_for_es() {
    local es_host="$1"
    local es_port="$2"
    local timeout="${3:-60}"

    echo "  Waiting for Elasticsearch at http://${es_host}:${es_port}..."
    local start=$SECONDS
    while (( SECONDS - start < timeout )); do
        if response=$(es_request "$es_host" "$es_port" GET "/_cluster/health" 2>/dev/null); then
            local status
            status=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
            if [[ "$status" == "green" || "$status" == "yellow" ]]; then
                echo "  Elasticsearch ready (status: $status)"
                return 0
            fi
        fi
        sleep 3
    done
    log_error "Elasticsearch not ready after ${timeout}s"
    return 1
}

# --- Argument parsing helpers ---

parse_common_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --input)
                INPUT_DIR="$2"; shift 2 ;;
            --geodata-path)
                GEODATA_PATH="$2"; shift 2 ;;
            --valhalla-path)
                VALHALLA_DATA_PATH="$2"; shift 2 ;;
            --pelias-path)
                PELIAS_DATA_PATH="$2"; shift 2 ;;
            --es-snapshots-path)
                ES_SNAPSHOTS_PATH="$2"; shift 2 ;;
            --tiles-path)
                TILES_DATA_PATH="$2"; shift 2 ;;
            --regions)
                REGIONS_OVERRIDE="$2"; shift 2 ;;
            --dry-run)
                DRY_RUN=true; shift ;;
            --es-host)
                ES_HOST="$2"; shift 2 ;;
            --es-port)
                ES_PORT="$2"; shift 2 ;;
            --repo-name)
                REPO_NAME="$2"; shift 2 ;;
            -h|--help)
                show_help; exit 0 ;;
            -*)
                log_error "Unknown option: $1"
                exit 1 ;;
            *)
                log_error "Unexpected argument: $1"
                exit 1 ;;
        esac
    done
}

# Defaults
INPUT_DIR=""
REGIONS_OVERRIDE=""
DRY_RUN=false
ES_HOST="${ES_HOST:-localhost}"
ES_PORT="${ES_PORT:-39200}"
REPO_NAME="pelias_repo"

# --- Restart instructions ---

print_restart_instructions() {
    local services="$1"
    local layer="$2"

    if [[ -z "$services" ]]; then
        return
    fi

    echo ""
    echo "  Restart required:"
    echo "    cd infra/dev/$layer && docker compose restart"
}
