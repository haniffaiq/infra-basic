# Observability Stack — Design

**Date:** 2026-09-08
**Status:** Approved
**Sub-project:** 1 of 3

## Context

`infa-basic` runs shared PostgreSQL, Redis, and MinIO for several applications
on a single 8 GB VPS with bare Docker Compose. It has no observability at all:
no metrics, no log aggregation, no dashboards, no alerting.

A review of the repo identified three separable bodies of work. Each gets its
own spec, plan, and implementation cycle:

1. **Observability stack** (this document) — purely additive; leaves the
   existing services almost untouched.
2. **Hardening** — `mem_limit` on every service, Redis `maxmemory` /
   `noeviction`, pinned image digests, MinIO healthcheck. Requires container
   recreation.
3. **Dynamic multi-app refactor** — remove the hardcoded four-app list
   (`petag`, `jbc`, `photoboxtyb`, `postyb`) so any number of app repos can be
   onboarded, including on a running stack.

Observability is sequenced first so that the two riskier bodies of work are
carried out with full visibility into their effect.

## Environment constraints

- Single Ubuntu VPS, 8 GB RAM. No Kubernetes, no cloud-managed services, no
  multiple instances.
- nginx runs under systemd on the host, not in a container. **This repo makes
  no changes to nginx.** nginx telemetry (`stub_status`, JSON access logs) is
  explicitly out of scope.
- Everything is self-hosted. No external SaaS, including for alerting. The
  accepted consequence: if the VPS itself goes down, no alert is delivered.
- A Grafana instance already exists on the server with its own dashboards and
  subdomain. It is **not** migrated and **not** modified. The Grafana in this
  repo is a fresh, separate instance.

## Goals

- Metrics and logs for the host, every container, PostgreSQL, Redis, and MinIO.
- New app repos are visible with **zero code changes** — they only need to join
  the `shared-infra` network.
- An OTLP endpoint is available from day one so apps can opt in to business
  metrics and structured logs.
- Traces are deferred, but no rework is required to add them later.

## Non-goals

- Traces (Tempo). Deferred to a follow-up; the collector gains one pipeline and
  one exporter when it lands.
- Dashboards as code. The operator builds dashboards manually in the Grafana
  UI. Exporting them to JSON and provisioning them from git is a later,
  optional step.
- Migrating the existing Grafana instance or its dashboards.
- nginx metrics and logs.
- Alert rules. Grafana unified alerting is available once the stack is up;
  authoring rules is separate work.

## Chosen approach

**OpenTelemetry Collector (contrib) + VictoriaMetrics + VictoriaLogs + Grafana.**
Roughly 750 MB of resident memory in normal operation, across five
containers. The `mem_limit` values in the table below sum to about 1.5 GB;
those are ceilings that contain a runaway process, not the expected footprint.

The contrib distribution ships native receivers for PostgreSQL, Redis, Docker,
and host metrics, so the stack needs **no separate exporter containers** —
`postgres_exporter`, `redis_exporter`, `node_exporter`, and `cadvisor` are all
replaced by receivers inside a single collector process.

### Alternatives rejected

**Prometheus + Loki** (~1.3–1.6 GB). The standard stack with the largest
dashboard ecosystem, but roughly twice the memory on a box that also runs
PostgreSQL, Redis, MinIO, and the applications. Loki's schema, compactor, and
retention configuration is error-prone, and a misconfiguration leaks disk
silently. Its main advantage — off-the-shelf community dashboards — does not
apply here, because dashboards are authored by hand.

**OpenObserve** (~250 MB, single binary). The smallest option, but it replaces
Grafana with its own UI, and Grafana is a requirement.

**SigNoz.** Requires ClickHouse, roughly 2 GB. Does not fit the memory budget.

### Why VictoriaMetrics specifically

It speaks PromQL and accepts Prometheus remote-write. If a Prometheus instance
already exists on the box, or the stack later moves elsewhere, only the
remote-write URL changes — there is no rewrite and no query-language lock-in.
The URL is therefore an `.env` variable
(`METRICS_REMOTE_WRITE_URL`), and the bundled VictoriaMetrics service can be
switched off without touching collector config.

VictoriaLogs uses **LogsQL**, not LogQL. This is a genuine cost — a different
query language with a smaller ecosystem — accepted because log volume under
zero-touch collection is high and VictoriaLogs holds it in a fraction of Loki's
memory.

## Architecture

### New files

