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

Set up (once), from `layer-00/`:

```bash
cp env.example .env     # set GARAGE_DATA_PATH/GARAGE_META_PATH, the secrets and the two key pairs (section 6)
mkdir -p "$GARAGE_DATA_PATH" "$GARAGE_META_PATH"   # data on the big SSD (~140 GB per release, keep 2), meta on a small fast disk
docker compose -f compose.yaml up -d garage
./garage/init.sh        # single-node layout, bucket swayrider-tiles, imports the rw and ro keys (idempotent)
./garage/smoke-test.sh  # put/get, multipart, ranged GET, pointer overwrite, read-only key (needs the AWS CLI)
```

- S3 endpoint: `http://127.0.0.1:39000` by default (path-style, region `garage`, bucket `swayrider-tiles`). When `data-manager` runs on another machine set `GARAGE_S3_BIND` to the WireGuard/LAN address (or `0.0.0.0`) and re-run `docker compose up -d garage`; test from that machine with `GARAGE_ENDPOINT=http://<host>:39000 ./garage/smoke-test.sh`. The admin API (3903) and RPC (3901) are not published.
- Keys come from `.env` (never committed): generate with `echo "GK$(openssl rand -hex 12)"; openssl rand -hex 32`. `init.sh` only imports them; rotating means deleting the key in Garage (`docker exec sw-dev-garage /garage key delete <name> --yes`) and re-running it.
- Release layout in the bucket and the `current.json` pointer: `data-manager/SERVICES.md` (tiles contract).
- Backup: the data directory is the only copy of the planet in this setup; it can be re-created from `data-manager`'s package.

## Data deployment

Data is produced by [`data-manager`](../../data-manager) (possibly on another machine) and **copied** here as immutable releases. Each artifact class has its own root, so classes can live on separate drives, plus a `current` symlink switched atomically:

```
$TILES_ROOT/     current -> releases/<id>/{tiles.pmtiles, manifest.json, styles/, glyphs/, sprites/}
$VALHALLA_ROOT/  current -> releases/<id>/<region>/{valhalla_tiles.tar, admin.sqlite, tz_world.sqlite}
$PELIAS_ROOT/    current -> releases/<id>/<region>/{wof/, interpolation/, pelias.json}
$GEODATA_ROOT/   current -> releases/<id>/{manifest.yml, contours/, border-crossings/}
$ES_SNAPSHOTS_PATH, $ES_DATA_PATH   (existing variables)
```

The full procedure (copy, verify, activate, rollback), activation order and the target compose changes (including the new `pelias-interpolation` service) are in [`Docs/MIGRATION-DATA-MANAGER.md`](../../Docs/MIGRATION-DATA-MANAGER.md) §3 and §6.

**Status:** the roots, the `pelias-interpolation` service and the copy/activate scripts are **not implemented yet** (migration Phase B). Until then, `scripts/deploy.sh` (legacy data-pipeline tarballs, deprecated) is still the working path.
