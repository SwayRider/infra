# Building & Development

## Protocol Buffers

Protocol Buffers must be generated before building services.

```bash
make proto
# or
cd backend/protos && make
```

This regenerates Go code in `backend/protos/gen/go/`.

## Backend Services (Go)

Build all backend code:

```bash
cd backend && go build ./...
```

Build a single service:

```bash
cd backend && go build ./services/authservice/cmd/authservice
```

Run a service locally:

```bash
cd backend && go run ./services/authservice/cmd/authservice
```

## Database Migrations (AuthService)

AuthService uses `sql-migrate`.

```bash
cd backend/services/authservice && make migrate-up
cd backend/services/authservice && make migrate-down
cd backend/services/authservice && make migrate-status
```

Install the tool if needed:

```bash
go install github.com/rubenv/sql-migrate/...@latest
```

## Docker

Build and push all service containers:

```bash
make services-containers
```

Build a single service container:

```bash
make services-authservice-container
```

## Testing

Run all backend tests:

```bash
cd backend && go test ./...
```

Run tests for a specific package:

```bash
cd backend && go test ./swlib/...
```

## Notes

* Generated binaries should be removed after verification
* Do not run data-pipeline code locally