```
otel/collector.yaml
grafana/provisioning/datasources/datasources.yml
scripts/observability-smoke-test.sh
scripts/setup-monitoring-db.sh
docs/superpowers/specs/2026-09-08-observability-design.md
```

### New services

| Service | Image | Published port | `mem_limit` | Volume |
|---|---|---|---|---|
| `otel-collector` | `otel/opentelemetry-collector-contrib` | none (internal `4317`/`4318`) | 300m | `otelstate` |
| `victoriametrics` | `victoriametrics/victoria-metrics` | `127.0.0.1:8428` | 512m | `vmdata` |
| `victorialogs` | `victoriametrics/victoria-logs` | `127.0.0.1:9428` | 384m | `vlogsdata` |
| `grafana` | `grafana/grafana` | `127.0.0.1:${GRAFANA_PORT}` | 256m | none (state in PostgreSQL) |
| `docker-socket-proxy` | `tecnativa/docker-socket-proxy` | none | 32m | none |

All join the existing `shared-infra` network. The collector publishes no host
port; applications reach it as `otel-collector:4318`.

Grafana coexists with the pre-existing instance: it binds `127.0.0.1:3001` and
is served from a new subdomain. The existing Grafana on port 3000 and its
nginx server block are untouched. The operator adds one new nginx server block
by hand; this repo does not manage it.

### Collector mounts

```
/var/lib/docker/containers:ro   filelog — logs from every container
/hostfs:ro (bind of /)          hostmetrics — host CPU, memory, disk, network
otelstate:/var/lib/otelcol      file_storage — read checkpoints and send queue
```

The Docker API is **not** mounted directly. See Security below.

### Grafana state in PostgreSQL

Grafana stores its state in a `grafana` database on the existing PostgreSQL
instance rather than in a SQLite volume. Hand-authored dashboards are the
primary asset this stack produces, and `backup/backup.sh` already dumps every
database — adding `grafana` to its app list is a one-word change. A SQLite
volume would not be backed up at all.

The accepted consequence: if PostgreSQL is down, Grafana will not start.
Metrics and logs continue to be collected and stored; only the UI is
unavailable. `depends_on: {postgres: {condition: service_healthy}}` and
`restart: unless-stopped` bring it back automatically.

## Components

### `otel/collector.yaml`

Receivers:

| Receiver | Replaces | Source |
|---|---|---|
| `otlp` (gRPC 4317, HTTP 4318) | — | applications, opt-in |
| `hostmetrics` | `node_exporter` | `/hostfs` |
| `docker_stats` | `cadvisor` | `tcp://docker-socket-proxy:2375` |
| `postgresql` | `postgres_exporter` | `postgres:5432` |
| `redis` | `redis_exporter` | `redis:6379` |
| `prometheus` | — | `minio:9000/minio/v2/metrics/cluster` |
| `filelog` | — | `/var/lib/docker/containers/*/*-json.log` |

The `filelog` receiver uses the `container` operator to parse Docker
json-file records and attach `container.name`. If that operator does not
resolve names reliably against this Docker version, the fallback is to read
container metadata and map IDs to names explicitly.

Two details are asserted from documentation rather than from a running
system, and are the first things implementation must verify against this
host (Docker 29.4.0):

- the `container` operator attaching `container.name` for the `json-file`
  driver, and
- `docker_stats` accepting a `tcp://` endpoint so it can reach the proxy
  instead of a mounted socket.

If the second does not hold, the choice is between mounting the socket
directly — reintroducing the escape risk documented under Security — and
dropping `docker_stats`, since `hostmetrics` and `filelog` do not depend
on it.

Processors, in pipeline order: `memory_limiter` (200 MiB, below the 300m
container limit), `resourcedetection` (`env`, `system`, `docker`), `batch`.

Exporters:

- `prometheusremotewrite` → `${METRICS_REMOTE_WRITE_URL}`
- `otlphttp/logs` → `${LOGS_OTLP_ENDPOINT}`

Both are configured with `retry_on_failure` and a **persistent** `sending_queue`
backed by the `file_storage` extension, so a backend restart does not lose data.

Extensions: `health_check` on `:13133` (used as the container healthcheck) and
`file_storage` on the `otelstate` volume.

Pipelines: `metrics` and `logs`. A `traces` pipeline is deliberately absent and
is the single addition required when Tempo lands.

### Retention

