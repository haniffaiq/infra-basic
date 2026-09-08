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

`container-logs.json` queries VictoriaLogs, plus VictoriaMetrics for one panel
and for its container picker. Log records carry only a 12-character
`container_id` — the filelog receiver can only recover the id from the log file
path, never the name — so the `container` variable reads id and name off the
`docker_stats` metrics and maps them, letting the dropdown show names while
queries still filter on the id.
