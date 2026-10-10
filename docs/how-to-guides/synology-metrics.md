# Synology metrics

The Synology NAS at `192.168.3.20` ran a self-contained observability stack in
Container Manager — InfluxDB, unpoller, Prometheus, node-exporter,
snmp-exporter, cadvisor and its own Grafana on port `3340`. Phase 1 moved the
**collection and the dashboards** into the cluster. The NAS stack is still
running; tearing it down is Phase 2.

| Thing | Lives in |
| --- | --- |
| NAS scrape targets | `system/monitoring-system/templates/scrapeconfig-synology.yaml` |
| Prometheus storage and retention | `system/monitoring-system/values.yaml` |
| Synology dashboard | `system/monitoring-system/files/dashboards/synology.json` |
| UniFi dashboards | `platform/grafana/values.yaml` (`grafana-dashboards-network`) |
| UniFi poller | `apps/unpoller/` |
| URL | <https://grafana.malford.io> |

## The NAS publishes three ports

The NAS exporters are plain HTTP endpoints with no Kubernetes Service to
select, so they are scraped by `ScrapeConfig` rather than `ServiceMonitor`. That
requires the compose file to publish them — by default they are reachable only
over the Docker bridge.

This is the only part of the pipeline that is **not deployed from this repo**.
The file below is kept here as the source of truth; applying it means pasting it
into the Container Manager project and recreating it. Nothing syncs.

```yaml title="./docs/how-to-guides/files/synology-compose.yml"
--8<--
./docs/how-to-guides/files/synology-compose.yml
--8<--
```

Those three `ports:` blocks are the entire contract with the cluster. If the
project is ever recreated from an older compose file they go missing and all
three targets go down together.

!!! warning "The job names are load-bearing"

    `nodeexporter` and `snmp` are chosen to satisfy the Synology dashboard,
    which hardcodes them in 38 expressions. Renaming either silently empties
    those panels — the targets stay up and nothing alerts.

    `nodeexporter` does **not** collide with the cluster's own DaemonSet job,
    which is `node-exporter`, with a hyphen. Check both when touching either.

## /metrics is not /federate

The original scrape job pointed at `http://192.168.3.20:9090/metrics`. That is
the NAS Prometheus reporting on *itself* — 778 series, of which 575 are
`prometheus_*` and 142 are `go_*`, and **zero** `node_*`. A Prometheus serves
its stored series at `/federate?match[]=...`, never at `/metrics`.

The job was up and green the entire time it collected nothing usable. Scraping
the exporters directly avoids the distinction altogether.

## The SNMP target is rewritten

The NAS passes `target=172.22.0.1` — the compose bridge gateway as seen from
inside the container. From the cluster it has to be the NAS's LAN address:

```yaml
  params:
    auth: [snmpv3]
    module: [synology]
    target: ["192.168.3.20"]
```

The snmpv3 credentials stay in `snmp.yml` on the NAS. Nothing secret moved into
git.

## unpoller moved into the cluster

unpoller only needs to reach the UniFi controller over HTTPS, so nothing tied
it to the NAS. It now runs in `apps/unpoller/` with `UP_INFLUXDB_DISABLE: true`
— after this nothing writes to the NAS InfluxDB, which is what makes the Phase 2
teardown clean.

The controller URL is `https://192.168.3.1` with **no port**: UnifiOS proxies
the controller on 443, and the older `:8443` is wrong here. Credentials come
from the existing `unifi-admin-username` / `unifi-admin-password` entries in the
secret store, so no new secrets were created.

This is the first `ServiceMonitor` defined by an app in this repo rather than
inherited from an upstream chart.

## The dashboards

The four UniFi boards on the NAS were the **InfluxDB** variants. InfluxQL does
not translate to PromQL, so they were replaced with the same author's
Prometheus-native equivalents rather than ported:

| Was (InfluxDB) | Now (Prometheus) |
| --- | --- |
| 10418 Client Insights | 11315 |
| 10414 Network Sites | 11311 |
| 10415 UAP Insights | 11314 |
| 10416 USG Insights | 11313 |
| — | 11310 Client DPI (new) |

