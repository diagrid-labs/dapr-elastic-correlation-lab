# dapr-elastic-correlation-lab

Dapr logs reach Elastic through the platform team's log shipper, landing in
`logs-*`. Traces and metrics reach it through an OpenTelemetry collector,
landing in the APM streams. Two data views, and you have to leave one and search
in the other to follow anything across them.

A Kibana data view takes a comma separated pattern, so one view covers all three.

![one data view](images/one-data-view.svg)

That's the fix. One view, three patterns, nothing changes in the pipeline.

Here it is against real Dapr 1.19 data: one query, three data streams, two
different collectors.

![ES|QL across three streams](images/esql-three-streams.jpg)

## Lining a span up with its log lines

Dapr sets `service.name` on the span to the app_id, so it already matches the
log side. The span also carries `attributes.dapr.api` and
`attributes.dapr.status_code`, which match the access log line's `method` and
`code` exactly. So a span and its access log lines join on service, API, status
and a time window.

Metrics join on `attributes.app_id`.

One thing this does not give you is Elastic's trace to logs click-through in the
APM UI, which keys on `trace.id`. Dapr log lines do not carry one: the span has
`trace_id` and `span_id`, the matching `HTTP API Called` line has 14 fields and
none of them is a trace id. Moving the logs into the APM data stream would not
change that either. That needs
<https://github.com/dapr/dapr/issues/10979>.

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
