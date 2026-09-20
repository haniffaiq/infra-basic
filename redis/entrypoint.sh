#!/bin/sh
# Regenerates the Redis ACL file from environment variables on every start,
# then launches redis-server. Each app user is locked to its own `<app>:*`
# key prefix and pub/sub channel prefix.
set -eu

ACL=/data/users.acl

# default user: full access, used by admin + backup.
echo "user default on >${REDIS_PASSWORD} ~* &* +@all" > "$ACL"

add_user() {
  app="$1"
  pw="$2"
  # +@all -@dangerous locks out destructive/admin commands; +info is added
  # back because BullMQ (used by the apps) issues INFO on every connection.
  # INFO is a read-only server-stats command, safe for key-scoped users.
  echo "user ${app} on >${pw} ~${app}:* &${app}:* +@all -@dangerous +info" >> "$ACL"
  echo "redis: configured ACL user '${app}'"
}

add_user petag       "$PETAG_REDIS_PASSWORD"
add_user photoboxtyb "$PHOTOBOXTYB_REDIS_PASSWORD"
add_user postyb      "$POSTYB_REDIS_PASSWORD"
add_user osvyn       "$OSVYN_REDIS_PASSWORD"

exec "$@"
