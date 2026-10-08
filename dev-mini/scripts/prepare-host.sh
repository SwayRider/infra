#!/bin/bash
#
# prepare-host.sh - check (and with --apply, create) what dev-mini needs on the host before data is deployed.
#
#   ./prepare-host.sh            report only
#   ./prepare-host.sh --apply    create missing directories; chown commands that need root are printed, not run
#
# Checks: vm.max_map_count >= 262144 (Elasticsearch), the roots of the data classes (VALHALLA_ROOT, PELIAS_ROOT,
# GEODATA_ROOT, TILES_ROOT), the tilesservice cache (TILES_CACHE_PATH), the Elasticsearch and Garage directories, and free space per filesystem.
# Values come from the environment or layer-00/10/20 .env (never printed except as paths).

set -uo pipefail
INFRA="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY=false
[[ "${1:-}" == "--apply" ]] && APPLY=true
RC=0

val() {  # val VAR: environment first, then the first layer .env that defines it
    local name="$1" v f
    v="${!name:-}"
    if [[ -z "$v" ]]; then
        for f in "$INFRA"/layer-00/.env "$INFRA"/layer-10/.env "$INFRA"/layer-20/.env; do
            [[ -f "$f" ]] && v="$(grep -m1 "^${name}=" "$f" | cut -d= -f2- | tr -d "'\"")" && [[ -n "$v" ]] && break
        done
    fi
    echo "$v"
}

ok()   { echo "  ok    $1"; }
warn() { echo "  WARN  $1"; RC=1; }

echo "Kernel"
mm="$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)"
if (( mm >= 262144 )); then ok "vm.max_map_count=$mm"; else warn "vm.max_map_count=$mm (< 262144): sudo sysctl -w vm.max_map_count=262144 and persist it in /etc/sysctl.d/"; fi

echo "Directories"
ensure() {  # ensure VAR SUBDIR OWNER_UID
    local var="$1" sub="${2:-}" uid="${3:-}" root dir
    root="$(val "$var")"
    if [[ -z "$root" || "$root" == /path/to/* ]]; then warn "$var is not set"; return; fi
    dir="$root${sub:+/$sub}"
    if [[ -d "$dir" ]]; then
        ok "$var: $dir"
    elif $APPLY && mkdir -p "$dir"; then
        ok "$var: created $dir"
    else
        warn "$var: $dir does not exist (run with --apply)"
        return
    fi
    if [[ -n "$uid" && "$(stat -c %u "$dir")" != "$uid" ]]; then
        warn "$var: $dir is not owned by uid $uid: sudo chown -R $uid:$uid '$dir'"
    fi
}
ensure VALHALLA_ROOT releases
for r in benelux france germany; do ensure VALHALLA_ROOT "work/$r" 59999; done  # scratch /custom_files of the valhalla containers
ensure PELIAS_ROOT releases
ensure GEODATA_ROOT releases
ensure TILES_ROOT base
ensure TILES_CACHE_PATH  # disk cache of tilesservice: an empty, writable directory
ensure ES_DATA_PATH "" 1000
ensure ES_SNAPSHOTS_PATH "" 1000
ensure GARAGE_DATA_PATH
ensure GARAGE_META_PATH

echo "Free space"
for var in VALHALLA_ROOT PELIAS_ROOT GEODATA_ROOT TILES_CACHE_PATH ES_DATA_PATH ES_SNAPSHOTS_PATH GARAGE_DATA_PATH; do
    p="$(val "$var")"
    [[ -d "$p" ]] && printf '  %-18s %s free (%s)\n' "$var" "$(df -h --output=avail "$p" | tail -1 | tr -d ' ')" "$p"
done
echo "A deploy refuses to start when the free space is below the release size x 1.1."
exit $RC
