#!/bin/sh
# One-shot, idempotent. Per app: creates a bucket, a policy scoped to that
# bucket, and a user bound to that policy. Safe to re-run.
set -eu

echo "minio: waiting for server..."
until mc alias set local "http://minio:9000" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 \
      && mc ready local >/dev/null 2>&1; do
  sleep 2
done

provision() {
  app="$1"
  ak="$2"
  sk="$3"

  mc mb --ignore-existing "local/${app}"

  cat > "/tmp/${app}-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:*"],
      "Resource": ["arn:aws:s3:::${app}", "arn:aws:s3:::${app}/*"]
    }
  ]
}
EOF

  mc admin policy create local "${app}-policy" "/tmp/${app}-policy.json" 2>/dev/null || true
  mc admin user add local "$ak" "$sk" 2>/dev/null || true
  mc admin policy attach local "${app}-policy" --user "$ak" 2>/dev/null || true
  echo "minio: provisioned app '${app}' (bucket + scoped user)"
}

provision petag       "$PETAG_MINIO_ACCESS_KEY"       "$PETAG_MINIO_SECRET_KEY"
provision photoboxtyb "$PHOTOBOXTYB_MINIO_ACCESS_KEY" "$PHOTOBOXTYB_MINIO_SECRET_KEY"
provision postyb      "$POSTYB_MINIO_ACCESS_KEY"      "$POSTYB_MINIO_SECRET_KEY"
provision osvyn       "$OSVYN_MINIO_ACCESS_KEY"       "$OSVYN_MINIO_SECRET_KEY"

echo "minio: provisioning complete"
