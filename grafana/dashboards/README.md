# Dashboard JSON — reference copies, not provisioned

These are the four dashboards migrated from the Grafana that used to run in
the separate `monitoring` compose project, exported on 2026-09-08 before that
Grafana was retired.

They are **not** wired to a Grafana dashboard provisioner, on purpose — see the
comment in `../provisioning/datasources/datasources.yml`. A provisioner would
overwrite hand-edits on every restart. These files were imported once through
the HTTP API (`POST /api/dashboards/db`), so they now live in the `grafana`
PostgreSQL database, stay editable in the UI, and are covered by `backup.sh`.

They are kept here as a version-controlled record and a rebuild path. To
re-import one after an edit in the UI, export it from the UI and overwrite the
file here.

All four query the `prometheus` datasource, which is the Prometheus still
running in the `monitoring` project. The OTel collector produces none of the
`probe_*`, `nginx_*`, `node_*` or `dockerstats_*` metrics they need.
