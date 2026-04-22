# Dev Server Data Deployment

Deploy data-pipeline output (tar files + manifests) to the dev server's docker volume layout.

## Prerequisites

1. Pipeline output (tar files + manifest `.yml` files) SCP'd to the server into a single directory
2. `.env` files created from `env.example` in each layer directory:

```bash
cp infra/dev/layer-00/env.example infra/dev/layer-00/.env
cp infra/dev/layer-10/env.example infra/dev/layer-10/.env
cp infra/dev/layer-20/env.example infra/dev/layer-20/.env
```

Edit the `.env` files to match your server's paths if needed.

## Expected Input Files

The input directory should contain:

| File | Produced by |
|------|-------------|
| `osm.tar.bz2` | `build-osm` |
| `border.tar.bz2` | `build-border-data` |
| `valhalla.tar.bz2` | `build-valhalla-data` |
| `pelias-data.tar.bz2` | `build-pelias-data` |
| `pelias-es-snapshot.tar.bz2` | `build-pelias-data` |
| `tiles.tar` | `build-tiles` |
| `manifest-*.yml` | each pipeline |

## Usage

### Deploy everything

```bash
# Dry run first (recommended)
./deploy-all.sh --input /path/to/pipeline-output --dry-run

# Apply
./deploy-all.sh --input /path/to/pipeline-output
```

### Deploy individual components

```bash
./deploy-osm.sh --input /path/to/pipeline-output
./deploy-border.sh --input /path/to/pipeline-output
./deploy-valhalla.sh --input /path/to/pipeline-output
./deploy-pelias.sh --input /path/to/pipeline-output --es-host localhost --es-port 39200
./deploy-tiles.sh --input /path/to/pipeline-output
```

### Common options

All scripts support:

- `--input DIR` - Directory containing pipeline output (required)
- `--dry-run` - Show what would be done without executing

### Per-script path overrides

| Script | Override options |
|--------|-----------------|
| `deploy-osm.sh` | `--geodata-path PATH` |
| `deploy-border.sh` | `--geodata-path PATH` |
| `deploy-valhalla.sh` | `--valhalla-path PATH`, `--regions REGIONS` |
| `deploy-pelias.sh` | `--pelias-path PATH`, `--es-snapshots-path PATH`, `--es-host HOST`, `--es-port PORT`, `--regions REGIONS` |
| `deploy-tiles.sh` | `--tiles-path PATH` |

## What Goes Where

Scripts read path variables from the layer `.env` files.

| Data | Env Var | Destination |
|------|---------|-------------|
| OSM | `GEODATA_PATH` | `{GEODATA_PATH}/osm/` |
| Border | `GEODATA_PATH` | `{GEODATA_PATH}/` (borders + border-crossings) |
| Valhalla | `VALHALLA_DATA_PATH` | `{VALHALLA_DATA_PATH}/{region}/` |
| ES Snapshot | `ES_SNAPSHOTS_PATH` | `{ES_SNAPSHOTS_PATH}/` + ES API restore |
| Pelias Data | `PELIAS_DATA_PATH` | `{PELIAS_DATA_PATH}/{region}/api/config/`, `pip/config/`, `pip/whosonfirst/`, `placeholder/data/` |
| Tiles | `TILES_DATA_PATH` | `{TILES_DATA_PATH}/` |

## Service Restarts

After deploying data, restart affected services:

```bash
# Layer 10 (valhalla + pelias)
cd infra/dev/layer-10 && docker compose restart

# Layer 20 (regionservice + tilesservice)
cd infra/dev/layer-20 && docker compose restart
```

| Data | Services to Restart |
|------|-------------------|
| OSM | None |
| Border | `regionservice` |
| Valhalla | `valhalla-iberian-peninsula`, `valhalla-west-europe` |
| Pelias (ES + data) | `pelias-placeholder`, `pelias-*-pip`, `pelias-*-api` |
| Tiles | `tilesservice` |

## Pelias ES Snapshot Notes

- Elasticsearch must be running (`layer-00` must be up) before deploying pelias
- The script waits for ES to be ready, registers the snapshot repository, restores indices, and updates aliases
- Run `deploy-all.sh` which handles ordering, or run `deploy-pelias.sh` after starting layer-00

## Scripts

| Script | Description |
|--------|-------------|
| `lib.sh` | Shared helpers (env parsing, logging, ES API) |
| `deploy-osm.sh` | Deploy `osm.tar.bz2` |
| `deploy-border.sh` | Deploy `border.tar.bz2` |
| `deploy-valhalla.sh` | Deploy `valhalla.tar.bz2` |
| `deploy-pelias.sh` | Deploy `pelias-es-snapshot.tar.bz2` + `pelias-data.tar.bz2` |
| `deploy-tiles.sh` | Deploy `tiles.tar` |
| `deploy-all.sh` | Run all scripts in dependency order |


## Elastic Search curl commands

```bash
# List all indices
curl -s http://localhost:39200/_cat/indices?v

# List all aliases
curl -s http://localhost:39200/_cat/aliases?v

# Show alias details (which indices an alias points to)
curl -s http://localhost:39200/_alias/pelias_* | python3 -m json.tool

# Check snapshot repository status
curl -s http://localhost:39200/_snapshot/pelias_repo | python3 -m json.tool

# List snapshots in the repository
curl -s http://localhost:39200/_snapshot/pelias_repo/_all | python3 -m json.tool

# Delete a snapshot
curl -X DELETE http://localhost:39200/_snapshots/pelias_repo/<snapshot_name>

# Cluster health
curl -s http://localhost:39200/_cluster/health | python3 -m json.tool
```
