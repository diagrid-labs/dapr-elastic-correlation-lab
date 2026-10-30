# dapr-elastic-correlation-lab

Dapr logs reach Elastic through the platform team's log shipper. Traces and
metrics reach it through an OpenTelemetry collector. They land in different data
streams, and the usual conclusion is that the two "cannot be connected" and the
logs need moving.

They don't. A Kibana data view takes a comma separated pattern.

![one data view](images/one-data-view.svg)

That's the whole fix. One view, three patterns, nothing changes in the pipeline.

Here it is against real Dapr 1.19 data: one query, three data streams, two
different collectors.

![ES|QL across three streams](images/esql-three-streams.jpg)

## Correlating logs and traces

Dapr sets `service.name` on the span to the app_id, so it already matches the
log side. The span also carries `attributes.dapr.api` and
`attributes.dapr.status_code`, which match the `HTTP API Called` access log
line's `method` and `code` exactly. So a span and its access log lines join on
service, API, status and a time window.

Metrics join on `attributes.app_id`.

There is no `trace_id` on a Dapr log line, so clicking from a trace straight to
its logs needs <https://github.com/dapr/dapr/issues/10979>.

## Dashboard

![dashboard](images/dashboard.jpg)

`elastic/dapr-elastic-dashboard.ndjson`: API calls by status code, 5xx ratio,
p95 latency per Dapr API from the trace side, control plane log volume by scope.

The index patterns in it are this lab's. Edit them to match your cluster before
importing, otherwise it imports fine and shows nothing.

## Running it

Needs minikube and Docker.

```bash
./scripts/setup.sh
```

Kibana is at <http://localhost:5601>. Data flows continuously; there is nothing
to re-run.

    docker-compose.yml   Elasticsearch + Kibana
    k8s/                 tracing config, collectors, test workload
    elastic/             dashboard, data views, queries

## Worth knowing

- **API logging is Dapr's access log.** Without
  `dapr.io/enable-api-logging: "true"` there are no `HTTP API Called` lines to
  correlate against.
- **Only log collection needs node access.** daprd pushes traces and exposes
  metrics for scraping, so those collectors are ordinary Deployments. Tailing
  container log files is the one job that needs a DaemonSet.
- **Widening a data view can collide fields** that are mapped differently on
  each side. Each pattern on its own is clean, and a dashboard can mix panels
  from different views, so this does not block charting.

[FINDINGS.md](FINDINGS.md) has the measurements and the things that cost time.
