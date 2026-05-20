# Shared Infrastructure Repo — Design

**Date:** 2026-05-20
**Status:** Approved

## Purpose

A pull-and-run starter repo that boots shared **PostgreSQL**, **Redis**, and **MinIO**
instances for 4 applications on a single server. New server workflow:

```
git clone → cp .env.example .env → fill secrets → docker compose up -d
```

## Apps

`petag`, `jbc`, `photoboxtyb`, `postyb` — referred to as "the 4 apps" below.

## Architecture

- One `docker-compose.yml`.
  - Long-running: `postgres`, `redis`, `minio`.
  - One-shot: `minio-provisioner` (creates buckets + scoped users).
  - Scheduled: `backup` (daily dumps).
- **External Docker network** named `shared-infra`. This repo owns/creates it
  (as the compose project's default network). The 4 app repos declare it
  `external: true` and join it.
- Apps connect by service name: `postgres:5432`, `redis:6379`, `minio:9000`.
- No public ports. Admin ports bound to `127.0.0.1` only:
  - Postgres `127.0.0.1:5432`
  - Redis `127.0.0.1:6379`
  - MinIO API `127.0.0.1:9000`, console `127.0.0.1:9001`
- All 3 services: `restart: unless-stopped` + healthchecks.

## Per-app isolation

### PostgreSQL (`postgres:16-alpine`)
- Init shell script in `/docker-entrypoint-initdb.d/` (`.sh`, so it can read env vars).
- For each app: `CREATE USER <app> WITH PASSWORD ...; CREATE DATABASE <app> OWNER <app>;`
- Each user owns only its own database.
- Volume: `pgdata`.

### Redis (`redis:7-alpine`)
- Custom entrypoint generates an ACL file from env vars at startup, then `exec redis-server`.
- One ACL user per app, restricted to its key prefix: user `petag` may touch only `~petag:*`.
- `default` user kept for admin/backup, password-protected.
- `appendonly yes`. Volume: `redisdata`.
- **Apps must prefix all keys** with `<app>:` (e.g. `petag:session:123`).

### MinIO (`minio/minio`)
- `minio-provisioner` one-shot (`minio/mc`): per app creates a bucket, a scoped
  IAM policy (access limited to that bucket), and a user with that policy.
- Volume: `miniodata`.

## Backup (chosen: volumes + scheduled local backup)

- `backup/` container: alpine + `crond` + `postgresql16-client` + `redis` + `mc`.
- `backup.sh` runs daily:
  - `pg_dump` each of the 4 databases → `.sql.gz`
  - Redis `--rdb` snapshot
  - `mc mirror` each MinIO bucket
- Output: `./backups/YYYY-MM-DD/`. Pruned after `BACKUP_RETENTION_DAYS`.
- `./backups` is gitignored. Operator copies it off-server (no offsite automation yet).

## Secrets (chosen: .env, gitignored)

- `.env` is gitignored. `.env.example` ships with blank placeholders.
- New server: `cp .env.example .env`, fill in strong secrets manually.

## File structure

```
infa-basic/
├── docker-compose.yml
├── .env.example
├── .gitignore
├── README.md
├── postgres/init/01-create-apps.sh
├── redis/redis.conf
├── redis/entrypoint.sh
├── minio/provision.sh
├── backup/Dockerfile
├── backup/backup.sh
├── backup/crontab
├── scripts/smoke-test.sh
└── backups/                (runtime, gitignored)
```

## Known constraints (documented in README)

- Postgres init script runs **only on an empty volume**. Changing app SQL after
  first boot has no effect — adding a 5th app later means manual `psql`/`mc` commands.
- Redis isolation depends on apps respecting the `<app>:` key prefix convention.

## Testing

`scripts/smoke-test.sh` after `docker compose up`:
- each app connects to Postgres / Redis / MinIO with its own credentials — passes
- each app is blocked from another app's database / keys / bucket — passes (isolation proof)

## Connection strings (per app, documented in README)

- Postgres: `postgresql://<app>:<pw>@postgres:5432/<app>`
- Redis: `redis://<app>:<pw>@redis:6379/0` — keys must be `<app>:*`
- MinIO: endpoint `minio:9000`, per-app access/secret key, bucket `<app>`
