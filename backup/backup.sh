#!/bin/sh
# Dumps all 4 Postgres databases, snapshots Redis, mirrors all MinIO buckets
# into ./backups/YYYY-MM-DD/, then prunes backups older than the retention window.
set -eu

APPS="petag jbc photoboxtyb postyb"
DATE="$(date +%F)"
OUT="/backups/${DATE}"
mkdir -p "$OUT"
echo "=== backup ${DATE} $(date +%T) ==="

# ── Postgres ──────────────────────────────────────────────
export PGPASSWORD="$POSTGRES_PASSWORD"
for app in $APPS; do
  pg_dump -h postgres -U postgres -d "$app" | gzip > "${OUT}/${app}.sql.gz"
  echo "postgres: dumped ${app}"
done

# ── Redis ─────────────────────────────────────────────────
redis-cli -h redis -a "$REDIS_PASSWORD" --no-auth-warning --rdb "${OUT}/redis-dump.rdb" >/dev/null
echo "redis: snapshot saved"

# ── MinIO ─────────────────────────────────────────────────
mc alias set local "http://minio:9000" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
for app in $APPS; do
  mc mirror --overwrite --remove --quiet "local/${app}" "${OUT}/minio/${app}"
  echo "minio: mirrored ${app}"
done

# ── Prune ─────────────────────────────────────────────────
find /backups -mindepth 1 -maxdepth 1 -type d -name '20*' \
  -mtime "+${BACKUP_RETENTION_DAYS}" -exec rm -rf {} +
echo "=== backup complete ${DATE} $(date +%T) ==="
