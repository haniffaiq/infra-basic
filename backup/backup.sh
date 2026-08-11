#!/bin/sh
# Dumps all app Postgres databases, snapshots Redis, mirrors all MinIO buckets
# into ./backups/YYYY-MM-DD/, then prunes backups older than the retention window.
set -eu

APPS="${BACKUP_APPS:-petag jbc photoboxtyb postyb}"
DATE="$(date +%F)"
OUT="/backups/${DATE}"
TMP="${OUT}/.tmp"
POSTGRES_HOST="${POSTGRES_HOST:-postgres}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://minio:9000}"

log() { echo "$(date '+%F %T') $*"; }
fail() { log "ERROR: $*"; exit 1; }

mkdir -p "$OUT" "$TMP"
log "=== backup ${DATE} start ==="
log "endpoints: postgres=${POSTGRES_HOST}:${POSTGRES_PORT} redis=${REDIS_HOST}:${REDIS_PORT} minio=${MINIO_ENDPOINT}"

# ── Postgres ──────────────────────────────────────────────
export PGPASSWORD="$POSTGRES_PASSWORD"
pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U postgres >/dev/null 2>&1 \
  || fail "postgres is not reachable at ${POSTGRES_HOST}:${POSTGRES_PORT}"

for app in $APPS; do
  sql_tmp="${TMP}/${app}.sql"
  gz_tmp="${TMP}/${app}.sql.gz"
  final="${OUT}/${app}.sql.gz"
  rm -f "$sql_tmp" "$gz_tmp"

  table_count="$(psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U postgres -d "$app" -v ON_ERROR_STOP=1 -Atc "select count(*) from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE';")" \
    || fail "could not count public tables for ${app}"
  log "postgres: dumping ${app} live_public_tables=${table_count}"
  pg_dump -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U postgres -d "$app" -f "$sql_tmp" \
    || fail "pg_dump failed for ${app}"
  [ -s "$sql_tmp" ] || fail "pg_dump produced an empty dump for ${app}"
  if [ "$table_count" -gt 0 ]; then
    grep -q '^CREATE TABLE\|^COPY \|^CREATE SCHEMA\|^CREATE EXTENSION' "$sql_tmp" \
      || fail "pg_dump for non-empty ${app} did not contain schema/data statements"
  fi
  gzip -c "$sql_tmp" > "$gz_tmp" || fail "gzip failed for ${app}"
  gzip -t "$gz_tmp" || fail "gzip validation failed for ${app}"
  mv "$gz_tmp" "$final"
  rm -f "$sql_tmp"
  log "postgres: dumped ${app} live_public_tables=${table_count} bytes=$(wc -c < "$final")"
done

# ── Redis ─────────────────────────────────────────────────
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -a "$REDIS_PASSWORD" --no-auth-warning ping 2>/dev/null | grep -q '^PONG$' \
  || fail "redis is not reachable at ${REDIS_HOST}:${REDIS_PORT}"
redis_tmp="${TMP}/redis-dump.rdb"
redis_final="${OUT}/redis-dump.rdb"
rm -f "$redis_tmp"
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -a "$REDIS_PASSWORD" --no-auth-warning --rdb "$redis_tmp" >/dev/null \
  || fail "redis RDB snapshot failed"
[ -s "$redis_tmp" ] || fail "redis RDB snapshot is empty"
mv "$redis_tmp" "$redis_final"
log "redis: snapshot saved bytes=$(wc -c < "$redis_final")"

# ── MinIO ─────────────────────────────────────────────────
mc alias set local "$MINIO_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null \
  || fail "minio alias failed for ${MINIO_ENDPOINT}"
mc ls local >/dev/null || fail "minio is not reachable at ${MINIO_ENDPOINT}"

for app in $APPS; do
  dest="${OUT}/minio/${app}"
  tmp_dest="${TMP}/minio-${app}"
  rm -rf "$tmp_dest"
  mkdir -p "$tmp_dest"

  if ! mc ls "local/${app}" >/tmp/mc-ls-${app}.txt 2>/tmp/mc-ls-${app}.err; then
    fail "minio bucket ${app} is not accessible: $(cat /tmp/mc-ls-${app}.err)"
  fi

  if ! mc mirror --overwrite --remove --quiet "local/${app}" "$tmp_dest" >/tmp/mc-mirror-${app}.out 2>/tmp/mc-mirror-${app}.err; then
    fail "minio mirror failed for ${app}: $(cat /tmp/mc-mirror-${app}.err)"
  fi
  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  mv "$tmp_dest" "$dest"
  objects="$(find "$dest" -type f | wc -l | tr -d ' ')"
  log "minio: mirrored ${app} objects=${objects}"
done

rm -rf "$TMP"

# ── Prune ─────────────────────────────────────────────────
find /backups -mindepth 1 -maxdepth 1 -type d -name '20*' \
  -mtime "+${BACKUP_RETENTION_DAYS}" -exec rm -rf {} +
log "=== backup ${DATE} complete ==="
