# dapr-elastic-correlation-lab

## The situation

Dapr logs come in through a log shipper and land in `logs-*`. Traces and
metrics come in through an OpenTelemetry collector and land in the APM streams.
Two data views, so following anything across them means leaving one and
searching in the other.

## Combining them

A Kibana data view takes more than one index pattern. Stack Management, Data
Views, Create, and put all three in the index pattern field, comma separated:

    logs-*,traces-*,metrics-*

Use your real stream names. With the APM integration the traces one is
`traces-apm-*`.

![one data view](images/one-data-view.svg)

One view over all three, nothing changes in the pipeline. Queries work across
them too:

![ES|QL across three streams](images/esql-three-streams.jpg)

## Settings

On each pod template:

    dapr.io/enable-api-logging: "true"   # the HTTP API Called lines
    dapr.io/log-as-json: "true"          # sidecar JSON
    dapr.io/enable-metrics: "true"       # metrics are scraped off this

On the Dapr Helm release, for the control plane:

    global.logAsJson=true

That covers the control plane only, and the pod annotation covers the sidecar.
Neither implies the other.

In the log pipeline, parse the JSON conditionally. `dapr-system` is not one
format: the scheduler emits etcd zap JSON (`ts`, `caller`) and plaintext
alongside Dapr's own JSON. Group control plane views on the container name,
since `scope` is absent on most scheduler lines.

In the metrics pipeline, add `cumulativetodelta`, or the Elasticsearch exporter
drops every Dapr histogram including `dapr_http_server_latency`. Counters still
arrive, so it looks like it is working.

## Joining a span to its log lines

Dapr sets `service.name` on the span to the app_id. The span also carries
`attributes.dapr.api` and `attributes.dapr.status_code`, which match `method`
and `code` on the access log line. Metrics join on `app_id`.

Dapr log lines carry no `trace.id`, so Elastic's trace to logs click through in
the APM UI does not work, and moving the logs into the APM data stream would not
change that. Tracked in <https://github.com/dapr/dapr/issues/10979>.

## The lab

Elasticsearch and Kibana 9.1 in Docker, Dapr 1.19 on minikube, a test workload
and two collectors. `./scripts/setup.sh` starts it, `teardown.sh` removes it.

    k8s/        tracing config, collectors, workload
    elastic/    dashboard, data views, queries

![dashboard](images/dashboard.jpg)

The dashboard's index patterns are this lab's, so edit them before importing.
