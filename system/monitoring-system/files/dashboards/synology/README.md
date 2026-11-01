# synology

`synology.json` is a checked-in copy, not a `gnetId`/`url` import like the
boards in `platform/grafana/values.yaml`. It does not track upstream, and it
carries edits a fresh upstream export would silently lose.

## Why it is forked

The board came out of the old NAS Grafana, where Prometheus scraped the NAS and
nothing else. Here it shares a TSDB with the whole cluster, so 44 of its 84
expressions carry a `job` selector — `snmp`, `nodeexporter`, or
`synology-cadvisor`. Without those selectors the queries match series from
every other scrape target.

The datasource uid was also rebound from the NAS Grafana's `ee17d478vg2kgb` to
this cluster's `prometheus` (c377e11). The export declares no `__inputs`, so
the chart's datasource rewrite never runs against it — a stale uid provisions
clean and renders nothing.

## If it is ever re-imported

Re-apply both the `job` selectors and `"uid": "prometheus"` on every
`datasource` block.

## Provisioning

`templates/configmap-dashboards.yaml` emits one ConfigMap per directory under
`files/dashboards/`, labelled `grafana_dashboard: "1"` and annotated
`grafana_folder: <directory>`. The directory name becomes the Grafana folder.
The template globs `*.json` only, so this file is ignored.
