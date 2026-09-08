# Observability Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `infa-basic` metrics and logs for the host, every container, PostgreSQL, Redis and MinIO, viewable in a fresh Grafana, with an OTLP endpoint ready for applications to opt into.

**Architecture:** One OpenTelemetry Collector (contrib distribution) gathers everything. Its native `postgresql`, `redis`, `docker_stats` and `hostmetrics` receivers replace what would otherwise be four separate exporter containers. Metrics go to VictoriaMetrics over Prometheus remote-write; logs go to VictoriaLogs over OTLP. Grafana reads both and stores its own state in the existing PostgreSQL. Nothing scrapes the applications — they are observed from the outside, and may later push OTLP in addition.

**Tech Stack:** Docker Compose, OpenTelemetry Collector contrib, VictoriaMetrics, VictoriaLogs, Grafana, `tecnativa/docker-socket-proxy`, POSIX shell.

**Spec:** `docs/superpowers/specs/2026-09-08-observability-design.md`

## Global Constraints

- Branch: `observability`. Do not commit to `main`.
- Single VPS, 8 GB RAM. No Kubernetes, no cloud-managed services.
- **This repo makes no changes to nginx.** nginx runs under systemd on the host. No `stub_status`, no access-log collection, no server block managed here.
- The pre-existing Grafana on the server is not modified and not migrated. The new Grafana binds `127.0.0.1:${GRAFANA_PORT}`, default `3001`.
- No new port is published on a public interface. VictoriaMetrics, VictoriaLogs and Grafana bind `127.0.0.1` only; the collector and the socket proxy publish nothing.
- VictoriaMetrics, VictoriaLogs and the socket proxy attach **only** to the `observability` network — never to `shared-infra`. The proxy's container-inspect endpoint returns every container's environment variables (all secrets), and the two stores are unauthenticated, so on the app network any compromised app could read other apps' logs. Apps see exactly one endpoint: `otel-collector:4318`.
- No dashboards are provisioned. Dashboards are authored by hand in the Grafana UI and must remain editable.
- Traces are out of scope. Do not add a `traces` pipeline.
- Every new service gets a `mem_limit`: collector `300m`, VictoriaMetrics `512m`, VictoriaLogs `384m`, Grafana `256m`, socket proxy `64m`.
- Retention defaults: metrics `30d`, logs `14d` capped at `10GB` of disk.
- Every new `.env` key must also be added to `.env.example` with a blank or default value. `.env` is gitignored; never commit it.

## Where verification runs

Every task is verified on the Ubuntu VPS where the stack runs. `filelog`,
`hostmetrics` and `docker_stats` read Linux host paths and the Docker Engine
API, so there is no second environment to reason about: build and verify in one
place.

**Check how Docker was installed before Task 4.** The `filelog` include path
differs, and getting it wrong means logs are silently never collected:

```sh
docker info --format '{{.DockerRootDir}}'
```

- `/var/lib/docker` — apt or the official Docker repo. The paths in this plan
  are correct as written.
- `/var/snap/docker/common/var-lib-docker` — the snap package. Replace
  `/var/lib/docker/containers` with that path plus `/containers` in **both** the
  `filelog` `include` glob and the collector's bind mount, everywhere they
  appear in Tasks 1, 4 and 8.

Bring the stack up before starting:

```sh
docker compose up -d
docker compose ps        # all healthy before proceeding
```

---

### Task 1: Verify the two unproven receiver assumptions

The spec records two details taken from documentation rather than from a running
system. Both can change the design, so they are settled before any of it is
built. Nothing from this task is kept.

**Files:**
- Create: `/tmp/preflight-collector.yaml` (throwaway, not committed)

**Interfaces:**
- Consumes: nothing.
- Produces: a decision recorded in the commit message of Task 4 — whether
  `docker_stats` reaches Docker over `tcp://`, and whether the `container`
  operator attaches a usable container name attribute.

- [ ] **Step 1: Record the Docker root directory**

Run: `docker info --format '{{.DockerRootDir}}'`
Expected: `/var/lib/docker` on an apt install, or
`/var/snap/docker/common/var-lib-docker` on the snap.

Every `/var/lib/docker/containers` below assumes the first. If you got the
second, substitute it consistently from here on — in this task, Task 4 and
Task 8.

- [ ] **Step 2: Start a throwaway socket proxy**

```bash
docker network create preflight-net
docker run -d --name preflight-proxy --network preflight-net \
  -e CONTAINERS=1 -e VERSION=1 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  tecnativa/docker-socket-proxy:latest
```

- [ ] **Step 3: Confirm the proxy answers the two endpoints `docker_stats` needs**

```bash
docker run --rm --network preflight-net curlimages/curl:latest \
  -sf http://preflight-proxy:2375/version >/dev/null && echo "version OK"
docker run --rm --network preflight-net curlimages/curl:latest \
  -sf http://preflight-proxy:2375/containers/json >/dev/null && echo "containers OK"
```

Expected: both lines print. If `/version` fails, `VERSION=1` was the missing
piece and the spec's note is confirmed.

- [ ] **Step 4: Write the throwaway collector config**

```bash
cat > /tmp/preflight-collector.yaml <<'EOF'
receivers:
  docker_stats:
    endpoint: tcp://preflight-proxy:2375
    collection_interval: 10s
  filelog:
    include: [/var/lib/docker/containers/*/*-json.log]
    start_at: end
    operators:
      - type: container
exporters:
  debug:
    verbosity: detailed
service:
  pipelines:
    metrics: {receivers: [docker_stats], exporters: [debug]}
    logs: {receivers: [filelog], exporters: [debug]}
EOF
```

- [ ] **Step 5: Run the collector and capture output**

```bash
docker run -d --name preflight-otel --network preflight-net --user 0 \
  -v /tmp/preflight-collector.yaml:/etc/otelcol-contrib/config.yaml:ro \
  -v /var/lib/docker/containers:/var/lib/docker/containers:ro \
  otel/opentelemetry-collector-contrib:latest

# generate a log line for filelog to pick up
docker run --rm alpine:3.20 echo "preflight-marker"
sleep 30
docker logs preflight-otel > /tmp/preflight.log 2>&1
```