| Store | Setting | Rationale |
|---|---|---|
| VictoriaMetrics | `-retentionPeriod=${METRICS_RETENTION}` (default `30d`) | Metrics are small; roughly 1–2 GB at this scale. |
| VictoriaLogs | `-retentionPeriod=${LOGS_RETENTION}` (default `14d`) and `-retention.maxDiskSpaceUsageBytes=${LOGS_MAX_DISK}` (default `10GB`) | The disk cap is the important one. Log volume under zero-touch collection cannot be predicted, and this is what stops the disk from filling. |

### Grafana provisioning

`grafana/provisioning/datasources/datasources.yml` declares two datasources:

- **VictoriaMetrics** — type `prometheus`, `http://victoriametrics:8428`,
  marked default. PromQL works unchanged.
- **VictoriaLogs** — plugin `victoriametrics-logs-datasource`,
  `http://victorialogs:9428`. Installed via `GF_INSTALL_PLUGINS`, which
  requires outbound internet on first container start.

Configuration via environment: `GF_DATABASE_TYPE=postgres`,
`GF_DATABASE_HOST=postgres:5432`, `GF_DATABASE_NAME=grafana`,
`GF_SERVER_ROOT_URL`, `GF_SECURITY_ADMIN_PASSWORD`,
`GF_USERS_ALLOW_SIGN_UP=false`, `GF_AUTH_ANONYMOUS_ENABLED=false`.

**No dashboard provisioning.** Dashboards are authored in the UI and are not
locked read-only.

### New `.env` keys

```
OTEL_PG_PASSWORD=
GRAFANA_ADMIN_PASSWORD=
GRAFANA_DB_PASSWORD=
GRAFANA_PORT=3001
GRAFANA_ROOT_URL=https://infra.example.com
METRICS_REMOTE_WRITE_URL=http://victoriametrics:8428/api/v1/write
LOGS_OTLP_ENDPOINT=http://victorialogs:9428/insert/opentelemetry/v1/logs
METRICS_RETENTION=30d
LOGS_RETENTION=14d
LOGS_MAX_DISK=10GB
```

All are added to `.env.example` with blank or default values.

## Data flow

```
zero-touch
  every container  -> /var/lib/docker/containers/*-json.log -> filelog     -.
  docker-socket-proxy ------------------------------------- -> docker_stats -|
  host via /hostfs ---------------------------------------- -> hostmetrics  -|
  postgres:5432 ------------------------------------------- -> postgresql   -|
  redis:6379 ---------------------------------------------- -> redis        -|
  minio:9000 ---------------------------------------------- -> prometheus   -|
opt-in                                                                       |
  app -> OTLP :4317/:4318 ---------------------------------- -> otlp        -'
                                                                             |
                        otel-collector                                       |
       memory_limiter -> resourcedetection -> batch <-------------------------'
                              |
              metrics         |          logs
     victoriametrics:8428 <---+---> victorialogs:9428
                              |
                    grafana :3001  (state -> postgres/grafana)
                              ^
                  nginx (systemd, host) -> new subdomain
```

## Application onboarding

**Zero-touch.** A new app joins `shared-infra` and immediately produces
container logs, CPU/memory/network metrics, and — once its database, Redis ACL
user, and bucket exist — database, cache, and object-storage metrics. No code
change.

