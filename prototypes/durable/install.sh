#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
: "${KUBECONFIG:=/tmp/konflux-sandbox-runtime/vm-kubeconfig}"
: "${KUBE_CONTEXT:=kind-konflux-sandbox-vm-prototype}"
"$here/guard.sh"
: "${DURABLE_NAMESPACE:=foundation-durable-prototype}"
[[ "$DURABLE_NAMESPACE" == foundation-*-prototype ]]
k() { kubectl --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" --request-timeout=15s "$@"; }
if existing=$(k get namespace "$DURABLE_NAMESPACE" -o json 2>/dev/null); then
  jq -e '.metadata.labels["foundation.sandbox.p5.dev/owner"]=="durable"' <<< "$existing" >/dev/null
else
  k create namespace "$DURABLE_NAMESPACE"
  k label namespace "$DURABLE_NAMESPACE" foundation.sandbox.p5.dev/owner=durable
fi
jq -n --arg ns "$DURABLE_NAMESPACE" '{apiVersion:"v1",kind:"ServiceAccount",metadata:{name:"durable-guest",namespace:$ns},automountServiceAccountToken:false}' | k apply -f -
k apply -f "$here/crd.yaml"
k wait crd/executions.foundation.sandbox.p5.dev --for=condition=Established --timeout=30s
