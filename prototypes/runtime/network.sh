#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${KUBECONFIG:?Set KUBECONFIG}"
source ./context.sh
require_runtime_context "$KUBECONFIG"
mkdir -p evidence
exec > >(tee evidence/network.log) 2>&1
namespace=sandbox-runtime-prototype
k() { runtime_k "$@"; }
runtime_field=''
if [[ -n ${RUNTIME_CLASS:-} ]]; then runtime_field="  runtimeClassName: $RUNTIME_CLASS"; fi
k create namespace "$namespace" --dry-run=client -o yaml | k apply -f -
k delete networkpolicy deny-network-client-egress -n "$namespace" --ignore-not-found
cat <<EOF | k apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: network-client
  namespace: $namespace
  labels: {prototype: network-client}
spec:
$runtime_field
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 2
  containers:
  - name: client
    image: konflux-sandbox-runtime:prototype
    imagePullPolicy: Never
    command: [sleep, '3600']
---
apiVersion: v1
kind: Pod
metadata:
  name: network-target
  namespace: $namespace
spec:
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 2
  containers:
  - name: server
    image: konflux-sandbox-runtime:prototype
    imagePullPolicy: Never
EOF
k wait -n "$namespace" pod/network-client pod/network-target --for=condition=Ready --timeout=90s
target=$(k get pod network-target -n "$namespace" -o jsonpath='{.status.podIP}')
probe() {
  k exec -n "$namespace" network-client -- timeout 3 bash -c 'exec 3<>/dev/tcp/$1/8080; printf "GET /v1/health HTTP/1.0\r\n\r\n" >&3; head -1 <&3' bash "$target"
}
probe
cat <<EOF | k apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-network-client-egress
  namespace: $namespace
spec:
  podSelector:
    matchLabels: {prototype: network-client}
  policyTypes: [Egress]
  egress: []
EOF
sleep 3
if probe; then
  echo 'OBSERVED: deny-all egress NetworkPolicy exists, but direct Pod traffic remains allowed'
  echo 'REQUIRED: execution admission must reject profiles until network enforcement passes conformance'
else
  echo 'OBSERVED: deny-all egress NetworkPolicy blocks tested direct Pod connection'
fi
k delete networkpolicy deny-network-client-egress -n "$namespace"
sleep 2
probe
echo 'PASS removing policy restores baseline connectivity'
k delete pod network-client network-target -n "$namespace" --wait=true
