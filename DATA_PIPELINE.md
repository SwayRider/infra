# Data Pipeline — Tile Generation

## Purpose

The data pipeline generates MBTiles files consumed by the `tilesservice`. It is resource-intensive and intended to run **only on the server**.

## Location

```
data-pipeline/
├── config/
├── gis/
│   ├── data/      # Source GIS data (OSM PBF, shapefiles)
│   └── export/    # Exported intermediate data
└── pipeline/
    ├── tiles.py
    ├── osm_funcs.py
    ├── utils/
    └── manifest/
```

## Processing Stages

1. **OSM Extraction** (`osm_funcs.py`)

   * Extracts roads, water, landuse, boundaries from OSM PBF files

2. **GeoJSON Conversion** (`tiles.py`)

   * Converts extracted data to GeoJSON using `osmium`

3. **Vector Tile Generation** (`tiles.py`)

   * Generates MBTiles using `tippecanoe`

## Tippecanoe Configuration

Key flags used:

* `--coalesce-densest-as-needed`
* `--simplification=N` (varies by zoom level)
* `--buffer=64`
* `--extend-zooms-if-still-dropping`

These settings prioritize visual continuity over aggressive feature dropping.

## Regenerating Tiles

To regenerate tiles on the server:

1. Delete existing `.mbtiles` files in the output directory
2. Re-run the pipeline — existing outputs are skipped automatically

## Constraints

* **Do NOT run locally**
* **Do NOT execute tests**
* Test files may exist for documentation purposes only