`--user 0` is required, not optional: the image defaults to UID 10001, which
cannot read `/var/lib/docker/containers` (mode 0700, root-owned). Without it
this preflight sees an empty filelog and misdiagnoses assumption B as an
operator problem when it is a permission problem.

- [ ] **Step 6: Check assumption A — `docker_stats` over `tcp://`**

Run: `grep -c 'container.cpu' /tmp/preflight.log`
Expected: a count greater than 0.

If it is 0, run `grep -i 'error\|refused\|api version' /tmp/preflight.log` and
record the message. Two fallbacks, in order of preference:
1. Pin the API version — add `api_version: "1.44"` to the receiver and retry.
2. If it still fails, **drop `docker_stats` from the design.** Do not mount the
   Docker socket into the collector as a workaround — the spec rejects that on
   security grounds. `hostmetrics` and `filelog` do not depend on this receiver,
   so the rest of the plan proceeds unchanged; note the removal in Task 4.

- [ ] **Step 7: Check assumption B — the `container` operator names containers**

```bash
grep -A5 'preflight-marker' /tmp/preflight.log | grep -i 'container'
```

Expected: an attribute carrying the container name.

Record the exact attribute key you see — it may be `container.name`,
`container_name`, or `log.file.name`. Task 8 and the smoke test use whatever
this prints; do not assume `container.name`.

If no name attribute appears at all, the fallback is `log.file.path`, which
contains the container ID, plus a `transform` processor. Record which applies.

- [ ] **Step 8: Tear down**

```bash
docker rm -f preflight-otel preflight-proxy
docker network rm preflight-net
rm -f /tmp/preflight-collector.yaml /tmp/preflight.log
```

Nothing is committed in this task. Carry the two findings into Task 4 and Task 8.

---

### Task 2: Bound Docker log growth

`filelog` will read `/var/lib/docker/containers/*/*-json.log` from Task 8
onward. Unrotated, those files grow until the disk fills. This lands first so
the stack is never reading from unbounded files.

**Files:**
- Modify: `docker-compose.yml` (add anchor near the top; add `logging: *logging` to all 5 existing services)

**Interfaces:**
- Consumes: nothing.
- Produces: the `*logging` YAML anchor, reused by every service added in later tasks.

- [ ] **Step 1: Add the anchor above `networks:`**

```yaml
x-logging: &logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"
```

- [ ] **Step 2: Attach it to all five existing services**

Add `logging: *logging` as a top-level key of `postgres`, `redis`, `minio`,
`minio-provisioner` and `backup`. Example for `postgres`:

```yaml
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    logging: *logging
```

- [ ] **Step 3: Verify the file still parses**

Run: `docker compose config >/dev/null && echo VALID`
Expected: `VALID`

- [ ] **Step 4: Apply and confirm the option reached the daemon**

```bash
docker compose up -d
docker inspect infa-basic-postgres-1 --format '{{json .HostConfig.LogConfig}}'
```

Expected: JSON showing `"max-size":"10m"` and `"max-file":"3"`.

Note: this recreates the containers, so PostgreSQL, Redis and MinIO restart
briefly. Named volumes are untouched and no data is lost. If the container name
differs, get it from `docker compose ps -q postgres`.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml
git commit -m "chore: cap docker json-file logs at 10m x 3"
```

---

### Task 3: VictoriaMetrics

The metrics backend goes in first, because the collector cannot be tested
without somewhere to write.

**Files:**
- Modify: `docker-compose.yml` (add `victoriametrics` service, add `vmdata` volume)
- Modify: `.env.example`
- Create: `scripts/observability-smoke-test.sh`

**Interfaces:**
- Consumes: `*logging` from Task 2.
- Produces:
  - the `observability` network, joined by every later observability service
  - service `victoriametrics`, reachable on it as `http://victoriametrics:8428`
  - `.env` keys `METRICS_REMOTE_WRITE_URL`, `METRICS_RETENTION`
  - `scripts/observability-smoke-test.sh` with helpers `ok`, `bad`, and a `pass`/`fail` counter, extended by every later task

- [ ] **Step 1: Write the failing check**

Create `scripts/observability-smoke-test.sh`:

```bash
#!/usr/bin/env bash
# Verifies the observability stack is collecting and storing telemetry.
# Run after `docker compose up -d` has settled. Run from the repo root.
set -u

cd "$(dirname "$0")/.."
if [ ! -f .env ]; then echo "ERROR: .env not found"; exit 1; fi
set -a; . ./.env; set +a

pass=0; fail=0
ok()  { echo "  ok   - $1"; pass=$((pass+1)); }
bad() { echo "  FAIL - $1"; fail=$((fail+1)); }

# Runs curl inside the observability network, where the backends live.
# Apps on shared-infra cannot reach these services; that is deliberate.
netcurl() { docker run --rm --network observability curlimages/curl:latest -s "$@"; }

echo "== VictoriaMetrics =="
if netcurl -f http://victoriametrics:8428/health | grep -q OK; then
  ok "victoriametrics is healthy"
else
  bad "victoriametrics is healthy"
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
```

Then: `chmod +x scripts/observability-smoke-test.sh`

- [ ] **Step 2: Run it to confirm it fails**

Run: `./scripts/observability-smoke-test.sh`
Expected: `FAIL - victoriametrics is healthy`, exit code 1. The service does not
exist yet.

- [ ] **Step 3: Add the service**

Extend the top-level `networks:` block — the backends get a network of their
own so applications on `shared-infra` can never reach them:

```yaml
networks:
  default:
    name: shared-infra
  observability:
    name: observability
```

Under `volumes:` add `vmdata:`. Then add the service:

