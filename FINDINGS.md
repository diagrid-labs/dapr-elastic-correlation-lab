# Findings

Lab: Elasticsearch and Kibana 9.1.0 in Docker under the free basic licence, real
Dapr 1.19.0 logs and traces from minikube. 1347 log documents, 350 spans.

Origin: Pylon #6591. Customer detail stays in the ticket.

## 1. The data streams do not need merging

A single Kibana data view accepts a comma separated pattern. `logs-*,traces-*`
resolved **87 fields across both sides** in one view: `app_id`, `method`, `code`
and `message` from the logs, and `trace_id`, `span_id`,
`resource.attributes.service.name` and `attributes.dapr.*` from the traces.

ES|QL spans both patterns in one query too:

    FROM logs-*, traces-* METADATA _index | STATS docs = COUNT(*) BY _index

returned 1347 log documents and 350 trace documents together.

So "the logs view and the APM view cannot connect" is a data view configuration
problem rather than a collection problem. One view covers both, and it changes
nothing in the pipeline.

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
- Kibana saved object imports fail on migration details rather than content:
  missing `datasourceStates.formBased.layers`, missing
  `indexpattern.currentIndexPatternId`, panel reference naming, and a 422 on
  `typeMigrationVersion` newer than the stack knows. The committed NDJSON is
  past all of these.
- The collector image is distroless, so there is no shell to exec into. Probe it
  from a separate curl pod.
