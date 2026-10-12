# infra/data-manager

Infra for the `data-manager` app (see `../../data-manager/DESIGN.md`), parallel to
`infra/dev`/`infra/dev-mini`.

## Redis

`data-manager` gets its own dedicated Redis (`sw-datamanager-redis`), separate from
the shared `sw-dev-redis` in `infra/dev/layer-00` — it's an independent RQ
broker/queue for a different application, not something to share with the rest of
the dev stack.

It's reachable two ways, both pointing at the same Redis instance:

- **From containers** in this compose stack: internal hostname `redis` (port 6379).
- **From a host-run process** (the normal Phase 0 development loop — running
  `wsgi.py`/`run_worker.py` directly on the host for debugging): mapped port
  `redis://localhost:36389/0`.

## Bringing it up

```sh
cd infra/data-manager
docker compose up -d redis
```

Then, from `data-manager/`, with `.env` copied from `.env.example` (default
`REDIS_URL=redis://localhost:36389/0` already points at this service):

```sh
./.venv/bin/flask run
./.venv/bin/python run_worker.py   # in a second terminal
```

## Future: running data-manager itself as a stack

`compose.yaml` reserves (commented-out) `app`/`worker` services for eventually
running data-manager as an always-on stack rather than a host process. Not wired
up yet — Phase 0's actual acceptance testing happens via the host-run path above.
