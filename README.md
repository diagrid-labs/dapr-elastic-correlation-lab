# dapr-elastic-correlation-lab

Correlating Dapr logs with Dapr traces in Elastic when the two arrive through
different pipelines, which is the normal situation: a log shipper owned by the
platform team writes container logs into `logs-*`, while an OpenTelemetry
collector writes spans into the APM data streams. The usual complaint is that
the two "cannot be connected" and that the logs therefore need to be moved into
the APM stream.

They do not. This lab reproduces the split end to end and shows what actually
closes the gap.

Everything here was run and verified. Elasticsearch and Kibana 9.1.0 under the
free basic licence, so no Elastic account is needed. Dapr 1.19.0 on minikube.

## What it shows

**A single Kibana data view accepts a comma separated pattern.** `logs-*,traces-*`
resolved 87 fields from both sides at once: `app_id`, `method`, `code` and
`message` from the logs next to `trace_id`, `span_id`,
`resource.attributes.service.name` and `attributes.dapr.*` from the traces.
ES|QL spans both patterns in one statement the same way. Two data views that do
not connect is a data view configuration problem, not a data stream problem, and
no pipeline change is required to fix it.

**Dapr already emits the identity Elastic APM keys on.** Span resource
attributes carry `service.name` set to the Dapr app_id, so aligning the log side
is a field rename rather than an invention.

**The join is stronger than timestamp and path.** A span carries
`attributes.dapr.api` and `attributes.dapr.status_code`; the matching
`HTTP API Called` access log line carries `method` and `code` with the same
values. So spans and access log lines join on service plus API plus status
within a time window.

**Trace level click through is still missing.** There is no `trace_id` on any
Dapr log line, confirmed across 1347 documents. Feature request filed upstream:
<https://github.com/dapr/dapr/issues/10979>.

Full detail, including what did not work, is in [FINDINGS.md](FINDINGS.md).

## Layout

    docker-compose.yml                 Elasticsearch + Kibana 9.1.0
    k8s/00-tracing-config.yaml         fully sampled tracing, OTLP push
    k8s/10-otelcol.yaml                collector as a Deployment, not a DaemonSet
    k8s/20-logtest.yaml                app + daprd + traffic driver
    elastic/index-templates/           data stream templates the exporter needs
    elastic/dapr-elastic-dashboard.ndjson   four panel dashboard + combined data view
    elastic/dataviews.ndjson           the data views alone
    elastic/queries.esql               every query, verified
    scripts/harvest.py                 stands in for the log shipper
    scripts/setup.sh                   stands the whole thing up
    scripts/teardown.sh                removes it

## Running it

Needs a running minikube and Docker.

```bash
./scripts/setup.sh
```

Then open Kibana at <http://localhost:5601> and import
`elastic/dapr-elastic-dashboard.ndjson` under Stack Management, Saved Objects,
Import.

Override the defaults with `KUBE_CONTEXT` and `ES_URL` if needed. Always pin the
context; the script defaults to `minikube` rather than whatever is current.

## Reusing the dashboard elsewhere

**The index patterns in the NDJSON are this lab's, not yours.** It uses
`logs-dapr-default` and `traces-generic-default`. A cluster running the APM
integration will have `traces-apm-*` and its own logs stream. Edit the data view
patterns in the saved objects before importing, otherwise the panels import
cleanly and show nothing.

The four panels are Dapr API call volume by status code, the 5xx error ratio,
p95 latency per Dapr API from the trace side, and control plane log volume by
scope. Round trip tested: deleted and re-imported cleanly, six objects, zero
errors, all four verified rendering against real data.

## Traps worth knowing

**API logging is the access log.** Without `dapr.io/enable-api-logging: "true"`
there are no `HTTP API Called` lines and nothing to correlate a span against.

**`global.logAsJson` is control plane only.** The sidecar needs the
`dapr.io/log-as-json` annotation. Neither implies the other.

**The traffic driver must share the pod.** daprd binds its HTTP API to
`[::1],127.0.0.1`, so a driver in its own Deployment reaches nothing while
looking perfectly correct.

**The collector needs no node access.** daprd pushes OTLP to an endpoint, so an
ordinary Deployment in the application team's own namespace is enough. A
DaemonSet is only needed to tail files off the node, which is the log shipper's
job, not the collector's.

**A bare cluster has no data stream templates.** The Elasticsearch exporter
fails with `index_not_found_exception ... requires a data stream, but no
matching index template`, and the collector reports it only at debug level.
Elastic Cloud ships equivalents through the APM integration. `setup.sh` installs
them.

**`_index` needs `METADATA _index` in ES|QL**, or it is an unknown column.

**Control plane logs are not one format.** Even with JSON enabled, `dapr-system`
emits three: the Dapr logger, the scheduler's zap cron lines keyed on `ts` and
`logger`, and klog plaintext from the operator. A pipeline keyed on `scope`
silently drops the cron lines; that is the blank scope row in the dashboard, and
it is real rather than a bug in the panel.