```yaml
  victoriametrics:
    image: victoriametrics/victoria-metrics:latest
    restart: unless-stopped
    logging: *logging
    mem_limit: 512m
    networks: [observability]
    command:
      - "-storageDataPath=/victoria-metrics-data"
      - "-retentionPeriod=${METRICS_RETENTION:-30d}"
      - "-httpListenAddr=:8428"
    volumes:
      - vmdata:/victoria-metrics-data
    ports:
      - "127.0.0.1:8428:8428"
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8428/health"]
      interval: 30s
      timeout: 5s
      retries: 3
```

- [ ] **Step 4: Add the new keys to `.env.example`**

```
# ── Observability ────────────────────────────────────────────
# Where the collector writes metrics. Point this at an existing
# Prometheus instead, and stop the victoriametrics service, if you have one.
METRICS_REMOTE_WRITE_URL=http://victoriametrics:8428/api/v1/write
METRICS_RETENTION=30d
```

Then add the same two lines to your local `.env`.

- [ ] **Step 5: Bring it up and confirm the check passes**

```bash
docker compose up -d victoriametrics
./scripts/observability-smoke-test.sh
```

Expected: `ok   - victoriametrics is healthy`, exit code 0.

- [ ] **Step 6: Commit**

```bash
git add docker-compose.yml .env.example scripts/observability-smoke-test.sh
git commit -m "feat(observability): add victoriametrics and smoke test harness"
```

---

### Task 4: Socket proxy and collector, with host and container metrics

The collector's first two receivers. Both are Linux-host specific.

**Verify this task on the Linux VPS.**

**Files:**
- Create: `otel/collector.yaml`
- Modify: `docker-compose.yml` (add `docker-socket-proxy` and `otel-collector`, add `otelstate` volume)
- Modify: `scripts/observability-smoke-test.sh`

**Interfaces:**
- Consumes: `victoriametrics`, the `observability` network and `METRICS_REMOTE_WRITE_URL` from Task 3; the two findings from Task 1.
- Produces:
  - service `otel-collector`, health endpoint `http://otel-collector:13133`
  - the `file_storage` extension at `/var/lib/otelcol/storage`, reused by Task 8 for `filelog` checkpoints
  - the `metrics` pipeline, extended by Tasks 5, 6, 7 and 9

- [ ] **Step 1: Write the failing checks**

Append to `scripts/observability-smoke-test.sh`, before the final `echo`:

```bash
echo "== Collector =="
if netcurl -f http://otel-collector:13133 >/dev/null; then
  ok "collector is healthy"
else
  bad "collector is healthy"
fi

# Asserts at least one stored series whose name starts with $1.
have_metric() {
  netcurl "http://victoriametrics:8428/api/v1/label/__name__/values" \
    | grep -q "\"$1" && ok "metrics present: $1*" || bad "metrics present: $1*"
}

have_metric system_
have_metric container_
```

- [ ] **Step 2: Run it to confirm the new checks fail**

Run: `./scripts/observability-smoke-test.sh`
Expected: `FAIL - collector is healthy`, `FAIL - metrics present: system_*`,
`FAIL - metrics present: container_*`. VictoriaMetrics still passes.

- [ ] **Step 3: Write `otel/collector.yaml`**

```yaml
receivers:
  hostmetrics:
    root_path: /hostfs
    collection_interval: 30s
    scrapers:
      cpu:
      memory:
      load:
      disk:
      filesystem:
      network:
      paging:

  docker_stats:
    endpoint: tcp://docker-socket-proxy:2375
    collection_interval: 30s

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 200
    spike_limit_mib: 40
  resourcedetection:
    detectors: [env, system]
    system:
      hostname_sources: [os]
  batch:
    timeout: 10s

exporters:
  prometheusremotewrite:
    endpoint: ${env:METRICS_REMOTE_WRITE_URL}
    resource_to_telemetry_conversion:
      enabled: true
    retry_on_failure:
      enabled: true
    sending_queue:
      enabled: true
      storage: file_storage

extensions:
  health_check:
    endpoint: 0.0.0.0:13133
  file_storage:
    directory: /var/lib/otelcol/storage

service:
  extensions: [health_check, file_storage]
  pipelines:
    metrics:
      receivers: [hostmetrics, docker_stats]
      processors: [memory_limiter, resourcedetection, batch]
      exporters: [prometheusremotewrite]
```

If Task 1 Step 6 required `api_version`, add it under `docker_stats` now. If
Task 1 Step 6 concluded `docker_stats` cannot work over `tcp://`, remove the
receiver from both the `receivers:` block and the pipeline, drop the
`docker-socket-proxy` service from Step 4, and delete the `have_metric
container_` line from Step 1.

- [ ] **Step 4: Add both services**

Under `volumes:` add `otelstate:`. Then:

```yaml
  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy:latest
    restart: unless-stopped
    logging: *logging
    mem_limit: 64m
    networks: [observability]
    environment:
      CONTAINERS: 1
      VERSION: 1
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro

  otel-collector:
    image: otel/opentelemetry-collector-contrib:latest
    restart: unless-stopped
    logging: *logging
    mem_limit: 300m
    # The image defaults to UID 10001, which can neither read
    # /var/lib/docker/containers (0700 root) nor write the root-owned
    # otelstate volume. Root inside the container; every mount except the
    # state volume stays read-only.
    user: "0"
    # Bridges both networks: apps push OTLP over shared-infra; the backends
    # and the socket proxy are reachable only over observability.
    networks: [default, observability]
    depends_on:
      - victoriametrics
      - docker-socket-proxy
    environment:
      METRICS_REMOTE_WRITE_URL: ${METRICS_REMOTE_WRITE_URL}
    volumes:
      - ./otel/collector.yaml:/etc/otelcol-contrib/config.yaml:ro
      - otelstate:/var/lib/otelcol
      - /:/hostfs:ro
```

The collector publishes no host port and has no compose healthcheck: the image
is built from scratch, with no shell or wget for a healthcheck to exec.
Liveness is asserted by the smoke test against `:13133` instead.

- [ ] **Step 5: Bring it up and confirm the checks pass**

```bash
docker compose up -d docker-socket-proxy otel-collector
sleep 60          # one hostmetrics interval plus remote-write flush
./scripts/observability-smoke-test.sh
```

