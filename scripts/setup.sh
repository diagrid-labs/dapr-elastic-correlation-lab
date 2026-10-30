#!/usr/bin/env bash
# Stand the whole lab up. Assumes a running minikube and Docker.
set -euo pipefail

CTX="${KUBE_CONTEXT:-minikube}"
ES="${ES_URL:-http://localhost:9200}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Elasticsearch and Kibana"
docker compose -f "$HERE/docker-compose.yml" up -d
until curl -sf "$ES/_cluster/health" >/dev/null; do sleep 3; done

# Without these, the elasticsearch exporter fails with
# index_not_found_exception ... requires a data stream, but no matching index
# template. Elastic Cloud ships equivalents via the APM integration; a bare
# cluster does not.
echo "==> index templates"
# NOTE: no lab-metrics here on purpose. A metrics-* template at a high priority
# shadows Elastic's own metrics-otel@template (metrics-*.otel-*, priority 120)
# and every metric document then fails with document_parsing_exception.
for t in lab-logs lab-traces; do
  curl -sf -X PUT "$ES/_index_template/$t" \
    -H 'Content-Type: application/json' \
    -d @"$HERE/elastic/index-templates/$t.json" >/dev/null
  echo "    $t"
done

echo "==> Dapr"
kubectl --context "$CTX" get ns dapr-system >/dev/null 2>&1 || \
  helm upgrade --install dapr dapr/dapr \
    --kube-context "$CTX" \
    --namespace dapr-system --create-namespace \
    --version 1.19.0 --wait

echo "==> workload"
kubectl --context "$CTX" apply -f "$HERE/k8s/"
kubectl --context "$CTX" -n default rollout status deploy/otelcol
kubectl --context "$CTX" -n default rollout status deploy/logtest

echo "==> waiting for traffic to accumulate"
sleep 60

echo "==> harvesting logs into Elasticsearch"
KUBE_CONTEXT="$CTX" ES_URL="$ES" python3 "$HERE/scripts/harvest.py"

cat <<EOF

Done.
  Kibana     http://localhost:5601
  Dashboard  import elastic/dapr-elastic-dashboard.ndjson
             Stack Management > Saved Objects > Import
EOF
