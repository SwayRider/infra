# SwayRider

A comprehensive geolocation and routing platform built as a multi-repo microservices architecture (each service lives in its own top-level git repo). SwayRider provides multi-region route planning, geocoding, and user authentication services, primarily focused on European regions (Belgium, Netherlands, Luxembourg, France, and Germany).

## Architecture

The project follows a microservices architecture organized into four main layers:

```
Backend Services (Go)
├── AuthService      - Authentication & authorization
├── MailService      - Transactional email delivery
├── RegionService    - Geographic region queries
├── RouterService    - Multi-modal route planning
├── SearchService    - Geocoding (Pelias fan-out)
├── TilesService     - Vector tile serving (MBTiles/MVT)
├── swayrider-api    - API gateway (JWT validation, rate limiting, circuit breakers, proxying)
└── Shared Libraries (swlib)

Infrastructure (Docker Compose)
├── Layer 00: Base (Traefik, Elasticsearch, PostgreSQL, Redis, WireGuard)
├── Layer 10: Geospatial (Valhalla routing, Pelias geocoding)
├── Layer 20: SwayRider internal services (authservice, mailservice, regionservice, routerservice, searchservice, tilesservice)
└── Layer 30: SwayRider web services (swayrider-api gateway)

Data Pipeline (Python)
└── OSM data processing and publication
```

## Services

### AuthService
Centralized authentication and authorization service featuring:
- User registration with email verification
- JWT-based authentication with rolling keys
- Password management (reset, change, strength validation)
- Role-based access control

### MailService
Email delivery system with:
- Template-based email sending
- SMTP integration
- Template storage (database-backed)

### RegionService
Geographic region management providing:
- Region lookup by point, bounding box, or radius
- Border crossing detection
- Region path resolution for cross-border routing

### RouterService
Multi-modal route planning supporting:
- Multiple transport modes (car, motorcycle, motor scooter)
- Turn-by-turn navigation
- Route customization (avoid tolls, highways, trails, etc.)
- Cross-region routing with border crossing handling
- Integration with Valhalla (routing) and Pelias (geocoding)

### SearchService
Geocoding service providing:
- Fan-out search across per-region Pelias instances
- Address/POI autocomplete

### TilesService
Vector tile serving:
- MBTiles/MVT tile serving across a zoom-level hierarchy (L0–L3)

### swayrider-api
API gateway — the sole externally reachable entry point:
- JWT validation, rate limiting, circuit breakers
- Proxies requests to every other service over gRPC/HTTP

## Technology Stack

| Layer | Technologies |
|-------|-------------|
| Backend | Go, gRPC, gRPC-Gateway, Protocol Buffers, PostgreSQL, sqlc |
| Infrastructure | Docker, Traefik, Elasticsearch, Valhalla, Pelias |
| Data Pipeline | Python, GeoPandas, Shapely, Osmium |

## Project Structure

This `infra` repo is one of several top-level repos that make up the SwayRider platform (backend service code, protos, swlib, and grpcclients each live in their own repo alongside it — see the platform-level `Docs/` repo for the full layout). Its own contents:

```
infra/
├── dev/                  # Full dev environment: layer-00 (base) … layer-30 (web services)
│   ├── layer-00/         # Traefik, PostgreSQL, Elasticsearch, Redis, WireGuard
│   ├── layer-10/         # Valhalla (per-region), Pelias (per-region)
│   ├── layer-20/         # authservice, mailservice, regionservice, routerservice, searchservice, tilesservice
│   ├── layer-30/         # swayrider-api
│   └── scripts/          # deploy-*.sh helpers
└── dev-mini/             # Lightweight single-host dev variant (same layer structure)
```

API-testing collections (Bruno) live in the separate `testing` repo, not in `infra`.

## Data Pipeline

The Python data pipeline (`data-pipeline/`) processes OpenStreetMap (OSM) data into MBTiles
files served by the tile backend.

### Tile layers