**Opt-in.** An app that wants business metrics or structured logs sets:

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318
OTEL_SERVICE_NAME=<app>
```

and installs an OpenTelemetry SDK. The endpoint exists from day one, so this
can happen per-app, at any time, with no infrastructure change.

## Security

**The Docker API is not exposed to the collector directly.** Mounting
`/var/run/docker.sock` — even with `:ro`, which makes only the socket file
read-only and not the API behind it — grants the container the ability to
create privileged containers and escape to the host. `docker_stats` needs only
container listing and stats.

`tecnativa/docker-socket-proxy` is therefore placed in front of it, with
`CONTAINERS=1` (list and stats) and `VERSION=1` (the Docker client pings
`/version` to negotiate an API version and fails without it), and every
mutating endpoint disabled. The proxy holds the socket
mount; the collector talks HTTP to the proxy. It costs roughly 32 MB and
removes the only root-equivalent blast radius in the stack.

Other notes:

- The collector holds the Redis `default` (admin) password, required by the
  `redis` receiver for `INFO`, and the `otel_monitor` PostgreSQL password.
- No new host ports are exposed publicly. VictoriaMetrics, VictoriaLogs, and
  Grafana bind `127.0.0.1` only; the collector binds nothing on the host.
- Grafana anonymous access and self sign-up are disabled.

## Changes to existing services

Three, all small, listed explicitly because two are easy to miss:

1. **MinIO** — add `MINIO_PROMETHEUS_AUTH_TYPE=public`. Without it the metrics
   endpoint requires a JWT. Safe: MinIO is reachable only on `127.0.0.1` and
   the `shared-infra` network. **Requires recreating the MinIO container.**
2. **PostgreSQL** — create an `otel_monitor` user and a `grafana` database.
   `postgres/init/01-create-apps.sh` runs only on an empty data volume, so on
   the live stack this is a one-time manual step, provided as
   `scripts/setup-monitoring-db.sh`. No restart, no downtime.
3. **`backup/backup.sh`** — add `grafana` to `APPS` so Grafana's state is
   backed up.

Additionally, a `json-file` logging anchor with `max-size: 10m` and
`max-file: 3` is applied to every service. This was originally scoped to
sub-project 2, and is pulled forward: the stack now *reads*
`/var/lib/docker/containers/*-json.log`, and unrotated logs grow without bound
until the disk fills. `filelog` handles rotation correctly via glob and poll.

### Required grant, and a cross-sub-project dependency

`postgres/init/01-create-apps.sh` runs
`REVOKE CONNECT ON DATABASE <app> FROM PUBLIC`, so `otel_monitor` cannot reach
any app database without an explicit grant:

```sql
CREATE USER otel_monitor WITH PASSWORD '...';
GRANT pg_monitor TO otel_monitor;
GRANT CONNECT ON DATABASE petag, jbc, photoboxtyb, postyb, grafana TO otel_monitor;
```

**Dependency:** the `add-app.sh` script built in sub-project 3 must also issue
`GRANT CONNECT ON DATABASE <newapp> TO otel_monitor`. If it does not, new apps
will be invisible in database metrics while appearing correct everywhere else —
a silent, hard-to-diagnose gap.

## Failure modes

| Event | Effect | Handling |
|---|---|---|
| Collector restarts | Duplicated or missing log lines | `file_storage` extension persists `filelog` read checkpoints on the `otelstate` volume. Without it, every restart re-reads or skips. |
| VictoriaMetrics or VictoriaLogs down | Telemetry gap | Persistent `sending_queue` plus `retry_on_failure`; the queue drains when the backend returns. |
| PostgreSQL down | Grafana will not start | Accepted consequence of the PostgreSQL backend. Collection and storage continue; only the UI is lost. Recovers automatically. |
| Disk fills | Whole box at risk | VictoriaLogs `maxDiskSpaceUsageBytes` and VictoriaMetrics retention are the primary brakes; Docker log rotation is the secondary one. |
| Collector exceeds memory | Telemetry interrupted | `memory_limiter` at 200 MiB sits below the 300m container limit, so the collector sheds data rather than being OOM-killed. |
| An app emits high-cardinality OTLP | VictoriaMetrics grows | Bounded by `mem_limit`; watch series growth once dashboards exist. |

## Testing

`scripts/observability-smoke-test.sh`, following the existing
`scripts/smoke-test.sh` conventions (`ok`/`FAIL` counters, non-zero exit on
failure), run after `docker compose up -d` settles:

1. Collector `:13133` health endpoint returns 200.
2. VictoriaMetrics holds series from **every** receiver: `postgresql_*`,
   `redis_*`, `system_cpu_*`, `container_*`, `minio_*`.
3. VictoriaLogs holds records from the last 5 minutes, from at least three
   distinct containers.
4. Grafana `/api/health` reports ok, and `/api/datasources` shows both
   datasources provisioned.
5. **OTLP round-trip:** a synthetic log record and metric are posted to
   `:4318` and asserted present in VictoriaLogs and VictoriaMetrics. This
   proves the opt-in path works before any application repo is touched.

## Rollback

```sh
docker compose stop otel-collector victoriametrics victorialogs grafana docker-socket-proxy
```

PostgreSQL, Redis, and MinIO are unaffected. The only residue is the MinIO
environment variable, the `otel_monitor` user, and the `grafana` database — all
inert while the stack is stopped. Reverting the MinIO variable requires
recreating that container.

## Follow-up work

- Traces: Tempo with the existing MinIO as its S3 backend, plus a `traces`
  pipeline in the collector and OTel SDKs in the app repos.
- Alert rules in Grafana: backup failure, disk above 80%, service down,
  PostgreSQL connections above 80%.
- Export hand-authored dashboards to JSON and provision them from git.
- nginx telemetry, if the constraint that this repo not touch nginx is relaxed.
