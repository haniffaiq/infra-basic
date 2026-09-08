# Dashboard JSON — reference copies, not provisioned

`container-logs.json` is authored here and reads from VictoriaLogs. The other
four were migrated from the Grafana that used to run in the separate
`monitoring` compose project, exported on 2026-09-08 before it was retired.

They are **not** wired to a Grafana dashboard provisioner, on purpose — see the
comment in `../provisioning/datasources/datasources.yml`. A provisioner would
overwrite hand-edits on every restart. These files were imported once through
the HTTP API (`POST /api/dashboards/db`), so they now live in the `grafana`
PostgreSQL database, stay editable in the UI, and are covered by `backup.sh`.

They are kept here as a version-controlled record and a rebuild path. To
re-import one after an edit in the UI, export it from the UI and overwrite the
file here.

The four migrated dashboards query the `prometheus` datasource, which is the
Prometheus still running in the `monitoring` project. The OTel collector
produces none of the `probe_*`, `nginx_*`, `node_*` or `dockerstats_*` metrics
they need.

`container-logs.json` queries VictoriaLogs, plus VictoriaMetrics for the
per-container CPU and memory panels and for its container picker. Log records
carry a `container_id` and no name — Docker's json-file records hold only
`{"log","stream","time"}` and the name is reachable only through the Docker
API — so the `container` variable reads id and name off the `docker_stats`
metrics and maps them: the dropdown lists names, the queries filter on the id.

The variable captures the first 12 hex characters of the id and every filter
matches by prefix (`container_id:${container}*` in LogsQL, `container_id=~
"${container}.*"` in PromQL). That is deliberate: records written before the
filelog regex was widened to the full 64-character id still carry a
12-character one, and prefix matching reads both.