Nothing was lost: all four NAS boards were `version: 1` with
`created == updated`, i.e. imported once and never edited.

!!! warning "The Synology board is a fork"

    It is committed as a ConfigMap, not a `gnetId`, so it does **not** follow
    upstream. Fourteen expressions were edited because the upstream board
    assumes a NAS-only Prometheus and breaks loudly in a shared TSDB:

    | Panel group | Was | Returned |
    | --- | --- | --- |
    | System uptime | `node_time_seconds{} - node_boot_time_seconds{}` | 7 series |
    | Exporter Status | bare `up` | 54 rows |
    | Storage totals | `node_disk_{read,written}_bytes_total{}` | 157 series each |
    | Docker row (10 panels) | `container_*{name=~".+"}` | 377 series, from kubelet |

    Each now carries a job selector. The Speedtest row was dropped —
    `speedtest_exporter` was not migrated and nothing in the cluster emits
    `speedtest_*`. If the board is ever re-imported, all of this must be
    re-applied.

The remaining ~19 panels read SNMP bare-name metrics — `modelName`,
`temperature`, `raidStatus`, `powerStatus`, the `mem*` and `ups*` families — and
need no selector because no cluster target emits any of them. That was verified
before the series existed; prefixing them `synology_*` would cost ~21 further
panel edits and was declined.

Folder placement uses `sidecar.dashboards.folderAnnotation`, enabled in
`platform/grafana/values.yaml`. The 26 kube-prometheus-stack dashboards carry no
annotation and stay in General.

### Every board has to be bound to a datasource

All six provisioned clean and rendered nothing. A dashboard reaching Grafana is
not the same as a dashboard that can *query* — the second failure is invisible
to every target and query check above.

!!! warning "gnetId exports with `__inputs` need a `datasource` key"

    A grafana.com export that declares
    `__inputs: [{name: "DS_PROMETHEUS", ...}]` sets every panel's datasource to
    the literal string `${DS_PROMETHEUS}`. Grafana cannot resolve it. Only a
    per-dashboard `datasource:` key makes the chart emit the substitution into
    `download_dashboards.sh`:

    ```sh
    | sed '/-- .* --/! s/"datasource":.*,/"datasource": "Prometheus",/g'
    ```

    All five UniFi boards need it. Ceph (2842) does not — its export declares
    no `__inputs`, so its panels are `datasource: null` and fall through to the
    default. Check `__inputs` before adding any new `gnetId`.

!!! warning "Never pull dashboard JSON through another Grafana's API"

    `/api/dashboards/uid/...` returns that Grafana's **own datasource UIDs**,
    not portable `${DS_*}` placeholders. The Synology board arrived carrying the
    NAS Grafana's uid `ee17d478vg2kgb` in 121 places, plus a `datasource`-type
    template variable whose `current` still named a NAS datasource. The
    template variable is a separate fix — correcting the panels does not touch
    it. Both are rewritten to `prometheus`, the cluster datasource uid.

`download_dashboards.sh` runs in an **init container**, so a `gnetId` change
needs a pod restart, not just a sync:

```sh
kubectl -n grafana rollout restart deploy/grafana
```

## Prometheus got a volume

The cluster TSDB was an `emptyDir` — 15.6 GB on whichever node the pod landed
on, discarded on every restart. It is now a 60Gi `standard-rwo` PVC with
`retention: 30d` and `retentionSize: 48GiB`.

30 days costs roughly 47 GB at current ingestion, so **the clock expires data,
not the size guard**. `retentionSize` sits just above that as a backstop: if the
series count grows it trips first and costs retention days instead of wedging
the TSDB on a full volume.

!!! note "Growing the volume later is awkward"

    `volumeClaimTemplates` are immutable. Ceph RBD supports expansion, but the
    StatefulSet template and the live PVC then drift, and the operator may need:

    ```sh
    kubectl -n monitoring-system delete sts \
      prometheus-monitoring-system-kube-pro-prometheus --cascade=orphan
    ```

    Both retention limits are cheap to change — they are container args.

## Verifying

