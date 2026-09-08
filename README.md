# infa-basic

Shared infrastructure starter: one **PostgreSQL**, one **Redis**, one **MinIO**,
backing 4 apps on a single server — `petag`, `jbc`, `photoboxtyb`, `postyb`.

Each app gets its own isolated database, Redis ACL user, and MinIO bucket.

## Bootstrap (new server)

```sh
git clone <this-repo> infa-basic
cd infa-basic
cp .env.example .env
# fill .env with strong secrets — e.g. openssl rand -base64 24
docker compose up -d
./scripts/smoke-test.sh        # verify connectivity + isolation
```

`docker compose up -d` boots the 3 services, creates the per-app databases /
Redis users / MinIO buckets, and starts the daily backup container.

## How apps connect

All apps run on the **same server, in Docker**, joined to the external network
`shared-infra` (created by this project). In each app's `docker-compose.yml`:

```yaml
networks:
  shared-infra:
    external: true

services:
  myapp:
    networks: [shared-infra]
```

Then connect by service name:

| Service  | Connection string                                      | Notes |
|----------|---------------------------------------------------------|-------|
| Postgres | `postgresql://<app>:<pw>@postgres:5432/<app>`           | |
| Redis    | `redis://<app>:<pw>@redis:6379/0`                       | **keys must be prefixed `<app>:`** |
| MinIO    | endpoint `minio:9000`, per-app access/secret key, bucket `<app>` | |

Example for `petag`: db `petag`, Redis user `petag` (keys `petag:session:…`),
MinIO bucket `petag`.

Admin access from the host only (bound to `127.0.0.1`): Postgres `5432`,
Redis `6379`, MinIO API `9000`, MinIO console `9001`.

## Observability

Any app joined to `shared-infra` is already observed — its container logs and
its CPU, memory and network usage are collected with no code change, as are the
shared Postgres, Redis and MinIO it uses.

To also emit its own metrics and structured logs, an app installs an
OpenTelemetry SDK and sets:

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318
OTEL_SERVICE_NAME=<app>
```

## Isolation

- **Postgres** — each app owns its database; `CONNECT` is revoked from `PUBLIC`,
  so one app cannot reach another's database.
- **Redis** — each app is an ACL user limited to its `<app>:*` key and channel
  prefix. Apps **must** prefix every key, or reads/writes are denied.
- **MinIO** — each app user has a policy scoped to its own bucket only.

## Backups

The `backup` container runs daily at 03:00: `pg_dump` of every database, a Redis
RDB snapshot, and a mirror of every MinIO bucket — written to
`./backups/YYYY-MM-DD/`. Backups older than `BACKUP_RETENTION_DAYS` (default 7)
are pruned. `./backups` is gitignored — **copy it off-server yourself.**

Run a backup immediately:

```sh
docker compose exec backup /usr/local/bin/backup.sh
```

Restore a database:

```sh
gunzip -c backups/2026-05-20/petag.sql.gz | \
  docker compose exec -T postgres psql -U postgres -d petag
```

## Observability stack

| Service | Bound on | Purpose |
|---|---|---|
| `otel-collector` | in-network only | collects everything; OTLP on `:4317` / `:4318` |
| `victoriametrics` | `127.0.0.1:8428` | metrics, 30-day retention |
| `victorialogs` | `127.0.0.1:9428` | logs, 14 days, capped at 10 GB |
| `grafana` | `127.0.0.1:3001` | dashboards; state in the `grafana` database |
| `docker-socket-proxy` | in-network only | read-only Docker API for container stats |

The backends and the socket proxy live on a separate `observability` network
that apps never join: one app cannot read another's logs, write bogus metrics,
or reach the Docker API proxy — whose container-inspect responses include every
container's environment variables. Apps see exactly one observability endpoint:
`otel-collector:4318`.

On a fresh server, after `docker compose up -d`:

```sh
./scripts/setup-monitoring-db.sh        # creates otel_monitor + the grafana database
./scripts/observability-smoke-test.sh   # verifies collection end to end
```

Serve Grafana by pointing an nginx server block at `127.0.0.1:3001`. This repo
does not manage nginx.

**Adding an app:** grant the collector access to its database, or its database
metrics are silently missing while every other signal looks correct:

```sh
docker compose exec postgres psql -U postgres -c \
  "GRANT CONNECT ON DATABASE app5 TO otel_monitor;"
```

**To use an existing Prometheus instead of VictoriaMetrics:** point
`METRICS_REMOTE_WRITE_URL` at it and stop the `victoriametrics` service. The
collector needs no other change.

### Container names in logs

Docker's json-file records contain only `{"log","stream","time"}`, and the
directory holding them is named by container id. **The container name is not
in the logs and cannot be**, short of asking the Docker API per record. Log
records therefore carry `container_id`, not a name.

The name is resolved at query time instead: `docker_stats` publishes
`container_id` and `container_name` as metric labels, refreshed every 30s. The
`Container Logs` dashboard uses that as a lookup — you pick a name, it filters
logs by the matching id. Import it once:

```sh
# Grafana → Dashboards → New → Import → upload the file, then pick the
# VictoriaLogs and VictoriaMetrics datasources when prompted.
grafana/dashboards/container-logs.json
```

Dashboards are deliberately not provisioned from git, so anything you import or
draw stays editable and is never overwritten on restart. Their definitions live
in the `grafana` database, which `backup.sh` dumps.

### The old Prometheus is still load-bearing

Grafana keeps the previous monitoring stack's Prometheus as a second
datasource. Four migrated dashboards — Node Exporter Full, Docker Containers,
Nginx Edge, and Domains Uptime & SSL — read from **it**, not from the
collector, and the collector does not produce the series they need
(`probe_*`, `nginx_*`, `node_*`, `dockerstats_*`).

**Turning off the old exporters blanks those four dashboards and stops uptime
and SSL-expiry monitoring for ~10 domains.** Do not decommission them as
"replaced by OpenTelemetry" until either the collector is configured to scrape
the same targets (blackbox for uptime/SSL, nginx for edge metrics) or those
dashboards are rebuilt against collector metric names, which differ.

## Adding a 5th app later

The Postgres init script and MinIO provisioner only create resources for the
4 apps above. The Postgres script runs **only on a fresh data volume** —
editing it after first boot has no effect. To add an app on a running stack:

1. Add its secrets to `.env`.
2. Postgres — create the database + user manually:
   ```sh
   docker compose exec postgres psql -U postgres -c \
     "CREATE USER app5 WITH PASSWORD '...'; CREATE DATABASE app5 OWNER app5;
      REVOKE CONNECT ON DATABASE app5 FROM PUBLIC; GRANT CONNECT ON DATABASE app5 TO app5;"
   ```
3. Redis — add an `add_user` line to `redis/entrypoint.sh`, then
   `docker compose restart redis`.
4. MinIO — add a `provision` line to `minio/provision.sh`, then
   `docker compose up -d minio-provisioner`.
5. Observability — grant the collector `CONNECT` on the new database, or its
   database metrics are silently missing while every other signal looks correct:
   ```sh
   docker compose exec postgres psql -U postgres -c \
     "GRANT CONNECT ON DATABASE app5 TO otel_monitor;"
   ```

(For a clean 5-app setup from scratch, just edit the 4 source files first.)

## Common commands

```sh
docker compose ps                  # status
docker compose logs -f postgres    # logs
docker compose down                # stop (volumes kept)
docker compose down -v             # stop + DELETE ALL DATA
```