| Layer | Zoom levels | Source | Description |
|-------|-------------|--------|-------------|
| L0 | Z0–6 | Natural Earth `ne_10m_land.geojson` | World overview |
| L1 | Z7–11 | OSM PBF + land-polygons shapefile | Regional detail |
| L2 | Z12–15 | OSM PBF | City/street level |
| L3 | Z16+ | OSM PBF | Full detail |

### Layer — `places` (L1, L2)

Point features for place name labels, sourced from OSM place nodes.

| Property | Values | Notes |
|----------|--------|-------|
| `place` | `city`, `town`, `village`, `hamlet`, `suburb`, `neighbourhood` | OSM place type |
| `name` | string | Display name |
| `population` | integer (string) | OSM population tag (if present) |
| `capital` | `yes`, `2` | National (`yes`) or sub-national (`2`) capital |
| `admin_level` | integer | OSM admin level |

**Zoom behaviour (map style):** place labels appear progressively to reduce density at lower zoom levels.

| Place type | Visible from | Condition |
|------------|-------------|-----------|
| Capitals | Z7 | `capital=yes` or `capital=2` |
| `city` | Z8 | population ≥ 25 000, unknown, or not set |
| `city` | Z9 | population known and < 25 000 |
| `town` | Z10 | — |
| `village` | Z12 | — |
| `hamlet`, `suburb` | Z14 | — |

Population is the OSM `population` tag (string). Missing or empty values fall back to the Z8 (major city) tier.

Capital detection: `capital=yes` (national capital) or `capital=2` (sub-national capital).
No simplification applied — place nodes are points.

### Feature properties — `motorway_link_type`

Applies to all `highway=motorway_link` features. Classifies the role of each ramp or
connector in the road network.

| Value | Meaning | Typical rendering |
|-------|---------|-------------------|
| `connector` | Chain of links forming a motorway-to-motorway path (not a single direct link) | Yellow |
| `off_ramp` | Departing the motorway — upstream reaches motorway, downstream does not | Yellow |
| `on_ramp` | Entering the motorway — downstream reaches motorway, upstream does not | Yellow |
| `exit` | Motorway_link not connected to any motorway (rare) | Yellow |
| `unknown` | No non-link road reachable from either endpoint | Not rendered |
| `""` (empty) | Set on all non-motorway_link features; tippecanoe drops the property | — |

**Detection method:** direction-aware BFS through motorway_link chains (respects OSM implicit
`oneway=yes` direction), combined with a single-hop direct-endpoint check that restricts the
`interchange` classification to links where BOTH endpoints directly touch a motorway segment.

What appears as a "bidirectional" Y-shaped ramp section in tile viewers is typically two
separate overlapping oneway OSM ways — one `on_ramp` and one `off_ramp` — sharing the same
physical road alignment. Each is classified independently.

## Development

### Prerequisites
- Go 1.26+ (workspace pins `go 1.26.4` in `go.work`)
- Docker & Docker Compose
- Python 3.11+ (for data pipeline)
- Protocol Buffer compiler (protoc)

### Getting Started

1. Clone the repository (and the sibling repos: `authservice`, `mailservice`, `regionservice`, `routerservice`, `searchservice`, `tilesservice`, `swayrider-api`, `swlib`, `grpcclients`, `protos`)
2. Copy environment templates and configure:
   ```bash
   cp infra/dev/layer-00/env.example infra/dev/layer-00/.env
   cp infra/dev/layer-10/env.example infra/dev/layer-10/.env
   cp infra/dev/layer-20/env.example infra/dev/layer-20/.env
   cp infra/dev/layer-30/env.example infra/dev/layer-30/.env
   ```
3. Start infrastructure services:
   ```bash
   cd infra/dev
   docker compose -f layer-00/compose.yaml up -d
   docker compose -f layer-10/compose.yaml up -d
   docker compose -f layer-20/compose.yml up -d
   docker compose -f layer-30/compose.yml up -d
   ```
4. Generate protobuf files (from the `protos` repo):
   ```bash
   cd protos && make
   ```

### API Testing
REST API collections for [Bruno](https://www.usebruno.com/) are available in the separate `testing` repo, under `testing/bruno/`.

## License

Proprietary
