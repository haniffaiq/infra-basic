#!/usr/bin/env bash
# Verifies each app can reach its own resources AND is blocked from others'.
# Run after `docker compose up -d` has settled. Run from the repo root.
set -u

cd "$(dirname "$0")/.."
if [ ! -f .env ]; then echo "ERROR: .env not found"; exit 1; fi
set -a; . ./.env; set +a

APPS="petag jbc photoboxtyb postyb"
pass=0; fail=0
ok()  { echo "  ok   - $1"; pass=$((pass+1)); }
bad() { echo "  FAIL - $1"; fail=$((fail+1)); }

val() { eval "printf '%s' \"\${$1}\""; }
upper() { echo "$1" | tr '[:lower:]' '[:upper:]'; }

echo "== Postgres =="
for app in $APPS; do
  pw="$(val "$(upper "$app")_DB_PASSWORD")"
  if docker compose exec -T -e PGPASSWORD="$pw" postgres \
       psql -U "$app" -d "$app" -tAc 'SELECT 1' >/dev/null 2>&1; then
    ok "$app connects to its own database"
  else
    bad "$app connects to its own database"
  fi
done
petag_pw="$(val PETAG_DB_PASSWORD)"
if docker compose exec -T -e PGPASSWORD="$petag_pw" postgres \
     psql -U petag -d jbc -tAc 'SELECT 1' >/dev/null 2>&1; then
  bad "petag is blocked from the jbc database"
else
  ok "petag is blocked from the jbc database"
fi

echo "== Redis =="
for app in $APPS; do
  pw="$(val "$(upper "$app")_REDIS_PASSWORD")"
  if docker compose exec -T redis \
       redis-cli -u "redis://${app}:${pw}@localhost:6379" set "${app}:smoke" 1 >/dev/null 2>&1; then
    ok "$app writes its own ${app}:* keys"
  else
    bad "$app writes its own ${app}:* keys"
  fi
done
petag_rpw="$(val PETAG_REDIS_PASSWORD)"
if docker compose exec -T redis \
     redis-cli -u "redis://petag:${petag_rpw}@localhost:6379" set "jbc:smoke" 1 2>&1 | grep -q NOPERM; then
  ok "petag is blocked from jbc:* keys"
else
  bad "petag is blocked from jbc:* keys"
fi

echo "== MinIO =="
for app in $APPS; do
  ak="$(val "$(upper "$app")_MINIO_ACCESS_KEY")"
  sk="$(val "$(upper "$app")_MINIO_SECRET_KEY")"
  if docker run --rm --network shared-infra --entrypoint sh minio/mc -c \
       "mc alias set t http://minio:9000 $ak $sk >/dev/null 2>&1 && mc ls t/$app >/dev/null 2>&1"; then
    ok "$app accesses its own bucket"
  else
    bad "$app accesses its own bucket"
  fi
done
petag_ak="$(val PETAG_MINIO_ACCESS_KEY)"
petag_sk="$(val PETAG_MINIO_SECRET_KEY)"
if docker run --rm --network shared-infra --entrypoint sh minio/mc -c \
     "mc alias set t http://minio:9000 $petag_ak $petag_sk >/dev/null 2>&1 && mc ls t/jbc >/dev/null 2>&1"; then
  bad "petag is blocked from the jbc bucket"
else
  ok "petag is blocked from the jbc bucket"
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
