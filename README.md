# infa-basic

Shared infrastructure starter: one **PostgreSQL**, one **Redis**, one **MinIO**,
backing 4 apps on a single server — `petag`, `jbc`, `photoboxtyb`, `postyb`.

Each app gets its own isolated database, Redis ACL user, and MinIO bucket.

## Bootstrap (new server)

```sh
git clone <this-repo> infa-basic
cd infa-basic
cp .env.example .env
# fill .env with strong secrets — e.g. openssl rand -base64 24
docker compose up -d
./scripts/smoke-test.sh        # verify connectivity + isolation
```

`docker compose up -d` boots the 3 services, creates the per-app databases /
Redis users / MinIO buckets, and starts the daily backup container.

## How apps connect

All apps run on the **same server, in Docker**, joined to the external network
`shared-infra` (created by this project). In each app's `docker-compose.yml`:

```yaml
networks:
  shared-infra:
    external: true

services:
  myapp:
    networks: [shared-infra]
```

Then connect by service name:

| Service  | Connection string                                      | Notes |
|----------|---------------------------------------------------------|-------|
| Postgres | `postgresql://<app>:<pw>@postgres:5432/<app>`           | |
| Redis    | `redis://<app>:<pw>@redis:6379/0`                       | **keys must be prefixed `<app>:`** |
| MinIO    | endpoint `minio:9000`, per-app access/secret key, bucket `<app>` | |

Example for `petag`: db `petag`, Redis user `petag` (keys `petag:session:…`),
MinIO bucket `petag`.

Admin access from the host only (bound to `127.0.0.1`): Postgres `5432`,
Redis `6379`, MinIO API `9000`, MinIO console `9001`.

## Isolation

- **Postgres** — each app owns its database; `CONNECT` is revoked from `PUBLIC`,
  so one app cannot reach another's database.
- **Redis** — each app is an ACL user limited to its `<app>:*` key and channel
  prefix. Apps **must** prefix every key, or reads/writes are denied.
- **MinIO** — each app user has a policy scoped to its own bucket only.

## Backups

The `backup` container runs daily at 03:00: `pg_dump` of every database, a Redis
RDB snapshot, and a mirror of every MinIO bucket — written to
`./backups/YYYY-MM-DD/`. Backups older than `BACKUP_RETENTION_DAYS` (default 7)
are pruned. `./backups` is gitignored — **copy it off-server yourself.**

Run a backup immediately:

```sh
docker compose exec backup /usr/local/bin/backup.sh
```

Restore a database:

```sh
gunzip -c backups/2026-05-20/petag.sql.gz | \
  docker compose exec -T postgres psql -U postgres -d petag
```

## Adding a 5th app later

The Postgres init script and MinIO provisioner only create resources for the
4 apps above. The Postgres script runs **only on a fresh data volume** —
editing it after first boot has no effect. To add an app on a running stack:

1. Add its secrets to `.env`.
2. Postgres — create the database + user manually:
   ```sh
   docker compose exec postgres psql -U postgres -c \
     "CREATE USER app5 WITH PASSWORD '...'; CREATE DATABASE app5 OWNER app5;
      REVOKE CONNECT ON DATABASE app5 FROM PUBLIC; GRANT CONNECT ON DATABASE app5 TO app5;"
   ```
3. Redis — add an `add_user` line to `redis/entrypoint.sh`, then
   `docker compose restart redis`.
4. MinIO — add a `provision` line to `minio/provision.sh`, then
   `docker compose up -d minio-provisioner`.

(For a clean 5-app setup from scratch, just edit the 4 source files first.)

## Common commands

```sh
docker compose ps                  # status
docker compose logs -f postgres    # logs
docker compose down                # stop (volumes kept)
docker compose down -v             # stop + DELETE ALL DATA
```
