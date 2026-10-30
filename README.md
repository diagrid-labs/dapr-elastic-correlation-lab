# dapr-elastic-correlation-lab

Dapr logs reach Elastic through the platform team's log shipper. Traces and
metrics reach it through an OpenTelemetry collector. They land in different data
streams, and the ask is usually to click from a trace straight to that trace's
log lines, instead of switching panes and searching by hand.

**That click-through cannot work today, and moving the logs into the APM data
stream will not fix it.** Elastic correlates a trace to its logs on `trace.id`.
A Dapr log line does not carry one. Verified here: the span carries `trace_id`
and `span_id`, while the matching `HTTP API Called` log line carries 14 fields
and none of them is a trace or span id. So the data stream layout is not what is
blocking it. The missing field is, and that is
<https://github.com/dapr/dapr/issues/10979>.

What you can do without it is stop switching panes. A Kibana data view takes a
comma separated pattern, so one view covers all three signals.

![one data view](images/one-data-view.svg)

One query, three data streams, two different collectors, real Dapr 1.19 data:

![ES|QL across three streams](images/esql-three-streams.jpg)

That buys one place to query and dashboards spanning both signals. It does not
buy click-through.

## The closest you get today

Dapr sets `service.name` on the span to the app_id, so it already matches the
log side. The span also carries `attributes.dapr.api` and
`attributes.dapr.status_code`, which match the access log line's `method` and
`code` exactly. So a span and its access log lines join on service, API, status
and a time window.

Metrics join on `attributes.app_id`.

That is a manual join in one view rather than a click, but it is a good deal
tighter than matching on a timestamp.

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
