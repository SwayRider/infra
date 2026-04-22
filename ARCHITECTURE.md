# SwayRider Architecture

## Overview

SwayRider is a Go-based microservices platform for multi-region routing and geocoding. The repository is organized as a monorepo, but services are logically isolated and communicate exclusively over gRPC.

## Backend Services

All backend services are implemented in Go and follow a common bootstrap pattern provided by `swlib/app`.

### Service Bootstrap Pattern

```go
application := app.New("servicename").
    WithDefaultConfigFields(app.BackendServiceFields | app.DatabaseConnectionFields).
    WithServiceClients(app.NewServiceClient("otherservice", clientCtor)).
    WithDatabase(dbCtor, dbBootstrap).
    WithGrpc(grpcConfig).
    Run()
```

### Interfaces

Each service may expose:

* **gRPC** (internal, default port 8081)
* **REST** via grpc-gateway (default port 8080)
* **Web / static** endpoints (optional, default port 8000)

### Service Communication

* All inter-service communication uses gRPC
* Client wrappers live in `backend/grpcclients/{service}`
* Clients are resolved via the app framework:

```go
client := app.GetServiceClient[*mailclient.Client](a, "mailservice")
```

Endpoints are configured through environment variables:

* `{SERVICE}_HOST`
* `{SERVICE}_PORT`

## Protocol Buffers

* Protos live in `backend/protos/{service}/v1/`
* Generated Go code is written to `backend/protos/gen/go/`
* Protos are shared across services and clients

## Shared Libraries (`swlib`)

`backend/swlib/` contains shared infrastructure and utilities:

* `app/` – service bootstrap and lifecycle
* `grpc/`, `http/` – transport helpers
* `jwt/`, `crypto/`, `security/` – auth & security
* `logger/` – logging utilities

`swlib` must not be modified or scanned unless explicitly required.

## Infrastructure Layers

Docker Compose configuration is layered under `infra/dev/`:

* **layer-00**: base services (Traefik, PostgreSQL, Minio, Elasticsearch)
* **layer-10**: geospatial services (Valhalla, Pelias)
* **layer-20**: SwayRider services

Each layer builds on the previous one.

