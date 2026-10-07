# dev-mini

Lightweight single-host variant of `infra/dev` (3 regions: **benelux**, **france**, **germany**). It is also the **test-bed for the single-server docker-compose deployment** that `data-manager` output is deployed to.

Same layer structure as `dev`:

| Layer | Content |
|-------|---------|
| `layer-00` | Traefik, Elasticsearch, PostgreSQL, Redis, WireGuard, Garage (S3 object store for the PMTiles planet) |
| `layer-10` | Valhalla (per region, ports 33001–33003), Pelias (placeholder, libpostal, pip + api per region) |
| `layer-20` | authservice, mailservice, regionservice, routerservice, searchservice, tilesservice, swayrider-api-register |
| `layer-30` | swayrider-api gateway |

Start in order (`layer-00` → `layer-30`) with `docker compose -f layer-NN/compose.y*ml up -d`; copy each layer's `env.example` to `.env` first.

## Object store (Garage)

The PMTiles planet release is stored in **Garage**, a single-node S3-compatible object store in `layer-00` (decision: [`Docs/MIGRATION-DATA-MANAGER.md`](../../Docs/MIGRATION-DATA-MANAGER.md) §3.1a). `data-manager` uploads releases with a read/write key, `tilesservice` reads them with a read-only key (ranged GETs). Other artifact classes are unaffected.

Set up, from `layer-00/`:

```bash
cp env.example .env     # set GARAGE_DATA_PATH/GARAGE_META_PATH, the secrets and the two key pairs (section 6)
mkdir -p "$GARAGE_DATA_PATH" "$GARAGE_META_PATH"   # data on the big SSD (~140 GB per release, keep 2), meta on a small fast disk
docker compose -f compose.yaml up -d               # starts everything incl. garage; the one-shot garage-init service does the rest
docker logs sw-dev-garage-init                     # "Garage ready: bucket swayrider-tiles, keys …"
./garage/smoke-test.sh  # put/get, multipart, ranged GET, pointer overwrite, read-only key (needs the AWS CLI)
```

`garage-init` (`garage/init.sh`, alpine + curl + jq, Garage admin API v2) runs on every `docker compose up` and is idempotent: it applies the single-node layout, creates the bucket `swayrider-tiles` and imports the read/write and read-only keys from `.env`; existing ones are left alone. It exits non-zero with Garage's answer when something is wrong (check the logs above). It needs network access on first start to `apk add curl jq`.

- S3 endpoint: `http://127.0.0.1:39000` by default (path-style, region `garage`, bucket `swayrider-tiles`). When `data-manager` runs on another machine set `GARAGE_S3_BIND` to the WireGuard/LAN address (or `0.0.0.0`) and re-run `docker compose up -d garage`; test from that machine with `GARAGE_ENDPOINT=http://<host>:39000 ./garage/smoke-test.sh`. The admin API (3903) and RPC (3901) are not published.
- Keys come from `.env` (never committed): generate with `echo "GK$(openssl rand -hex 12)"; openssl rand -hex 32`. `garage-init` only imports them; rotating means deleting the key in Garage (`docker exec sw-dev-garage /garage key delete <name> --yes`) and running `docker compose up -d garage-init` again.
- Release layout in the bucket and the `current.json` pointer: `data-manager/SERVICES.md` (tiles contract).
- Backup: the data directory is the only copy of the planet in this setup; it can be re-created from `data-manager`'s package.

## Data deployment

Data is produced by [`data-manager`](../../data-manager) (possibly on another machine) and **copied** here as immutable releases. Each artifact class has its own root (env var in the layer `.env`, see `env.example`), so classes can live on separate drives, plus a `current` symlink that is switched atomically:

```
$VALHALLA_ROOT/  current -> releases/<tag>/<region>/{valhalla_tiles.tar, admin.sqlite, tz_world.sqlite}
$PELIAS_ROOT/    current -> releases/<tag>/{placeholder/data/store.sqlite3, <region>/{wof/sqlite/, interpolation/{street,address}.db, pelias.json}}
$GEODATA_ROOT/   current -> releases/<tag>/{manifest.yml, contours/, border-crossings/}
$TILES_ROOT/     base/  (legacy MBTiles, transition only)       planet PMTiles: Garage, releases/<tag>/ + current.json
$ES_SNAPSHOTS_PATH/<tag>/<region>/   snapshot repository of a release (restored into Elasticsearch)
```

Compose mounts the files of `<ROOT>/current/...` read-only (`create_host_path: false`): **a service whose class has not been deployed yet does not start** (instead of Docker creating empty root-owned directories). `current` is resolved when a container starts, so activating a release means switching the symlink and `docker restart`ing the services of that class. Valhalla gets a scratch volume for `/custom_files` (the image writes `file_hashes.txt` there) with the release files mounted into it. Pelias API and PIP read the release's `pelias.json`, whose `api.indexName` pins the concrete Elasticsearch index of that release, so there is no alias to switch: restore the index, switch `current`, restart. Each region also has a `pelias-<region>-interpolation` service (ports 33112/33122/33132) that the API reaches over `net-sw-dev-pelias`.

**Tiles** live in Garage (see above). `data-manager` uploads `releases/<tag>/`, writes `current.json` last, writes `layer-20/tiles-release.env` (`PMTILES_URL=s3://swayrider-tiles/releases/<tag>/tiles.pmtiles`, git-ignored) and recreates `tilesservice` (`docker compose up -d --force-recreate tilesservice`); that last step goes away when tilesservice reloads on `current.json`.

### Preparing the host

```bash
./scripts/prepare-host.sh           # report: vm.max_map_count, roots, ES/Garage directories, free space
./scripts/prepare-host.sh --apply   # create the missing directories (chown commands that need root are printed)
```

### Manual fallback: `scripts/release.py`

`data-manager` deploys by itself (the `compose-single-machine` driver); `scripts/release.py` does the same by hand with the same layout and semantics (valhalla, pelias, geodata; standard-library Python):

```bash
./scripts/release.py copy valhalla r-20261012-1 --from /mnt/hdd-pool/swayrider/data-repo/r-20261012-1   # verify sha256, unpack, rename .partial -> release
./scripts/release.py activate valhalla r-20261012-1     # switch current (previous kept), restart the region services
./scripts/release.py rollback valhalla                  # switch back to previous and restart
./scripts/release.py list
./scripts/release.py prune valhalla --keep 2
./scripts/release.py es-restore r-20261012-1            # pelias: restore the snapshots of a copied release (activate does this too)
```

Order for a full release: geodata, valhalla, pelias (tiles go through data-manager). The legacy `scripts/deploy.sh` and `dev/scripts/deploy-*.sh` (data-pipeline tarballs) are deprecated.

Procedure and rationale: [`Docs/MIGRATION-DATA-MANAGER.md`](../../Docs/MIGRATION-DATA-MANAGER.md) §3 and §6.

**Status:** roots, `pelias-*-interpolation`, the read-only mounts, `release.py` and `prepare-host.sh` are in place. Not yet exercised against real data: that is the first deploy.
