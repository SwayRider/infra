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
# Shared access: the data directories belong to root and the group $DATA_GROUP (default swdata), setgid and with a default
# ACL, so everybody in that group can deploy and nobody locks the others out: files that one user creates stay writable
# for the group. The script creates the group, adds you to it and makes it active (it continues inside `sg`); other
# administrators are added with `sudo usermod -aG swdata <name>`. Directories owned by a service (Elasticsearch data, the
# Valhalla scratch) keep that service's uid.
#
# Checks: the group and the acl tools, vm.max_map_count >= 262144 (Elasticsearch), the roots of the data classes
# (VALHALLA_ROOT, PELIAS_ROOT, GEODATA_ROOT, TILES_ROOT), the tilesservice cache (TILES_CACHE_PATH), the Elasticsearch and
# Garage directories, and free space per filesystem. Values come from the environment or layer-00/10/20 .env (never
# printed except as paths).

set -uo pipefail
INFRA="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GROUP="${DATA_GROUP:-swdata}"
ME="$(id -un)"
APPLY=false
case "${1:-}" in
    "" | --dry-run) ;;
    --apply) APPLY=true ;;
    *) echo "usage: $0 [--dry-run | --apply]" >&2; exit 2 ;;
esac

group_exists()    { getent group "$GROUP" >/dev/null; }
group_has_me()    { getent group "$GROUP" | cut -d: -f4 | tr ',' '\n' | grep -qx "$ME"; }
group_in_shell()  { id -nG | tr ' ' '\n' | grep -qx "$GROUP"; }

reexec_in_group() {  # continue inside the group, so the checks see what a deploy would see
    echo "Group $GROUP is not active in this shell; continuing inside it (sg)."
    exec env PREPARE_HOST_SG=1 sg "$GROUP" -c "$(printf '%q ' "$0" "$@")"
}
if group_exists && group_has_me && ! group_in_shell && [[ -z "${PREPARE_HOST_SG:-}" ]]; then
    reexec_in_group "$@"
fi

RC=0
SYSTEM=() MKDIRS=() TREES=() LEAVES=()  # the fix, in the order it must run: system, create, share the new trees, give service dirs to their uid
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

share() {  # the commands that make a tree shared: root:GROUP, group read/write, setgid directories, default ACL
    local t="$1"
    TREES+=("sudo chown -R root:$GROUP '$t'"
            "sudo chmod -R g+rwX '$t'"
            "sudo find '$t' -type d -exec chmod g+s {} +"
            "sudo setfacl -R -m g:$GROUP:rwX -m d:g:$GROUP:rwX '$t'")
}

ensure() {  # ensure VAR SUBDIR OWNER_UID   (no uid = shared through the group)
    local var="$1" sub="${2:-}" uid="${3:-}" root dir parent rel top
    root="$(val "$var")"
    if [[ -z "$root" || "$root" == /path/to/* ]]; then warn "$var is not set"; return; fi
    if [[ "$root$sub" =~ [^A-Za-z0-9_./@:+=\ -] ]]; then warn "$var: the path contains characters this script will not put in a command: $root"; return; fi
    dir="$root${sub:+/$sub}"
    if [[ ! -d "$dir" ]]; then
        warn "$var: $dir does not exist"
        parent="$(nearest_parent "$dir")"
        rel="${dir#"$parent"/}"; top="$parent/${rel%%/*}"  # the first directory that does not exist yet: the new tree starts here
        if [[ -w "$parent" ]]; then MKDIRS+=("mkdir -p '$dir'"); else MKDIRS+=("sudo mkdir -p '$dir'"); fi
        share "$top"
        [[ -n "$uid" ]] && LEAVES+=("sudo chown -R $uid:$uid '$dir'")
        return
    fi
    if [[ -n "$uid" ]]; then
        if [[ "$(stat -c %u "$dir")" != "$uid" ]]; then
            warn "$var: $dir is not owned by uid $uid"
            LEAVES+=("sudo chown -R $uid:$uid '$dir'")
        else
            ok "$var: $dir"
        fi
    elif [[ "$(stat -c %G "$dir")" != "$GROUP" || ! -g "$dir" || ! -w "$dir" ]]; then
        warn "$var: $dir is not shared through the group $GROUP (group, setgid and write access for you)"
        share "$dir"
    else
        ok "$var: $dir"
    fi
}

check_all() {
    RC=0 SYSTEM=() MKDIRS=() TREES=() LEAVES=() PLAN=()
    echo "Access"
    if ! group_exists; then
        warn "the group $GROUP does not exist"
        SYSTEM+=("sudo groupadd $GROUP")
    else
        ok "group $GROUP exists (gid $(getent group "$GROUP" | cut -d: -f3))"
    fi
    if ! group_exists || ! group_has_me; then
        warn "$ME is not a member of $GROUP"
        SYSTEM+=("sudo usermod -aG $GROUP $ME")
    elif ! group_in_shell; then
        warn "$ME is a member of $GROUP, but this shell does not have the group yet: log in again or run 'newgrp $GROUP'"
    else
        ok "$ME is a member of $GROUP"
    fi
    if command -v setfacl >/dev/null; then
        ok "setfacl is installed"
    else
        warn "setfacl (package acl) is not installed"
        SYSTEM+=("sudo apt-get install -y acl")
    fi

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
    ensure ES_SNAPSHOTS_PATH  # shared: data-manager unpacks the pelias snapshots here; Elasticsearch only reads them
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

shell_note() {  # this process runs inside sg, the shell you started it from may not have the group yet
    if [[ -n "${PREPARE_HOST_SG:-}" ]]; then
        echo
        echo "Your own shell does not have the group $GROUP yet: log in again, or run 'newgrp $GROUP' before you start"
        echo "debug.sh or the worker from it (otherwise they cannot write to the shared directories)."
    fi
}

check_all
if (( ${#PLAN[@]} == 0 )); then
    echo
    [[ $RC -eq 0 ]] && echo "Everything is in place." || echo "Nothing this script can fix: see the WARN lines."
    shell_note
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
    if group_exists && group_has_me && ! group_in_shell && [[ -z "${PREPARE_HOST_SG:-}" ]]; then
        echo "The group $GROUP now exists with you in it."
        reexec_in_group  # the report that follows runs inside the group
    fi
    echo "Checking again..."
    check_all
    if (( ${#PLAN[@]} == 0 )); then
        echo
        [[ $RC -eq 0 ]] && echo "Done: everything is in place." || echo "The commands worked; the remaining WARN lines are not something this script can fix."
        shell_note
        exit $RC
    fi
    echo
    echo "Something is still missing (see the WARN lines above)."
done
