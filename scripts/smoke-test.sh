#!/usr/bin/env bash
# Verifies each app can reach its own resources.
# Run after the shared infra compose stack has settled. Run from the repo root.
# Supports Docker Compose and rootless Podman/podman-compose on this host.
# Checks use per-tenant credentials from .env.
set -u

cd "$(dirname "$0")/.."
if [ ! -f .env ]; then echo "ERROR: .env not found"; exit 1; fi
set -a; . ./.env; set +a

APPS="petag photoboxtyb postyb osvyn"
pass=0; fail=0
ok()  { echo "  ok   - $1"; pass=$((pass+1)); }
bad() { echo "  FAIL - $1"; fail=$((fail+1)); }

if command -v docker >/dev/null 2>&1; then
  compose_exec() { docker compose exec -T "$@"; }
  MINIO_ENDPOINT=http://minio:9000
  minio_mc() { docker run --rm --network shared-infra --entrypoint sh minio/mc -c "$1"; }
elif command -v podman-compose >/dev/null 2>&1 && command -v podman >/dev/null 2>&1; then
  compose_exec() { podman-compose exec -T "$@"; }
  # Rootless Podman DNS can be unavailable for one-shot containers on this VM.
  # Execute mc inside the existing MinIO container against localhost instead.
  MINIO_ENDPOINT=http://localhost:9000
  minio_mc() { podman exec infa-basic_minio_1 sh -c "$1"; }
else
  echo "ERROR: need docker compose or podman-compose+podman"; exit 1
fi

val() { eval "printf '%s' \"\${$1}\""; }
upper() { echo "$1" | tr '[:lower:]' '[:upper:]'; }

echo "== Postgres =="
for app in $APPS; do
  pw="$(val "$(upper "$app")_DB_PASSWORD")"
  if compose_exec -e PGPASSWORD="$pw" postgres \
       psql -U "$app" -d "$app" -tAc 'SELECT 1' >/dev/null 2>&1; then
    ok "$app connects to its own database"
  else
    bad "$app connects to its own database"
  fi
done

echo "== Redis =="
for app in $APPS; do
  pw="$(val "$(upper "$app")_REDIS_PASSWORD")"
  if compose_exec redis \
       redis-cli -u "redis://${app}:${pw}@localhost:6379" set "${app}:smoke" 1 >/dev/null 2>&1; then
    ok "$app writes its own ${app}:* keys"
  else
    bad "$app writes its own ${app}:* keys"
  fi
done

echo "== MinIO =="
for app in $APPS; do
  ak="$(val "$(upper "$app")_MINIO_ACCESS_KEY")"
  sk="$(val "$(upper "$app")_MINIO_SECRET_KEY")"
  if minio_mc \
       "mc alias set t $MINIO_ENDPOINT $ak $sk >/dev/null 2>&1 && mc ls t/$app >/dev/null 2>&1"; then
    ok "$app accesses its own bucket"
  else
    bad "$app accesses its own bucket"
  fi
done

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
