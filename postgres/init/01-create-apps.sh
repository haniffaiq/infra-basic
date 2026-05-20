#!/usr/bin/env bash
# Runs once, only on a fresh (empty) Postgres data volume.
# Creates one database + one owner user per app, and blocks cross-app access
# by revoking the default PUBLIC CONNECT privilege.
set -euo pipefail

create_app() {
  local app="$1" pw="$2"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
    CREATE USER ${app} WITH PASSWORD '${pw}';
    CREATE DATABASE ${app} OWNER ${app};
    REVOKE CONNECT ON DATABASE ${app} FROM PUBLIC;
    GRANT CONNECT ON DATABASE ${app} TO ${app};
EOSQL
  echo "postgres: created app '${app}'"
}

create_app petag       "$PETAG_DB_PASSWORD"
create_app jbc         "$JBC_DB_PASSWORD"
create_app photoboxtyb "$PHOTOBOXTYB_DB_PASSWORD"
create_app postyb      "$POSTYB_DB_PASSWORD"
