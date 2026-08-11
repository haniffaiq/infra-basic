# Shared infra backup job fix verification - 2026-08-11

## Summary

S4 follow-up `t_3b8f751b` fixed the shared infra backup job after restore verification proved the previous cron outputs were unusable 20-byte gzip files. The backup script now fails visibly on connectivity, `pg_dump`, gzip, Redis, and MinIO mirror failures instead of logging success after failed pipelines.

No application code was changed.

## Root cause

The old backup script used this pattern:

```sh
pg_dump -h postgres -U postgres -d "$app" | gzip > "${OUT}/${app}.sql.gz"
echo "postgres: dumped ${app}"
```

With `set -eu` but without pipeline failure handling, a `pg_dump` DNS failure was masked by successful `gzip`, leaving a valid but empty gzip file and an unconditional success log line.

The live rootless Podman `shared-infra` DNS state was also stale. From the backup container, service names did not reliably resolve/connect during the failed cron runs. During remediation, DNS later resolved but to stale pre-recreate IPs, so the deployed job uses explicit verified service endpoints in `.env` via the new backup endpoint override variables.

## Code changes

Changed files:

- `.env.example`
  - documents optional backup endpoint override variables.
- `docker-compose.yml`
  - passes backup app list and endpoint override variables into the backup service.
- `backup/backup.sh`
  - adds explicit endpoint logging without secrets.
  - probes Postgres with `pg_isready` before dumps.
  - counts live public base tables before each dump.
  - writes each dump to a temporary plain SQL file first, checks it is non-empty, and only then gzips and atomically moves it into place.
  - requires schema/data statements only for DBs that have live public base tables, so intentionally empty app DBs can still be backed up.
  - validates gzip output with `gzip -t`.
  - probes Redis with `PING`, writes RDB to a temp file, checks non-empty, then moves into place.
  - probes MinIO with `mc ls`, mirrors to a temp directory, then moves into place.
  - suppresses noisy successful MinIO object-transfer output while preserving failure stderr.

## Live deployment notes

Runtime uses rootless Podman under `/home/ubuntu`, so verification commands used:

```sh
export HOME=/home/ubuntu XDG_RUNTIME_DIR=/run/user/1000
```

`podman system migrate` was required to recover the stale rootless network namespace before the shared infra containers could be restarted. After recovery:

```text
infa-basic_postgres_1  Up (healthy)  shared-infra
infa-basic_redis_1     Up (healthy)  shared-infra
infa-basic_minio_1     Up            shared-infra
infa-basic_backup_1    Up            shared-infra
```

The one-shot `infa-basic_minio-provisioner_1` is exited after provisioning and is not required for the daily backup job.

## Fresh backup proof

Manual backup command:

```sh
podman exec infa-basic_backup_1 /usr/local/bin/backup.sh
```

Final run output summary:

```text
2026-08-11 05:54:13 === backup 2026-08-11 start ===
2026-08-11 05:54:13 postgres: dumping petag live_public_tables=19
2026-08-11 05:54:14 postgres: dumped petag live_public_tables=19 bytes=5096
2026-08-11 05:54:14 postgres: dumping jbc live_public_tables=0
2026-08-11 05:54:14 postgres: dumped jbc live_public_tables=0 bytes=376
2026-08-11 05:54:14 postgres: dumping photoboxtyb live_public_tables=41
2026-08-11 05:54:14 postgres: dumped photoboxtyb live_public_tables=41 bytes=65729
2026-08-11 05:54:14 postgres: dumping postyb live_public_tables=0
2026-08-11 05:54:14 postgres: dumped postyb live_public_tables=0 bytes=381
2026-08-11 05:54:19 redis: snapshot saved bytes=32912
2026-08-11 05:54:19 minio: mirrored petag objects=0
2026-08-11 05:54:20 minio: mirrored jbc objects=0
2026-08-11 05:54:20 minio: mirrored photoboxtyb objects=67
2026-08-11 05:54:20 minio: mirrored postyb objects=0
2026-08-11 05:54:20 === backup 2026-08-11 complete ===
```

Generated artifact proof under `/home/ubuntu/infra-basic/backups/2026-08-11`:

```text
petag.sql.gz        5096 bytes
jbc.sql.gz           376 bytes
photoboxtyb.sql.gz 65729 bytes
postyb.sql.gz        381 bytes
redis-dump.rdb     32912 bytes
minio/petag            0 objects
minio/jbc              0 objects
minio/photoboxtyb     67 objects
minio/postyb           0 objects
```

This records empty-bucket evidence for petag, jbc, and postyb, and a non-empty mirror for photoboxtyb.

## Restore verification

Restore command shape:

```sh
RESTORE_DB="s4_backup_restore_20260811135344"
podman exec infa-basic_postgres_1 createdb -U postgres "$RESTORE_DB"
zcat backups/2026-08-11/petag.sql.gz | podman exec -i infa-basic_postgres_1 psql -U postgres -d "$RESTORE_DB"
```

Table-count diff:

```text
restore_db=s4_backup_restore_20260811135344
live_public_tables=19
restored_public_tables=19
diff=0
```

The scratch DB was dropped after the table-count check.

## Remaining operational note

The backup job is now working through explicit verified endpoints. Podman service DNS on `shared-infra` still has stale aardvark records on this host, so future full stack recreates should either refresh the endpoint overrides after service IP changes or clean/recreate the Podman network DNS state during a maintenance window.
