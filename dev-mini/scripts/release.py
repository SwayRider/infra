#!/usr/bin/env python3
"""release.py - manual fallback for the data-manager deploy (valhalla, pelias, geodata classes).

Same layout and semantics as data-manager's `compose-single-machine` driver (Docs/MIGRATION-DATA-MANAGER.md
section 3, data-manager/RELEASE-CONTRACT.md): copy a verified package into <ROOT>/releases/<tag>, switch
<ROOT>/current atomically, restart the services, roll back by switching back. Tiles are not handled here: they go to
the object store (Garage), see README.md. Standard library only.

  release.py list
  release.py copy      <class> <tag> --from <package-dir> [--dry-run]
  release.py activate  <class> <tag> [--no-services]
  release.py rollback  <class> [--no-services]
  release.py prune     <class> [--keep 2] [--dry-run]
  release.py es-restore <tag> [--region R]        (pelias: restore the snapshots of a copied release)

<class> is valhalla | pelias | geodata. Roots come from the environment or the layer .env files:
VALHALLA_ROOT, PELIAS_ROOT, GEODATA_ROOT (layer-10/20), ES_SNAPSHOTS_PATH (layer-00); ES_URL (default
http://localhost:39200); SW_PREFIX (container prefix, default sw-dev).
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
INFRA = HERE.parent
CLASSES = ("geodata", "valhalla", "pelias")
ROOT_VARS = {"valhalla": "VALHALLA_ROOT", "pelias": "PELIAS_ROOT", "geodata": "GEODATA_ROOT"}
ES_CONTAINER_SNAPSHOTS = "/usr/share/elasticsearch/snapshots"


class Fail(Exception):
    pass


def env(name: str, default: str | None = None) -> str | None:
    """Environment first, then the first layer .env that defines it (values are never printed)."""
    if os.environ.get(name):
        return os.environ[name]
    for layer in ("layer-00", "layer-10", "layer-20"):
        f = INFRA / layer / ".env"
        if f.exists():
            m = re.search(rf"^{name}=(.*)$", f.read_text(), re.M)
            if m:
                return m.group(1).strip().strip("'\"")
    return default


def root(cls: str) -> Path:
    value = env(ROOT_VARS[cls])
    if not value or value.startswith("/path/to"):
        raise Fail(f"{ROOT_VARS[cls]} is not set (environment or layer .env)")
    return Path(value)


def log(msg: str) -> None:
    print(f"  {msg}", flush=True)


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(8 * 1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def read_package(folder: Path) -> dict:
    f = folder / "package.json"
    if not f.exists():
        raise Fail(f"{folder} is not a package (no package.json)")
    return json.loads(f.read_text())


def class_parts(doc: dict, cls: str) -> list[dict]:
    parts = doc.get("classes", {}).get(cls, {}).get("parts", [])
    if not parts:
        raise Fail(f"the package has no {cls} class")
    return parts


# --- package path -> target layout ------------------------------------------------------------------------------

def target_of(cls: str, part: dict, tag: str) -> tuple[str, str]:
    """(kind, relative target). kind: file | wof (tar.gz unpacked into <region>/wof/sqlite) | snapshot (tar unpacked
    into ES_SNAPSHOTS_PATH/<tag>/<region>)."""
    path = part["path"]
    if cls == "geodata":
        return "file", path.removeprefix("geodata/")
    if cls == "valhalla":
        return "file", path.removeprefix("valhalla/")
    rel = path.removeprefix("pelias/")
    if rel.endswith("/wof.tar.gz"):
        return "wof", rel.removesuffix("/wof.tar.gz")
    if rel.endswith(".es-snapshot.tar"):
        return "snapshot", rel.split("/")[0]
    return "file", rel


# --- copy -----------------------------------------------------------------------------------------------------

def copy_file(src: Path, dst: Path, expected: str) -> None:
    if dst.exists() and dst.stat().st_size == src.stat().st_size and sha256_of(dst) == expected:
        return  # resumed copy: this one is already there
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(dst.name + ".tmp")
    h = hashlib.sha256()
    with open(src, "rb") as fin, open(tmp, "wb") as fout:
        for block in iter(lambda: fin.read(8 * 1024 * 1024), b""):
            h.update(block)
            fout.write(block)
    if h.hexdigest() != expected:
        tmp.unlink()
        raise Fail(f"{src}: source changed or is corrupt (sha256 does not match package.json)")
    os.replace(tmp, dst)


def unpack(src: Path, dest: Path, expected: str, *, flat_into: str | None = None) -> None:
    if sha256_of(src) != expected:
        raise Fail(f"{src}: sha256 does not match package.json")
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    target = dest / flat_into if flat_into else dest
    target.mkdir(parents=True, exist_ok=True)
    with tarfile.open(src) as tf:
        tf.extractall(target, filter="data")


def cmd_copy(args) -> None:
    cls, tag, pkg = args.cls, args.tag, Path(args.source)
    doc = read_package(pkg)
    parts = class_parts(doc, cls)
    base = root(cls)
    final, partial = base / "releases" / tag, base / "releases" / f"{tag}.partial"
    if final.exists():
        raise Fail(f"{final} exists already; nothing to copy")
    size = sum(p["size"] for p in parts)
    free = shutil.disk_usage(base if base.exists() else base.parent).free
    log(f"{cls}: {len(parts)} parts, {size / 1e9:.1f} GB, free {free / 1e9:.1f} GB")
    if free < size * 1.1:
        raise Fail("not enough free space (need release size x 1.1)")
    if args.dry_run:
        for p in parts:
            log(f"{p['path']} -> {target_of(cls, p, tag)[1]}")
        return
    snapshots = Path(env("ES_SNAPSHOTS_PATH", "") or "") / tag if cls == "pelias" else None
    for p in parts:
        src, (kind, rel) = pkg / p["path"], target_of(cls, p, tag)
        if not src.exists():
            raise Fail(f"{src} is missing")
        if kind == "file":
            copy_file(src, partial / rel, p["sha256"])
        elif kind == "wof":
            unpack(src, partial / rel / "wof", p["sha256"], flat_into="sqlite")
        else:
            if snapshots is None or not str(snapshots.parent):
                raise Fail("ES_SNAPSHOTS_PATH is not set")
            unpack(src, snapshots / rel, p["sha256"])
        log(f"ok {p['path']}")
    partial.rename(final)
    log(f"copied to {final}")


# --- activate / rollback / list / prune ------------------------------------------------------------------------

def releases(base: Path) -> list[str]:
    d = base / "releases"
    return sorted(x.name for x in d.iterdir() if x.is_dir() and not x.name.endswith(".partial")) if d.exists() else []


def pointer(base: Path, name: str) -> str | None:
    link = base / name
    return os.path.basename(os.readlink(link)) if link.is_symlink() else None


def switch(base: Path, name: str, tag: str) -> None:
    tmp = base / f"{name}.tmp"
    if tmp.is_symlink() or tmp.exists():
        tmp.unlink()
    os.symlink(f"releases/{tag}", tmp)  # relative, so the root can move
    os.replace(tmp, base / name)


def container(suffix: str) -> str:
    return f"{env('SW_PREFIX', 'sw-dev')}-{suffix}"


def docker_restart(*names: str) -> None:
    for name in names:
        r = subprocess.run(["docker", "restart", name], capture_output=True, text=True)
        if r.returncode:
            raise Fail(f"docker restart {name}: {r.stderr.strip()}")
        log(f"restarted {name}")


def regions_of(base: Path, tag: str) -> list[str]:
    rel = base / "releases" / tag
    return sorted(x.name for x in rel.iterdir() if x.is_dir() and x.name not in {"placeholder", "contours", "border-crossings"})


def restart_services(cls: str, base: Path, tag: str) -> None:
    if cls == "geodata":
        docker_restart(container("regionservice"))
    elif cls == "valhalla":
        for r in regions_of(base, tag):
            docker_restart(container(f"valhalla-{r}"))
    else:
        if (base / "releases" / tag / "placeholder").exists():
            docker_restart(container("pelias-placeholder"))
        for r in regions_of(base, tag):
            docker_restart(container(f"pelias-{r}-pip"), container(f"pelias-{r}-interpolation"), container(f"pelias-{r}-api"))


def cmd_activate(args) -> None:
    cls, tag = args.cls, args.tag
    base = root(cls)
    if not (base / "releases" / tag).is_dir():
        raise Fail(f"release {tag} is not copied to {base} yet")
    if cls == "pelias" and not args.no_services:
        es_restore(tag, None)
    current = pointer(base, "current")
    if current and current != tag:
        switch(base, "previous", current)
    switch(base, "current", tag)
    log(f"{cls}: current -> {tag}" + (f" (previous {current})" if current and current != tag else ""))
    if not args.no_services:
        restart_services(cls, base, tag)


def cmd_rollback(args) -> None:
    cls, base = args.cls, root(args.cls)
    previous, current = pointer(base, "previous"), pointer(base, "current")
    if not previous:
        raise Fail(f"{cls}: no previous release to roll back to")
    if cls == "pelias" and not args.no_services:
        es_restore(previous, None)  # a no-op while the index is still in Elasticsearch
    switch(base, "current", previous)
    switch(base, "previous", current) if current else None
    log(f"{cls}: current -> {previous}")
    if not args.no_services:
        restart_services(cls, base, previous)


def cmd_list(args) -> None:
    for cls in CLASSES:
        try:
            base = root(cls)
        except Fail as e:
            print(f"{cls}: {e}")
            continue
        cur, prev = pointer(base, "current"), pointer(base, "previous")
        print(f"{cls} ({base}): current={cur} previous={prev}")
        for t in releases(base):
            print(f"    {t}{'  <- current' if t == cur else '  <- previous' if t == prev else ''}")


def cmd_prune(args) -> None:
    base = root(args.cls)
    keep_tags = {pointer(base, "current"), pointer(base, "previous")} - {None}
    tags = sorted((t for t in releases(base) if t not in keep_tags), key=lambda t: (base / "releases" / t).stat().st_mtime)
    room = max(0, args.keep - len(keep_tags))  # the newest of the others that still fit next to current/previous
    doomed = tags[: len(tags) - room] if room < len(tags) else []
    for t in doomed:
        log(f"{'would remove' if args.dry_run else 'removing'} {base / 'releases' / t}")
        if args.dry_run:
            continue
        if args.cls == "pelias":
            es_drop(t, base)
        shutil.rmtree(base / "releases" / t)
    for stale in (base / "releases").glob("*.partial"):
        log(f"{'would remove' if args.dry_run else 'removing'} leftover {stale}")
        if not args.dry_run:
            shutil.rmtree(stale)


# --- Elasticsearch (pelias) ---------------------------------------------------------------------------------------

def es(method: str, path: str, body: dict | None = None, timeout: int = 3600):
    url = env("ES_URL", "http://localhost:39200").rstrip("/") + path
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise Fail(f"Elasticsearch {method} {path}: {e.code} {e.read()[:300].decode(errors='replace')}")
    except OSError as e:
        raise Fail(f"Elasticsearch not reachable at {url}: {e}")


def release_indexes(base: Path, tag: str, only: str | None = None) -> dict[str, str]:
    """region -> index name, from the pelias.json of the release (api.indexName pins the concrete index)."""
    out = {}
    for r in regions_of(base, tag):
        if only and r != only:
            continue
        cfg = json.loads((base / "releases" / tag / r / "pelias.json").read_text())
        out[r] = cfg["schema"]["indexName"]
    return out


def es_restore(tag: str, region: str | None) -> None:
    base = root("pelias")
    for r, index in release_indexes(base, tag, region).items():
        if es("HEAD", f"/{index}") is not None:
            log(f"{r}: index {index} is already in Elasticsearch")
            continue
        repo = f"dm_{tag}_{r}"
        location = f"{ES_CONTAINER_SNAPSHOTS}/{tag}/{r}"
        log(f"{r}: registering repository {repo} ({location}) and restoring {index}")
        es("PUT", f"/_snapshot/{repo}", {"type": "fs", "settings": {"location": location, "readonly": True}})
        res = es("POST", f"/_snapshot/{repo}/{index}/_restore?wait_for_completion=true",
                 {"indices": index, "include_global_state": False})
        if not res or res.get("snapshot", {}).get("shards", {}).get("failed", 1):
            raise Fail(f"{r}: restore of {index} failed: {res}")
        es("GET", f"/_cluster/health/{index}?wait_for_status=yellow&timeout=120s")
        log(f"{r}: restored {index}")


def es_drop(tag: str, base: Path) -> None:
    try:
        for r, index in release_indexes(base, tag).items():
            es("DELETE", f"/{index}")
            es("DELETE", f"/_snapshot/dm_{tag}_{r}")
            log(f"{r}: dropped index {index} and repository dm_{tag}_{r}")
    except (Fail, FileNotFoundError, KeyError) as e:
        log(f"Elasticsearch cleanup of {tag} skipped: {e}")
    snaps = env("ES_SNAPSHOTS_PATH")
    if snaps and (Path(snaps) / tag).exists():
        shutil.rmtree(Path(snaps) / tag)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list").set_defaults(fn=cmd_list)
    for name, fn in (("copy", cmd_copy), ("activate", cmd_activate), ("rollback", cmd_rollback), ("prune", cmd_prune)):
        p = sub.add_parser(name)
        p.add_argument("cls", metavar="class", choices=CLASSES)
        if name in ("copy", "activate"):
            p.add_argument("tag")
        if name == "copy":
            p.add_argument("--from", dest="source", required=True, help="package directory (contains package.json)")
            p.add_argument("--dry-run", action="store_true")
        if name in ("activate", "rollback"):
            p.add_argument("--no-services", action="store_true", help="only switch the symlink")
        if name == "prune":
            p.add_argument("--keep", type=int, default=2)
            p.add_argument("--dry-run", action="store_true")
        p.set_defaults(fn=fn)
    p = sub.add_parser("es-restore")
    p.add_argument("tag")
    p.add_argument("--region")
    p.set_defaults(fn=lambda a: es_restore(a.tag, a.region))
    args = ap.parse_args()
    try:
        args.fn(args)
    except Fail as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
