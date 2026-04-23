# Organisation of SwayRider Docker Compose setup

The setup is composed of several layers, each building upon eachother:

- layer-00: Base infrastructure and data services
- layer-10: Swayrider Data Services
- layer-20: Swayrider Internal Services
- layer-30: Swyrider Web Services

## Setup

### Prerequisites

1. Copy environment templates:

```bash
cp layer-00/env.example layer-00/.env
cp layer-10/env.example layer-10/.env
cp layer-20/env.example layer-20/.env
```

2. Edit `.env` files to match your setup (paths, passwords, domain)

### Starting the stack

```bash
# Start in order (layer-10 depends on layer-00 networks, etc.)
docker compose -f layer-00/compose.yaml up -d
docker compose -f layer-10/compose.yaml up -d
docker compose -f layer-20/compose.yml up -d
```

### Domain Configuration

Set `DEV_DOMAIN` in your layer-00 `.env` file. All services will be accessible at `<service>.${DEV_DOMAIN}`.

Default: `example.com` (for local development without real DNS)

## Layer 00

### Networks

net-sw-dev-proxy: 10.10.0.0/24
net-sw-dev-data: 10.10.1.0/24

### Traefik

#### sw-dev-traefik

internal hostname: traefik

Networks:
- net-sw-dev-proxy

Exposed Ports:
- 30080
- 30443
- 38080

### Minio

> **DEPRECATED:** Minio was previously used for mail template storage. MailService now uses database-backed templates.

### Elastic Search

#### sw-dev-prepare-elasticsearch (init container)
#### sw-dev-elasticsearch

internal hostname: elasticsearch

Networks:
- net-ws-dev-data

Exposed Ports:
- 39200
- 39300

### Postgres

#### sw-dev-postgres

internal hostname: postgress

Networks:
- net-sw-dev-data

Exposed Ports:
- 35432


## Layer 10

### Networks

net-sw-dev-valhalla: 10.10.10.0/24
net-sw-dev-pelias: 10.10.11.0/24

### Valhalla

#### sw-dev-valhalla-iberian-peninsula

internal hostname: valhalla-iberian-peninsula
public hostname: valhalla-iberian-peninsula.${DEV_DOMAIN}

Networks:
- net-sw-dev-valhalla
- net-sw-dev-proxy

Exposed Ports:
- 33001

#### sw-dev-valhalla-west-europe

internal hostname: valhalla-west-europe
public hostname: valhalla-west-europe.${DEV_DOMAIN}

Networks:
- net-sw-dev-valhalla
- net-sw-dev-proxy

Exposed Ports:
- 33002

#### sw-dev-pelias-placeholder

internal hostname: pelias-placeholder
public hostname: pelias-placeholder.${DEV_DOMAIN}

Networks:
- net-sw-dev-pelias
- net-sw-dev-proxy

Exposed Ports:
- 33100

#### sw-dev-pelias-libpostal

internal hostname: pelias-libpostal
public hostname: pelias-libpostal.${DEV_DOMAIN}

Networks:
- net-sw-dev-pelias
- net-sw-dev-proxy

Exposed Ports:
- 33101

#### sw-dev-pelias-iberian-peninsula-pip

internal hostname: pelias-iberian-peninsula-pip
public hostname: pelias-iberian-peninsula-pip.${DEV_DOMAIN}

Networks:
- net-sw-dev-pelias
- net-sw-dev-proxy

Exposed Ports:
- 33110

#### sw-dev-pelias-west-europe-pip

internal hostname: pelias-west-europe-pip
public hostname: pelias-west-europe-pip.${DEV_DOMAIN}

Networks:
- net-sw-dev-pelias
- net-sw-dev-proxy

Exposed Ports:
- 33120

#### sw-dev-pelias-iberian-peninsula-api

internal hostname: pelias-iberian-peninsula-api
public hostname: pelias-iberian-peninsula-api.${DEV_DOMAIN}

Networks:
- net-sw-dev-pelias
- net-sw-data
- net-sw-dev-proxy

Exposed Ports:
- 33111

#### sw-dev-pelias-west-europe-api

internal hostname: pelias-west-europe-api
public hostname: pelias-west-europe-api.${DEV_DOMAIN}

Networks:
- net-sw-dev-pelias
- net-sw-data
- net-sw-dev-proxy

Exposed Ports:
- 33121
