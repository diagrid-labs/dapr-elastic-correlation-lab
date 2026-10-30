#!/usr/bin/env bash
# Stand the lab up. Needs a running minikube and Docker.
set -euo pipefail

CTX="${KUBE_CONTEXT:-minikube}"
ES="${ES_URL:-http://localhost:9200}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Elasticsearch and Kibana"
docker compose -f "$HERE/docker-compose.yml" up -d
until curl -sf "$ES/_cluster/health" >/dev/null; do sleep 3; done

echo "==> index template for logs"
curl -sf -X PUT "$ES/_index_template/lab-traces" \
  -H 'Content-Type: application/json' \
  -d @"$HERE/elastic/index-templates/lab-traces.json" >/dev/null

echo "==> Dapr"
kubectl --context "$CTX" get ns dapr-system >/dev/null 2>&1 || \
  helm upgrade --install dapr dapr/dapr \
    --kube-context "$CTX" \
    --namespace dapr-system --create-namespace \
    --version 1.19.0 --wait

echo "==> collectors and workload"
kubectl --context "$CTX" apply -f "$HERE/k8s/"
kubectl --context "$CTX" -n default rollout status deploy/otelcol
kubectl --context "$CTX" -n default rollout status deploy/logtest
kubectl --context "$CTX" -n default rollout status ds/logcol

cat <<EOF

Done. Data flows continuously from here.
  Kibana     http://localhost:5601
  Dashboard  import elastic/dapr-elastic-dashboard.ndjson
             Stack Management > Saved Objects > Import
EOF
