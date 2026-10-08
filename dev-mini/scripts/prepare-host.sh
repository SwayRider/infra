#!/bin/bash
#
# prepare-host.sh - check what dev-mini needs on the host before data is deployed, and help to create it.
#
#   ./prepare-host.sh            report and show the commands that would fix it; changes nothing
#   ./prepare-host.sh --dry-run  same (explicit)
#   ./prepare-host.sh --apply    report, show the commands, then ask:
#                                  A = run them now (commands that need root run through sudo, which asks for your password)
#                                  M = manual: they are printed again and you run them yourself, then press Enter
#                                  Q = quit
#                                after A or M the checks run again, so you see whether it worked
#
# Checks: vm.max_map_count >= 262144 (Elasticsearch), the roots of the data classes (VALHALLA_ROOT, PELIAS_ROOT,
# GEODATA_ROOT, TILES_ROOT), the tilesservice cache (TILES_CACHE_PATH), the Elasticsearch and Garage directories, and
# free space per filesystem. Values come from the environment or layer-00/10/20 .env (never printed except as paths).

set -uo pipefail
INFRA="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY=false
case "${1:-}" in
    "" | --dry-run) ;;
    --apply) APPLY=true ;;
    *) echo "usage: $0 [--dry-run | --apply]" >&2; exit 2 ;;
esac

RC=0
SYSTEM=() MKDIRS=() TREES=() LEAVES=()  # the fix, in the order it must run: kernel, create, hand new trees to you, give data dirs to their service user
PLAN=()

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

nearest_parent() {  # the closest existing ancestor of a path
    local p="$1"
    while [[ ! -e "$p" && "$p" != "/" ]]; do p="$(dirname "$p")"; done
    echo "$p"
}

ensure() {  # ensure VAR SUBDIR OWNER_UID
    local var="$1" sub="${2:-}" uid="${3:-}" root dir parent rel top
    root="$(val "$var")"
    if [[ -z "$root" || "$root" == /path/to/* ]]; then warn "$var is not set"; return; fi
    if [[ "$root$sub" =~ [^A-Za-z0-9_./@:+=\ -] ]]; then warn "$var: the path contains characters this script will not put in a command: $root"; return; fi
    dir="$root${sub:+/$sub}"
    if [[ -d "$dir" ]]; then
        ok "$var: $dir"
    else
        warn "$var: $dir does not exist"
        parent="$(nearest_parent "$dir")"
        rel="${dir#"$parent"/}"; top="$parent/${rel%%/*}"  # the first directory that does not exist yet: the new tree starts here
        if [[ -w "$parent" ]]; then
            MKDIRS+=("mkdir -p '$dir'")
        else  # the parent belongs to someone else (often root): create with sudo, then hand the new tree to you
            MKDIRS+=("sudo mkdir -p '$dir'")
            TREES+=("sudo chown -R $(id -u):$(id -g) '$top'")
        fi
        [[ -n "$uid" && "$uid" != "$(id -u)" ]] && LEAVES+=("sudo chown -R $uid:$uid '$dir'")
        return
    fi
    if [[ -n "$uid" && "$(stat -c %u "$dir")" != "$uid" ]]; then
        warn "$var: $dir is not owned by uid $uid"
        LEAVES+=("sudo chown -R $uid:$uid '$dir'")
    fi
}

check_all() {
    RC=0 SYSTEM=() MKDIRS=() TREES=() LEAVES=() PLAN=()
    echo "Kernel"
    local mm
    mm="$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)"
    if (( mm >= 262144 )); then
        ok "vm.max_map_count=$mm"
    else
        warn "vm.max_map_count=$mm (< 262144; persist the value in /etc/sysctl.d/ too)"
        SYSTEM+=("sudo sysctl -w vm.max_map_count=262144")
    fi

    echo "Directories"
    ensure VALHALLA_ROOT releases
    local r
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
    local var p
    for var in VALHALLA_ROOT PELIAS_ROOT GEODATA_ROOT TILES_CACHE_PATH ES_DATA_PATH ES_SNAPSHOTS_PATH GARAGE_DATA_PATH; do
        p="$(val "$var")"
        [[ -d "$p" ]] && printf '  %-18s %s free (%s)\n' "$var" "$(df -h --output=avail "$p" | tail -1 | tr -d ' ')" "$p"
    done
    echo "A deploy refuses to start when the free space is below the release size x 1.1."

    local seen=$'\n' list cmd
    for list in SYSTEM MKDIRS TREES LEAVES; do  # in this order, without duplicates
        declare -n arr="$list"
        for cmd in "${arr[@]}"; do
            if [[ "$seen" != *$'\n'"$cmd"$'\n'* ]]; then PLAN+=("$cmd"); seen+="$cmd"$'\n'; fi
        done
        unset -n arr
    done
}

show_plan() {
    echo
    echo "$1"
    printf '  %s\n' "${PLAN[@]}"
}

check_all
if (( ${#PLAN[@]} == 0 )); then
    echo
    [[ $RC -eq 0 ]] && echo "Everything is in place." || echo "Nothing this script can fix: see the WARN lines."
    exit $RC
fi

if ! $APPLY; then
    show_plan "Commands that would fix this (nothing was changed):"
    echo
    echo "Run '$0 --apply' to be asked whether to run them or to do them yourself."
    exit $RC
fi

if [[ ! -t 0 ]]; then
    show_plan "Commands that would fix this:"
    echo "Not an interactive terminal: nothing was done." >&2
    exit 1
fi

while (( ${#PLAN[@]} )); do
    show_plan "These commands would fix it:"
    echo
    read -r -p "[A]pply them now (sudo will ask for your password), do it [M]anually, or [Q]uit? " choice
    case "${choice,,}" in
        a)
            for cmd in "${PLAN[@]}"; do
                echo "+ $cmd"
                if ! bash -c "$cmd"; then echo "  failed: $cmd" >&2; break; fi
            done
            ;;
        m)
            show_plan "Run these yourself, in this order:"
            echo
            read -r -p "Press Enter when you have run them (q to quit): " done_
            [[ "${done_,,}" == q ]] && exit 1
            ;;
        q) exit 1 ;;
        *) echo "Answer A, M or Q."; continue ;;
    esac
    echo
    echo "Checking again..."
    check_all
    if (( ${#PLAN[@]} == 0 )); then
        echo
        [[ $RC -eq 0 ]] && echo "Done: everything is in place." || echo "The commands worked; the remaining WARN lines are not something this script can fix."
        exit $RC
    fi
    echo
    echo "Something is still missing (see the WARN lines above)."
done