```sh
kubectl -n monitoring-system port-forward \
  svc/monitoring-system-kube-pro-prometheus 9091:9090 &
sleep 5
curl -s localhost:9091/api/v1/targets | python3 -c "
import sys,json
want={'nodeexporter','snmp','synology-cadvisor'}
for t in json.load(sys.stdin)['data']['activeTargets']:
    j=t['labels'].get('job','')
    if j in want or 'unpoller' in j:
        print(f\"{j:22} {t['health']:8} {t['scrapeUrl']}\")
"
```

All four must read `up`. Then confirm the data actually arrived — the check the
original config would have failed:

```sh
for q in 'count(node_cpu_seconds_total{job="nodeexporter"})' \
         'count({job="snmp"})' \
         'count(container_memory_usage_bytes{job="synology-cadvisor"})' \
         'count({__name__=~"unpoller_.*"})'; do
  curl -s --get localhost:9091/api/v1/query --data-urlencode "query=$q" \
    | python3 -c "import sys,json;r=json.load(sys.stdin)['data']['result'];print(r[0]['value'][1] if r else 0)"
done
```

Four non-zero numbers. Zero on the first three means the NAS ports are not
published; zero on the fourth means unpoller cannot authenticate.

Confirm the cluster DaemonSet is untouched and still distinct — expect two rows,
`node-exporter` = 6 and `nodeexporter` = 1:

```sh
curl -s --get localhost:9091/api/v1/query \
  --data-urlencode 'query=count by (job) (node_time_seconds)'
```

Metrics arriving does not mean panels render. Check the binding separately —
every uid must be `prometheus` or the name string `Prometheus`, and no
`${DS_` may survive:

```sh
R="--resolve grafana.malford.io:443:192.168.5.225"
for uid in lcHlCU2Vz 9WaGWZaZk; do
  curl -s $R "https://grafana.malford.io/api/dashboards/uid/$uid" | python3 -c "
import sys,json,re
d=json.load(sys.stdin)['dashboard']
raw=json.dumps(d)
print(d['title'][:34].ljust(36), 'unresolved=', len(re.findall(r'\\\$\{DS_', raw)))
"
done
```

A single `unresolved` hit means a `gnetId` entry is missing its `datasource`
key, or the pod has not been restarted since it was added.

On the Synology board itself, the edited groups are where a mistake shows up:
**System uptime** must show one value, not seven; **Exporter Status** three
rows, not fifty-four; the **Docker row** only NAS containers.

## Phase 2 — tearing the NAS stack down

The compose file above **is** the post-teardown state. It drops InfluxDB, the
NAS Grafana, the NAS Prometheus, the NAS unpoller and `speedtest_exporter`,
along with the `grafana_net` network that only they used. node-exporter,
snmp-exporter and cadvisor stay — they are the targets this pipeline scrapes.
Ports 8086, 3340 and 9090 are freed.

Removing the services orphans their data on disk but does not delete it, which
is the right order. Keep `./unifi-poller/influxdb`, `./grafana`, `./prometheus`
and `./prometheus.yml` until the cluster has been trusted for a week.
`./snmp.yml` is still load-bearing — leave it. `./.env.metrics` becomes
unreferenced but still holds UniFi and InfluxDB credentials, so delete it rather
than leave it lying around.

Historical InfluxDB data is not migrated; Prometheus starts fresh, and the gap
is accepted.

!!! note "The Docker row gets smaller, and that is correct"

    cadvisor reported 13 container series with the full stack running. After
    teardown it sees three containers. Not a regression — but it looks like one.

After recreating the project, confirm the ports still answer:

```sh
for p in 9100 9338 9116; do
  printf '%s ' "$p"; curl -s -o /dev/null -w '%{http_code}\n' "http://192.168.3.20:$p/"
done
```

Then confirm the cluster still sees all three — expect `3`:

```sh
curl -s -G --resolve grafana.malford.io:443:192.168.5.225 \
  "https://grafana.malford.io/api/datasources/proxy/uid/prometheus/api/v1/query" \
  --data-urlencode 'query=count(up{job=~"nodeexporter|snmp|synology-cadvisor"} == 1)'
```