Expected: all four checks `ok`.

If the collector restarts in a loop, read `docker compose logs otel-collector` —
a bad config makes it exit immediately with the offending key named.

- [ ] **Step 6: Commit**

```bash
git add otel/collector.yaml docker-compose.yml scripts/observability-smoke-test.sh
git commit -m "feat(observability): collect host and container metrics via otel collector

Docker is reached through tecnativa/docker-socket-proxy rather than a
mounted socket: a :ro socket mount makes only the file read-only, not the
API behind it, which would let a compromised collector create privileged
containers and escape to the host."
```

Record the Task 1 findings in this commit message if `docker_stats` needed an
`api_version` pin or had to be dropped.

---

### Task 5: Redis metrics

**Files:**
- Modify: `otel/collector.yaml`
- Modify: `docker-compose.yml` (`otel-collector` environment)
- Modify: `scripts/observability-smoke-test.sh`

**Interfaces:**
- Consumes: the `metrics` pipeline from Task 4; `REDIS_PASSWORD` from the existing `.env`.
- Produces: `redis_*` series in VictoriaMetrics.

- [ ] **Step 1: Write the failing check**

Add below the existing `have_metric` calls:

```bash
have_metric redis_
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `./scripts/observability-smoke-test.sh`
Expected: `FAIL - metrics present: redis_*`

- [ ] **Step 3: Add the receiver**

Under `receivers:` in `otel/collector.yaml`:

```yaml
  redis:
    endpoint: redis:6379
    password: ${env:REDIS_PASSWORD}
    collection_interval: 30s
```

Add `redis` to the `metrics` pipeline receiver list:

```yaml
      receivers: [hostmetrics, docker_stats, redis]
```

The receiver issues `INFO`. It authenticates as the `default` user, which
`redis/entrypoint.sh` grants `+@all`, so no ACL change is needed.

- [ ] **Step 4: Pass the password into the container**

In the `otel-collector` service `environment:` block:

```yaml
      REDIS_PASSWORD: ${REDIS_PASSWORD}
```

- [ ] **Step 5: Restart and confirm the check passes**

```bash
docker compose up -d otel-collector
sleep 60
./scripts/observability-smoke-test.sh
```

Expected: `ok   - metrics present: redis_*`

- [ ] **Step 6: Commit**

```bash
git add otel/collector.yaml docker-compose.yml scripts/observability-smoke-test.sh
git commit -m "feat(observability): collect redis metrics"
```

---

### Task 6: PostgreSQL metrics and the monitoring role

`postgres/init/01-create-apps.sh` runs only on an empty data volume, so on a
live stack the monitoring role is created by hand. It also runs `REVOKE CONNECT
ON DATABASE <app> FROM PUBLIC`, so the role needs an explicit grant per
database or it silently sees nothing.

**Files:**
- Create: `scripts/setup-monitoring-db.sh`
- Modify: `otel/collector.yaml`
- Modify: `docker-compose.yml` (`otel-collector` environment)
- Modify: `.env.example`
- Modify: `scripts/observability-smoke-test.sh`

**Interfaces:**
- Consumes: the `metrics` pipeline from Task 4.
- Produces:
  - PostgreSQL role `otel_monitor` with `pg_monitor` and `CONNECT` on every app database
  - database `grafana` owned by role `grafana` — consumed by Task 10
  - `.env` keys `OTEL_PG_PASSWORD`, `GRAFANA_DB_PASSWORD`
  - `postgresql_*` series in VictoriaMetrics

- [ ] **Step 1: Write the failing check**

```bash
have_metric postgresql_
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `./scripts/observability-smoke-test.sh`
Expected: `FAIL - metrics present: postgresql_*`

- [ ] **Step 3: Add the two keys to `.env.example` and `.env`**

```
# Password for the read-only PostgreSQL role the collector uses.
OTEL_PG_PASSWORD=
# Password for the database Grafana stores its own state in.
GRAFANA_DB_PASSWORD=
```

Generate values with `openssl rand -base64 24` and put them in `.env`.

- [ ] **Step 4: Write `scripts/setup-monitoring-db.sh`**

```bash
#!/usr/bin/env bash
# Creates the read-only role the collector uses and the database Grafana
# stores its state in. Idempotent: safe to re-run after adding an app.
#
# The init script in postgres/init/ only runs on an empty data volume, so on a
# running stack this is how those objects get created.
set -euo pipefail

cd "$(dirname "$0")/.."
if [ ! -f .env ]; then echo "ERROR: .env not found"; exit 1; fi
set -a; . ./.env; set +a

APPS="petag jbc photoboxtyb postyb"

psql() { docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" postgres \
           psql -v ON_ERROR_STOP=1 -U postgres "$@"; }

# ── collector's read-only role ────────────────────────────
psql -d postgres <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'otel_monitor') THEN
    CREATE ROLE otel_monitor LOGIN PASSWORD '${OTEL_PG_PASSWORD}';
  ELSE
    ALTER ROLE otel_monitor PASSWORD '${OTEL_PG_PASSWORD}';
  END IF;
END \$\$;
GRANT pg_monitor TO otel_monitor;
SQL
echo "postgres: role 'otel_monitor' ready"

# ── grafana's own database ────────────────────────────────
psql -d postgres <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'grafana') THEN
    CREATE ROLE grafana LOGIN PASSWORD '${GRAFANA_DB_PASSWORD}';
  ELSE
    ALTER ROLE grafana PASSWORD '${GRAFANA_DB_PASSWORD}';
  END IF;
END \$\$;
SQL
if ! psql -tAc "SELECT 1 FROM pg_database WHERE datname='grafana'" | grep -q 1; then
  psql -d postgres -c "CREATE DATABASE grafana OWNER grafana;"
  psql -d postgres -c "REVOKE CONNECT ON DATABASE grafana FROM PUBLIC;"
  psql -d postgres -c "GRANT CONNECT ON DATABASE grafana TO grafana;"
fi
echo "postgres: database 'grafana' ready"

# ── CONNECT grants: required, because init revokes it from PUBLIC ──
for db in $APPS grafana; do
  psql -d postgres -c "GRANT CONNECT ON DATABASE ${db} TO otel_monitor;"
  echo "postgres: granted CONNECT on '${db}' to otel_monitor"
done
```

