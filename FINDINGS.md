# Findings

Lab: Elasticsearch and Kibana 9.1.0 in Docker under the free basic licence, real
Dapr 1.19.0 logs, traces and metrics from minikube. 1347 log documents, 60829
spans, 577 metric documents, across three data streams written by two separate
collectors.

Screenshots of the main claims are in the README.

Origin: Pylon #6591. Customer detail stays in the ticket.

## 1. The data streams do not need merging

A single Kibana data view accepts a comma separated pattern, and this holds for
all three signals, not just logs and traces. Measured with `_field_caps`:

| pattern | fields | conflicts |
|---|---|---|
| `logs-*` | 50 | 0 |
| `traces-*` | 87 | 0 |
| `metrics-*` | 306 | 0 |
| `logs-*,traces-*` | 118 | 1 |
| `logs-*,traces-*,metrics-*` | 389 | 10 |

Each combined set is an **exact union** of its parts, verified by set comparison
rather than by eye, and every signal contributes fields no other one has:
`code`, `instance` and `kubernetes.*` only from logs; `attributes.dapr.api` and
`attributes.dapr.status_code` only from traces; `attributes.component` and
`attributes.grpc_client_method` only from metrics.

ES|QL spans all three in one query:

    FROM logs-*, traces-*, metrics-* METADATA _index | STATS docs = COUNT(*) BY _index

returns three rows from three data streams written by two different collectors.

So "the logs view and the APM view cannot connect" is a data view configuration
problem rather than a collection problem. One view covers them, and it changes
nothing in the pipeline.

An earlier note from this work put the `logs-*,traces-*` figure at 87. The
measured value is 118; 87 is `traces-*` alone. The conclusion is unchanged and
is now backed by the exact union check rather than a single field count.

## 1b. Widening the pattern collides fields

The three way view has **ten conflicting fields**, and they are the ones that
matter: `app_id`, `method`, `resource.attributes.service.name`,
`kubernetes.namespace`, `kubernetes.pod.name`, `kubernetes.container.name`,
`scope`, `scope.name`, `status`, `resource.schema_url`. A conflicted field
displays in Discover but cannot be aggregated on, so it is unusable in a
visualisation or a `STATS ... BY`.

Two different causes:

- `scope` and `status` genuinely collide. Dapr logs use `scope` as a string;
  OTel uses it as an object for instrumentation scope. Likewise `status` is an
  object on a span. One side has to be renamed in the pipeline.
- The rest are `keyword` against `text`, which is an artifact of the log side
  being dynamically mapped in this lab. A log pipeline writing through a
  template that maps these as `keyword` agrees with the OTel side and the
  conflict disappears.

So the approach holds, but it is not free: it needs the two sides to agree on
mappings, which is a conversation with whoever owns the log pipeline.

## 1c. Metrics carry app_id, but not on service.name

Metric documents carry `attributes.app_id` set to the Dapr app_id, so they join
to the log side on the same identity. But
`resource.attributes.service.name` on a metric is **`daprd`**, not the app id,
because it describes the scrape target rather than the application. On a span
the same field *is* the app id. So `service.name` is a valid join key between
logs and traces and a misleading one between logs and metrics; use
`attributes.app_id` for metrics.

## 2. Dapr already emits service.name

Real span resource attributes contain `service.name: logtest`, which is the Dapr
app_id. Mapping log side `app_id` onto `service.name` is therefore a rename, not
an invention, and it lines the two signals up on the identity Elastic APM
already keys on.

## 3. The join is better than timestamp plus path

A real span carries:

    attributes.dapr.api               "GET /v1.0/invoke/nosuchapp/method/x"
    attributes.dapr.status_code       "500"
    resource.attributes.service.name  "logtest"

The matching access log line carries:

    method   "GET /v1.0/invoke/nosuchapp/method/x"
    code     500
    app_id   "logtest"

So spans and access log lines join on service plus API plus status plus a time
window. Verified on live data for the same requests.

## 4. Trace level click through is still unavailable

No `trace_id` on any log line, confirmed across 1347 documents, including the
API logging lines and with tracing fully sampled and an explicit traceparent on
the request. Feature request filed upstream:
<https://github.com/dapr/dapr/issues/10979>

API logging is Dapr's access log, which is where a service mesh such as Istio
exposes the trace ID, so that is the right place for it rather than on every log
line.

## 4b. Dapr latency histograms are dropped by default

Routing Dapr metrics through the collector's Elasticsearch exporter silently
loses every histogram:

    dropping cumulative temporality histogram "dapr_http_server_latency"
    dropping cumulative temporality histogram "dapr_http_client_roundtrip_latency"
    dropping cumulative temporality histogram "dapr_grpc_io_client_roundtrip_latency"
    ...

Dapr emits cumulative temporality; the exporter wants delta. It reports this at
`warn` and carries on, so the metrics simply are not there. A
`cumulativetodelta` processor in the metrics pipeline fixes it, and is in
`k8s/10-otelcol.yaml`.

This is worth knowing for anyone who has compared the OTel collector path
against scraping the Prometheus endpoint directly and concluded they are
equivalent. For counters and gauges they are. For histograms, which is where the
latency golden signals live, the collector path loses them unless the processor
is present.

## 5. Deliverables

- `elastic/dapr-elastic-dashboard.ndjson` — four panel dashboard plus the
  combined data view. Round trip tested: deleted and re-imported cleanly, six
  objects, zero errors. All four panels verified rendering against real data.
  Panels: API calls by status code over time; 5xx error ratio; p95 latency by
  Dapr API from the trace side; control plane log volume by scope.
- `elastic/dataviews.ndjson` — the three data views on their own.
- `elastic/queries.esql` — every query, verified.

## Caveats

- **Index names differ elsewhere.** This lab used `logs-dapr-default` and
  `traces-generic-default`. A cluster with the APM integration will have
  `traces-apm-*` and its own logs stream. The data view patterns in the NDJSON
  must be edited to match or the panels import cleanly and show nothing.
- The control plane panel shows a blank scope row. That is real: the scheduler's
  embedded cron library logs in a different JSON shape keyed on `logger` rather
  than `scope`, so a pipeline keyed on `scope` drops it. 325 of the dapr-system
  lines were in that shape.
- All spans in the lab share one trace_id because the driver sends a fixed
  traceparent. That is a test artifact, not a finding.

## Things that cost time

- The Elasticsearch exporter failed silently until debug logging revealed
  `index_not_found_exception ... requires a data stream, but no matching index
  template`. A bare cluster has none; Elastic Cloud gets them from the APM
  integration. `elastic/index-templates/` fixes it.
- A traffic driver in its own Deployment produces nothing, because daprd binds
  `--dapr-listen-addresses [::1],127.0.0.1`. It has to be a container in the
  same pod.
- A `logs-*` index template at high priority shadows Elastic's own
  `logs-otel@template` exactly as the metrics one does, and the collector's
  parse failures carry an empty reason either way.
- Kibana saved object imports fail on migration details rather than content:
  missing `datasourceStates.formBased.layers`, missing
  `indexpattern.currentIndexPatternId`, panel reference naming, and a 422 on
  `typeMigrationVersion` newer than the stack knows. The committed NDJSON is
  past all of these.
- The collector image is distroless, so there is no shell to exec into. Probe it
  from a separate curl pod.
- A `metrics-*` index template at priority 500 shadows Elastic's own
  `metrics-otel@template` (`metrics-*.otel-*`, priority 120), and every metric
  document then fails with `document_parsing_exception` carrying an **empty**
  reason string, which gives nothing to search for. `logs-*` and `traces-*` need
  the lab templates; metrics must be left to the built in one.
