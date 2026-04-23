# SwayRider

A comprehensive geolocation and routing platform built as a monorepo with a microservices architecture. SwayRider provides multi-region route planning, geocoding, and user authentication services, primarily focused on European regions (Belgium, Netherlands, Luxembourg, France, and Germany).

## Architecture

The project follows a microservices architecture organized into four main layers:

```
Backend Services (Go)
├── AuthService      - Authentication & authorization
├── MailService      - Transactional email delivery
├── RegionService    - Geographic region queries
├── RouterService    - Multi-modal route planning
└── Shared Libraries (swlib)

Infrastructure (Docker Compose)
├── Layer 00: Base (Traefik, Elasticsearch, PostgreSQL)
├── Layer 10: Geospatial (Valhalla routing, Pelias geocoding)
└── Layer 20: SwayRider internal services

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

## Technology Stack

| Layer | Technologies |
|-------|-------------|
| Backend | Go, gRPC, gRPC-Gateway, Protocol Buffers, PostgreSQL, sqlc |
| Infrastructure | Docker, Traefik, Elasticsearch, Valhalla, Pelias |
| Data Pipeline | Python, GeoPandas, Shapely, Osmium |

## Project Structure

```
swayrider/
├── backend/
│   ├── services/        # Go microservices
│   │   ├── authservice/
│   │   ├── mailservice/
│   │   ├── regionservice/
│   │   └── routerservice/
│   ├── protos/          # gRPC/Protocol Buffer definitions
│   ├── swlib/           # Shared Go utilities
│   ├── grpcclients/     # gRPC client generators
│   └── restclients/     # REST client utilities
├── data-pipeline/       # Python OSM data processing
├── infra/
│   └── dev/             # Docker Compose configurations
├── rest/                # API documentation (Bruno collections)
└── Makefile             # Build orchestration
```

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
- Go 1.21+
- Docker & Docker Compose
- Python 3.11+ (for data pipeline)
- Protocol Buffer compiler (protoc)

### Getting Started

1. Clone the repository
2. Copy environment templates and configure:
   ```bash
   cp infra/dev/.env.template infra/dev/.env
   ```
3. Start infrastructure services:
   ```bash
   cd infra/dev
   docker-compose -f layer-00-base.yml up -d
   docker-compose -f layer-10-geospatial.yml up -d
   docker-compose -f layer-20-swayrider.yml up -d
   ```
4. Generate protobuf files:
   ```bash
   make protos
   ```

### API Testing
REST API collections for [Bruno](https://www.usebruno.com/) are available in the `rest/` directories throughout the project.

## License

Proprietary