Then: `chmod +x scripts/setup-monitoring-db.sh`

- [ ] **Step 5: Run it, twice, to prove it is idempotent**

```bash
./scripts/setup-monitoring-db.sh
./scripts/setup-monitoring-db.sh
```

Expected: identical output both times, exit code 0, no error on the second run.

- [ ] **Step 6: Add the receiver**

Under `receivers:` in `otel/collector.yaml`:

```yaml
  postgresql:
    endpoint: postgres:5432
    transport: tcp
    username: otel_monitor
    password: ${env:OTEL_PG_PASSWORD}
    collection_interval: 30s
    tls:
      insecure: true
```

Add `postgresql` to the `metrics` pipeline receiver list:

```yaml
      receivers: [hostmetrics, docker_stats, redis, postgresql]
```

In the `otel-collector` service `environment:` block:

```yaml
      OTEL_PG_PASSWORD: ${OTEL_PG_PASSWORD}
```

- [ ] **Step 7: Restart and confirm the check passes**

```bash
docker compose up -d otel-collector
sleep 60
./scripts/observability-smoke-test.sh
```

Expected: `ok   - metrics present: postgresql_*`

If the collector logs `permission denied for database`, a `GRANT CONNECT` is
missing — re-run `scripts/setup-monitoring-db.sh`.

- [ ] **Step 8: Commit**

```bash
git add scripts/setup-monitoring-db.sh otel/collector.yaml docker-compose.yml \
        .env.example scripts/observability-smoke-test.sh
git commit -m "feat(observability): collect postgres metrics via otel_monitor role

The init script only runs on an empty data volume, so setup-monitoring-db.sh
creates the role on a live stack. CONNECT is revoked from PUBLIC per database,
so otel_monitor needs an explicit grant on each one or it sees nothing."
```

---

### Task 7: MinIO metrics

MinIO exposes a Prometheus endpoint of its own. It is scraped rather than
received.

**Files:**
- Modify: `docker-compose.yml` (`minio` environment; `otel-collector` has no new env)
- Modify: `otel/collector.yaml`
- Modify: `scripts/observability-smoke-test.sh`

**Interfaces:**
- Consumes: the `metrics` pipeline from Task 4.
- Produces: `minio_*` series in VictoriaMetrics.

- [ ] **Step 1: Write the failing check**

```bash
have_metric minio_
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `./scripts/observability-smoke-test.sh`
Expected: `FAIL - metrics present: minio_*`

- [ ] **Step 3: Open the MinIO metrics endpoint**

In the existing `minio` service `environment:` block:

```yaml
      MINIO_PROMETHEUS_AUTH_TYPE: public
```

Without this the endpoint demands a JWT. This is safe here: MinIO publishes only
on `127.0.0.1` and is otherwise reachable only from `shared-infra`.

- [ ] **Step 4: Add the scrape**

Under `receivers:` in `otel/collector.yaml`:

```yaml
  prometheus:
    config:
      scrape_configs:
        - job_name: minio
          scrape_interval: 30s
          metrics_path: /minio/v2/metrics/cluster
          static_configs:
            - targets: [minio:9000]
```

Add `prometheus` to the `metrics` pipeline receiver list:

```yaml
      receivers: [hostmetrics, docker_stats, redis, postgresql, prometheus]
```

- [ ] **Step 5: Recreate MinIO and the collector, then confirm**

```bash
docker compose up -d minio otel-collector
sleep 60
./scripts/observability-smoke-test.sh
```

Expected: `ok   - metrics present: minio_*`

This recreates the MinIO container. The `miniodata` volume is untouched.

Sanity check if it fails:
`docker run --rm --network shared-infra curlimages/curl:latest -sf http://minio:9000/minio/v2/metrics/cluster | head`

- [ ] **Step 6: Commit**

```bash
git add docker-compose.yml otel/collector.yaml scripts/observability-smoke-test.sh
git commit -m "feat(observability): scrape minio cluster metrics"
```

---

### Task 8: VictoriaLogs and container logs

The zero-touch half of the design: logs from every container, including
applications that have not been modified at all.

**Verify this task on the Linux VPS.**

**Files:**
- Modify: `docker-compose.yml` (add `victorialogs` service, add `vlogsdata` volume, `otel-collector` env)
- Modify: `otel/collector.yaml`
- Modify: `.env.example`
- Modify: `scripts/observability-smoke-test.sh`

**Interfaces:**
- Consumes: the `file_storage` extension from Task 4.
- Produces:
  - service `victorialogs`, reachable as `http://victorialogs:9428`
  - `.env` keys `LOGS_OTLP_ENDPOINT`, `LOGS_RETENTION`, `LOGS_MAX_DISK`
  - the `logs` pipeline, extended by Task 9

- [ ] **Step 1: Write the failing checks**

```bash
echo "== VictoriaLogs =="
if netcurl -f http://victorialogs:9428/health >/dev/null; then
  ok "victorialogs is healthy"
else
  bad "victorialogs is healthy"
fi

# At least one log record ingested in the last 5 minutes.
if netcurl -X POST http://victorialogs:9428/select/logsql/query \
     --data-urlencode 'query=_time:5m' --data-urlencode 'limit=1' \
     | grep -q '_msg'; then
  ok "container logs are being ingested"
else
  bad "container logs are being ingested"
fi
```

- [ ] **Step 2: Run it to confirm both fail**

Run: `./scripts/observability-smoke-test.sh`
Expected: `FAIL - victorialogs is healthy`, `FAIL - container logs are being ingested`

- [ ] **Step 3: Add the keys to `.env.example` and `.env`**

```
LOGS_OTLP_ENDPOINT=http://victorialogs:9428/insert/opentelemetry/v1/logs
LOGS_RETENTION=14d
# Hard disk ceiling for logs. Log volume cannot be predicted, and this is
# what stops the disk filling.
LOGS_MAX_DISK=10GB
```

