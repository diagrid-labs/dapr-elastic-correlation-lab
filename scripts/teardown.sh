#!/usr/bin/env bash
set -euo pipefail
CTX="${KUBE_CONTEXT:-minikube}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubectl --context "$CTX" delete -f "$HERE/k8s/" --ignore-not-found
docker compose -f "$HERE/docker-compose.yml" down -v
