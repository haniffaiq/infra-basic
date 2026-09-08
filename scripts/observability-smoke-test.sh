#!/usr/bin/env bash
# Verifies the observability stack is collecting and storing telemetry.
# Run after `docker compose up -d` has settled. Run from the repo root.
set -u

cd "$(dirname "$0")/.."
if [ ! -f .env ]; then echo "ERROR: .env not found"; exit 1; fi
set -a; . ./.env; set +a

pass=0; fail=0
ok()  { echo "  ok   - $1"; pass=$((pass+1)); }
bad() { echo "  FAIL - $1"; fail=$((fail+1)); }

# Two curl helpers, because the two networks are deliberately separated.
# netcurl runs on the observability network, where the backends live; apps on
# shared-infra cannot reach them, and that is the point.
netcurl() { docker run --rm --network observability curlimages/curl:latest -s "$@"; }
# appcurl runs on shared-infra, the only network an app is on. It is used solely
# to POST to otel-collector:4318, so the round-trip exercises the real app path.
appcurl() { docker run --rm --network shared-infra curlimages/curl:latest -s "$@"; }

echo "== VictoriaMetrics =="
if netcurl -f http://victoriametrics:8428/health | grep -q OK; then
  ok "victoriametrics is healthy"
else
  bad "victoriametrics is healthy"
fi

echo "== Collector =="
if netcurl -f http://otel-collector:13133 >/dev/null; then
  ok "collector is healthy"
else
  bad "collector is healthy"
fi

# Asserts at least one stored series whose name starts with $1.
have_metric() {
  netcurl "http://victoriametrics:8428/api/v1/label/__name__/values" \
    | grep -q "\"$1" && ok "metrics present: $1*" || bad "metrics present: $1*"
}

have_metric system_
have_metric container_
have_metric redis_
have_metric postgresql_
have_metric minio_

echo "== VictoriaLogs =="
if netcurl -f http://victorialogs:9428/health >/dev/null; then
  ok "victorialogs is healthy"
else
  bad "victorialogs is healthy"
fi

# At least one log record ingested in the last 5 minutes.
if netcurl -X POST http://victorialogs:9428/select/logsql/query \
     --data-urlencode 'query=_time:5m' --data-urlencode 'limit=1' \
     | grep -q '_msg'; then
  ok "container logs are being ingested"
else
  bad "container logs are being ingested"
fi

echo "== OTLP round-trip =="
appcurl -X POST http://otel-collector:4318/v1/logs \
  -H 'Content-Type: application/json' \
  -d '{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"smoketest"}}]},"scopeLogs":[{"logRecords":[{"body":{"stringValue":"otlp-roundtrip-probe"}}]}]}]}' \
  >/dev/null

# OTLP rejects a data point with no timestamp, so stamp it with the current
# nanosecond clock rather than leaving timeUnixNano at zero.
now="$(date +%s%N)"
appcurl -X POST http://otel-collector:4318/v1/metrics \
  -H 'Content-Type: application/json' \
  -d "{\"resourceMetrics\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"smoketest\"}}]},\"scopeMetrics\":[{\"metrics\":[{\"name\":\"otlp.roundtrip.probe\",\"gauge\":{\"dataPoints\":[{\"asInt\":\"1\",\"timeUnixNano\":\"${now}\"}]}}]}]}]}" \
  >/dev/null
sleep 20
if netcurl -X POST http://victorialogs:9428/select/logsql/query \
     --data-urlencode 'query=otlp-roundtrip-probe' --data-urlencode 'limit=1' \
     | grep -q 'otlp-roundtrip-probe'; then
  ok "OTLP log pushed by an app reaches victorialogs"
else
  bad "OTLP log pushed by an app reaches victorialogs"
fi
have_metric otlp_roundtrip_probe

echo "== Backup coverage =="
grep -q 'grafana' backup/backup.sh \
  && ok "backup.sh dumps the grafana database" \
  || bad "backup.sh dumps the grafana database"

echo "== Grafana =="
# Plain host curl, not netcurl: Grafana is checked on the published host port,
# the same way nginx will reach it.
# The `:-` defaults matter under `set -u` — these keys may not be in .env yet,
# and an unbound variable would abort the script and lose the fail tally.
if curl -sf "http://127.0.0.1:${GRAFANA_PORT:-3001}/api/health" | grep -q '"database": *"ok"'; then
  ok "grafana is healthy"
else
  bad "grafana is healthy"
fi

ds=$(curl -sf -u "admin:${GRAFANA_ADMIN_PASSWORD:-}" \
       "http://127.0.0.1:${GRAFANA_PORT:-3001}/api/datasources" || echo '')
echo "$ds" | grep -q 'VictoriaMetrics' \
  && ok "VictoriaMetrics datasource provisioned" \
  || bad "VictoriaMetrics datasource provisioned"
echo "$ds" | grep -q 'VictoriaLogs' \
  && ok "VictoriaLogs datasource provisioned" \
  || bad "VictoriaLogs datasource provisioned"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