- [ ] **Step 4: Add the service**

Under `volumes:` add `vlogsdata:`. Then:

```yaml
  victorialogs:
    image: victoriametrics/victoria-logs:latest
    restart: unless-stopped
    logging: *logging
    mem_limit: 384m
    networks: [observability]
    command:
      - "-storageDataPath=/victoria-logs-data"
      - "-retentionPeriod=${LOGS_RETENTION:-14d}"
      - "-retention.maxDiskSpaceUsageBytes=${LOGS_MAX_DISK:-10GB}"
      - "-httpListenAddr=:9428"
    volumes:
      - vlogsdata:/victoria-logs-data
    ports:
      - "127.0.0.1:9428:9428"
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:9428/health"]
      interval: 30s
      timeout: 5s
      retries: 3
```

- [ ] **Step 5: Add the filelog receiver, exporter and pipeline**

Under `receivers:` in `otel/collector.yaml`:

```yaml
  filelog:
    include: [/var/lib/docker/containers/*/*-json.log]
    start_at: end
    storage: file_storage
    operators:
      - type: container
```

`storage: file_storage` is what makes read positions survive a collector
restart. Without it every restart either replays or skips.

Under `exporters:`:

```yaml
  otlphttp/logs:
    logs_endpoint: ${env:LOGS_OTLP_ENDPOINT}
    retry_on_failure:
      enabled: true
    sending_queue:
      enabled: true
      storage: file_storage
```

Under `service.pipelines:`:

```yaml
    logs:
      receivers: [filelog]
      processors: [memory_limiter, resourcedetection, batch]
      exporters: [otlphttp/logs]
```

Add the mount and env to `otel-collector`:

```yaml
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
```

```yaml
      LOGS_OTLP_ENDPOINT: ${LOGS_OTLP_ENDPOINT}
```

Add `victorialogs` to the collector's `depends_on`.

- [ ] **Step 6: Bring it up and confirm both checks pass**

```bash
docker compose up -d victorialogs otel-collector
docker run --rm alpine:3.20 echo "smoke-test-marker"
sleep 45
./scripts/observability-smoke-test.sh
```

Expected: both checks `ok`.

`start_at: end` means only lines written after the collector starts are read, so
the marker line above is what the second check finds.

The spec asks for records from at least three distinct containers; this check
asserts ingestion only. Counting distinct containers requires the attribute key
that Task 1 Step 7 discovers, which is not known when this script is written.
Step 7 below covers the identity half by inspection.

- [ ] **Step 7: Confirm records carry a container identity**

```bash
docker run --rm --network observability curlimages/curl:latest \
  -s -X POST http://victorialogs:9428/select/logsql/query \
  --data-urlencode 'query=_time:5m' --data-urlencode 'limit=3'
```

Expected: records including the attribute key recorded in Task 1 Step 7.

If no container identity is present, add the fallback recorded in Task 1 — a
`transform` processor deriving it from `log.file.path`, which contains the
container ID:

```yaml
  transform/container_id:
    log_statements:
      - context: log
        statements:
          - merge_maps(attributes,
              ExtractPatterns(attributes["log.file.path"],
                "containers/(?P<container_id>[0-9a-f]{12})"),
              "insert")
```

Place it after `resourcedetection` in the `logs` pipeline only. This matches the
ID out of the path rather than assuming a byte offset, so it is unaffected by
where Docker's root directory sits.

- [ ] **Step 8: Commit**

```bash
git add docker-compose.yml otel/collector.yaml .env.example scripts/observability-smoke-test.sh
git commit -m "feat(observability): ingest all container logs into victorialogs

filelog read positions are checkpointed through the file_storage extension so
a collector restart neither replays nor skips lines."
```

---

### Task 9: The OTLP endpoint, and proof it works

Everything so far observes services from the outside. This adds the endpoint
applications push to, and proves it end-to-end before any app repo is touched.

**Files:**
- Modify: `otel/collector.yaml`
- Modify: `scripts/observability-smoke-test.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: the `metrics` pipeline from Task 4, the `logs` pipeline from Task 8.
- Produces: `otel-collector:4317` (gRPC) and `otel-collector:4318` (HTTP), in-network only.

- [ ] **Step 1: Write the failing check**

Append before the final `echo`:

```bash
echo "== OTLP round-trip =="
# POSTs run from shared-infra — the same network path an app uses.
appcurl() { docker run --rm --network shared-infra curlimages/curl:latest -s "$@"; }

appcurl -X POST http://otel-collector:4318/v1/logs \
  -H 'Content-Type: application/json' \
  -d '{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"smoketest"}}]},"scopeLogs":[{"logRecords":[{"body":{"stringValue":"otlp-roundtrip-probe"}}]}]}]}' \
  >/dev/null

now="$(date +%s%N)"
appcurl -X POST http://otel-collector:4318/v1/metrics \
  -H 'Content-Type: application/json' \
  -d "{\"resourceMetrics\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"smoketest\"}}]},\"scopeMetrics\":[{\"metrics\":[{\"name\":\"otlp.roundtrip.probe\",\"gauge\":{\"dataPoints\":[{\"asInt\":\"1\",\"timeUnixNano\":\"${now}\"}]}}]}]}]}" \
  >/dev/null
sleep 20
if netcurl -X POST http://victorialogs:9428/select/logsql/query \
     --data-urlencode 'query=otlp-roundtrip-probe' --data-urlencode 'limit=1' \
     | grep -q 'otlp-roundtrip-probe'; then
  ok "OTLP log pushed by an app reaches victorialogs"
else
  bad "OTLP log pushed by an app reaches victorialogs"
fi
have_metric otlp_roundtrip_probe
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `./scripts/observability-smoke-test.sh`
Expected: `FAIL - OTLP log pushed by an app reaches victorialogs` and
`FAIL - metrics present: otlp_roundtrip_probe*`. The collector is not
listening on 4318 yet, so both POSTs are refused.

