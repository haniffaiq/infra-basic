#!/usr/bin/env bash
# Creates the read-only role the collector uses and the database Grafana
# stores its state in. Idempotent: safe to re-run.
#
# postgres/init/01-create-apps.sh only runs on an empty data volume, so on a
# running stack this script is how those objects get created.
# Run after `docker compose up -d` has settled. Run from anywhere.
set -euo pipefail

cd "$(dirname "$0")/.."
if [ ! -f .env ]; then echo "ERROR: .env not found"; exit 1; fi
set -a; . ./.env; set +a

# Hardcoded, like the rest of the repo. Re-run this script after adding an app,
# or the collector will silently report no metrics for the new database.
APPS="petag jbc photoboxtyb postyb"

psql() { docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" postgres \
           psql -v ON_ERROR_STOP=1 -U postgres "$@"; }

# ── collector's read-only role ────────────────────────────
# pg_monitor is the built-in role that grants read access to the statistics
# views the postgresql receiver reads. An existing role keeps its grants and
# just has its password reset, so re-running never fails.
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
echo "postgres: role 'grafana' ready"

# CREATE DATABASE cannot run inside a DO block, so the existence check is done
# here instead. Same isolation pattern the init script uses for app databases.
if ! psql -tAc "SELECT 1 FROM pg_database WHERE datname='grafana'" | grep -q 1; then
  psql -d postgres -c "CREATE DATABASE grafana OWNER grafana;"
  psql -d postgres -c "REVOKE CONNECT ON DATABASE grafana FROM PUBLIC;"
  psql -d postgres -c "GRANT CONNECT ON DATABASE grafana TO grafana;"
fi
echo "postgres: database 'grafana' ready"

# ── CONNECT grants: required, not optional ────────────────
# postgres/init/01-create-apps.sh runs `REVOKE CONNECT ON DATABASE <app> FROM
# PUBLIC`. Without an explicit grant here the collector still connects to the
# server and looks healthy, but silently reports no metrics for that database.
# GRANT is a no-op when the privilege is already held, so this re-runs cleanly.
for db in $APPS grafana; do
  psql -d postgres -c "GRANT CONNECT ON DATABASE ${db} TO otel_monitor;"
  echo "postgres: granted CONNECT on '${db}' to otel_monitor"
done