- [ ] **Step 3: Add the receiver**

Under `receivers:` in `otel/collector.yaml`:

```yaml
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
```

Add `otlp` to **both** pipelines:

```yaml
    metrics:
      receivers: [otlp, hostmetrics, docker_stats, redis, postgresql, prometheus]
    logs:
      receivers: [otlp, filelog]
```

No port mapping is added. Applications reach the collector by service name on
`shared-infra`; nothing is exposed to the host.

- [ ] **Step 4: Restart and confirm the check passes**

```bash
docker compose up -d otel-collector
sleep 15
./scripts/observability-smoke-test.sh
```

Expected: `ok   - OTLP log pushed by an app reaches victorialogs` and
`ok   - metrics present: otlp_roundtrip_probe*`

- [ ] **Step 5: Document how an app opts in**

Add to `README.md`, after the "How apps connect" table:

```markdown
## Observability

Any app joined to `shared-infra` is already observed — its container logs,
CPU, memory and network are collected with no code change, and the shared
Postgres, Redis and MinIO it uses are monitored centrally.

To also emit your own metrics and structured logs, install an OpenTelemetry
SDK and set:

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318
OTEL_SERVICE_NAME=<app>
```

Grafana is on `127.0.0.1:3001`, behind whichever subdomain your nginx serves
it on. Verify the stack with `./scripts/observability-smoke-test.sh`.
```

- [ ] **Step 6: Commit**

```bash
git add otel/collector.yaml scripts/observability-smoke-test.sh README.md
git commit -m "feat(observability): expose OTLP endpoint for opt-in app telemetry"
```

---

### Task 10: Grafana

**Files:**
- Create: `grafana/provisioning/datasources/datasources.yml`
- Modify: `docker-compose.yml` (add `grafana` service)
- Modify: `.env.example`
- Modify: `scripts/observability-smoke-test.sh`

**Interfaces:**
- Consumes: the `grafana` database and role from Task 6; `victoriametrics` from Task 3; `victorialogs` from Task 8.
- Produces: Grafana on `127.0.0.1:${GRAFANA_PORT}` with both datasources provisioned.

- [ ] **Step 1: Write the failing checks**

```bash
echo "== Grafana =="
if curl -sf "http://127.0.0.1:${GRAFANA_PORT:-3001}/api/health" | grep -q '"database": *"ok"'; then
  ok "grafana is healthy"
else
  bad "grafana is healthy"
fi

ds=$(curl -sf -u "admin:${GRAFANA_ADMIN_PASSWORD:-}" \
       "http://127.0.0.1:${GRAFANA_PORT:-3001}/api/datasources" || echo '')
echo "$ds" | grep -q 'VictoriaMetrics' \
  && ok "VictoriaMetrics datasource provisioned" \
  || bad "VictoriaMetrics datasource provisioned"
echo "$ds" | grep -q 'VictoriaLogs' \
  && ok "VictoriaLogs datasource provisioned" \
  || bad "VictoriaLogs datasource provisioned"
```

These use plain `curl` against `127.0.0.1`, not `netcurl` — Grafana is checked
on the published host port, the same way nginx will reach it.

- [ ] **Step 2: Run it to confirm all three fail**

Run: `./scripts/observability-smoke-test.sh`
Expected: three `FAIL` lines under `== Grafana ==`.

- [ ] **Step 3: Add the keys to `.env.example` and `.env`**

```
# Port bound on 127.0.0.1 for the new Grafana. The server's existing
# Grafana keeps 3000; this one is separate and does not touch it.
GRAFANA_PORT=3001
GRAFANA_ROOT_URL=https://infra.example.com
GRAFANA_ADMIN_PASSWORD=
```

Set a real password in `.env` with `openssl rand -base64 24`, and set
`GRAFANA_ROOT_URL` to the subdomain you will serve it from.

- [ ] **Step 4: Write `grafana/provisioning/datasources/datasources.yml`**

```yaml
apiVersion: 1

datasources:
  - name: VictoriaMetrics
    type: prometheus
    access: proxy
    url: http://victoriametrics:8428
    isDefault: true
    jsonData:
      timeInterval: 30s

  - name: VictoriaLogs
    type: victoriametrics-logs-datasource
    access: proxy
    url: http://victorialogs:9428
```

Only datasources are provisioned. No dashboard provider is configured, so
dashboards authored in the UI stay editable and are never overwritten.

- [ ] **Step 5: Add the service**

```yaml
  grafana:
    image: grafana/grafana:latest
    restart: unless-stopped
    logging: *logging
    mem_limit: 256m
    # default for postgres and the plugin download; observability for the backends.
    networks: [default, observability]
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      GF_DATABASE_TYPE: postgres
      GF_DATABASE_HOST: postgres:5432
      GF_DATABASE_NAME: grafana
      GF_DATABASE_USER: grafana
      GF_DATABASE_PASSWORD: ${GRAFANA_DB_PASSWORD}
      GF_DATABASE_SSL_MODE: disable
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD:?set in .env}
      GF_SERVER_ROOT_URL: ${GRAFANA_ROOT_URL}
      GF_USERS_ALLOW_SIGN_UP: "false"
      GF_AUTH_ANONYMOUS_ENABLED: "false"
      GF_INSTALL_PLUGINS: victoriametrics-logs-datasource
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
    ports:
      - "127.0.0.1:${GRAFANA_PORT:-3001}:3000"
```

No Grafana volume: all state lives in the `grafana` PostgreSQL database, which
`backup.sh` picks up in Task 11. Plugin installation needs outbound internet on
first start.

- [ ] **Step 6: Bring it up and confirm all three checks pass**

```bash
docker compose up -d grafana
sleep 30
./scripts/observability-smoke-test.sh
```

Expected: all three `ok`.

If Grafana exits with a database error, Task 6 has not been run against this
stack — run `./scripts/setup-monitoring-db.sh`.

- [ ] **Step 7: Confirm a query actually returns data**

Open `http://127.0.0.1:${GRAFANA_PORT}` (or tunnel with
`ssh -L 3001:127.0.0.1:3001 <vps>`), log in as `admin`, and in Explore run
`system_cpu_time_seconds_total` against VictoriaMetrics and `_time:5m` against
VictoriaLogs. Both must return rows.

- [ ] **Step 8: Commit**

```bash
git add grafana/provisioning/datasources/datasources.yml docker-compose.yml \
        .env.example scripts/observability-smoke-test.sh
git commit -m "feat(observability): add grafana with provisioned datasources

State lives in the shared postgres so hand-authored dashboards are covered by
backup.sh. Only datasources are provisioned; dashboards stay editable in the UI.
Binds 127.0.0.1:3001, leaving the server's existing Grafana on 3000 untouched."
```

---

### Task 11: Back up Grafana, pin images, document

The last loose ends: Grafana's dashboards are an asset and are not yet backed
up, and every new service is running a floating `latest` tag.

**Files:**
- Modify: `backup/backup.sh:9`
- Modify: `docker-compose.yml` (pin the five new images)
- Modify: `README.md`

**Interfaces:**
- Consumes: the `grafana` database from Task 6.
- Produces: nothing consumed downstream.

- [ ] **Step 1: Write the failing check**

Append to `scripts/observability-smoke-test.sh`:

```bash
echo "== Backup coverage =="
grep -q 'grafana' backup/backup.sh \
  && ok "backup.sh dumps the grafana database" \
  || bad "backup.sh dumps the grafana database"
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `./scripts/observability-smoke-test.sh`
Expected: `FAIL - backup.sh dumps the grafana database`

- [ ] **Step 3: Add `grafana` to the backup list**

In `backup/backup.sh`, change:

```sh
APPS="petag jbc photoboxtyb postyb"
```

to:

```sh
# grafana holds hand-authored dashboards; it is not an app but must be dumped.
APPS="petag jbc photoboxtyb postyb grafana"
```

- [ ] **Step 4: Prove the dump actually works**

```bash
docker compose exec backup /usr/local/bin/backup.sh
ls -la "backups/$(date +%F)/grafana.sql.gz"
gunzip -c "backups/$(date +%F)/grafana.sql.gz" | head -20
```

Expected: a non-empty file whose first lines are a PostgreSQL dump header.

If `pg_dump` reports a permission error, the superuser is used for dumps and
already has access — check instead that Task 6 created the database.

- [ ] **Step 5: Resolve and pin the five new images**

Floating `latest` tags make the stack non-reproducible and let an upstream
change break a working box. Full digest pinning across every service is
sub-project 2, but recording these five now costs nothing.

```bash
for img in \
  victoriametrics/victoria-metrics:latest \
  victoriametrics/victoria-logs:latest \
  otel/opentelemetry-collector-contrib:latest \
  tecnativa/docker-socket-proxy:latest \
  grafana/grafana:latest
do
  docker pull -q "$img" >/dev/null
  docker inspect --format='{{index .RepoDigests 0}}' "$img"
done
```

Replace each `image:` line in `docker-compose.yml` with the printed
`repo@sha256:...` value.

- [ ] **Step 6: Confirm the pinned stack still comes up clean**

```bash
docker compose config >/dev/null && echo VALID
docker compose up -d
sleep 60
./scripts/observability-smoke-test.sh
```

Expected: `VALID`, then every check `ok`.

- [ ] **Step 7: Document operating the stack**

Add to `README.md`, after the `## Backups` section:

```markdown
## Observability stack

| Service | Bound on | Purpose |
|---|---|---|
| `otel-collector` | in-network only | collects everything; OTLP on `:4317`/`:4318` |
| `victoriametrics` | `127.0.0.1:8428` | metrics, 30-day retention |
| `victorialogs` | `127.0.0.1:9428` | logs, 14 days, capped at 10 GB |
| `grafana` | `127.0.0.1:3001` | dashboards; state in the `grafana` database |
| `docker-socket-proxy` | in-network only | read-only Docker API for container stats |

The backends and the socket proxy live on a separate `observability` network
that apps never join: an app cannot read other apps' logs, write bogus
metrics, or reach the Docker API proxy (whose container-inspect responses
include every service's environment variables). Apps see exactly one
observability endpoint: `otel-collector:4318` on `shared-infra`.

On a fresh server, after `docker compose up -d`:

```sh
./scripts/setup-monitoring-db.sh        # creates otel_monitor + the grafana database
./scripts/observability-smoke-test.sh   # verifies collection end to end
```

Serve Grafana by pointing an nginx server block at `127.0.0.1:3001`. This repo
does not manage nginx.

**Adding an app:** grant the collector access to its database, or its metrics
will be missing while everything else looks fine:

```sh
docker compose exec postgres psql -U postgres -c \
  "GRANT CONNECT ON DATABASE app5 TO otel_monitor;"
```

**To use an existing Prometheus instead of VictoriaMetrics:** point
`METRICS_REMOTE_WRITE_URL` at it and stop the `victoriametrics` service. The
collector needs no other change.
```

- [ ] **Step 8: Commit**

```bash
git add backup/backup.sh docker-compose.yml README.md scripts/observability-smoke-test.sh
git commit -m "feat(observability): back up grafana state, pin images, document stack"
```

---

## Done when

- `./scripts/observability-smoke-test.sh` passes every check on the VPS.
- `./scripts/smoke-test.sh` still passes — the existing isolation guarantees are unchanged.
- Grafana serves the new subdomain and both datasources return data in Explore.
- `backups/<today>/grafana.sql.gz` exists and is non-empty.
- `git log --oneline main..observability` shows one commit per task (Task 1, the preflight, commits nothing).

## Deliberately not done here

Traces, alert rules, dashboards-as-code, nginx telemetry, offsite backups,
PgBouncer, and per-app network segmentation. The first three are follow-ups to
this spec; the rest belong to sub-projects 2 and 3.

## Carried into sub-project 3

`add-app.sh` must issue `GRANT CONNECT ON DATABASE <newapp> TO otel_monitor`.
Without it a new app's database metrics are silently missing while every other
signal looks correct.
