#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${KUBECONFIG:?Set KUBECONFIG}"
source ./context.sh
require_runtime_context "$KUBECONFIG"
mkdir -p evidence
exec > >(tee evidence/claims.log) 2>&1
namespace=sandbox-runtime-prototype
k() { runtime_k "$@"; }
runtime_field=''
if [[ -n ${RUNTIME_CLASS:-} ]]; then runtime_field="      runtimeClassName: $RUNTIME_CLASS"; fi
cat <<EOF | k apply -f -
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxTemplate
metadata:
  name: pool-template
  namespace: $namespace
spec:
  podTemplate:
    spec:
$runtime_field
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 1
      containers:
      - name: runtime
        image: konflux-sandbox-runtime:prototype
        imagePullPolicy: Never
        command: [sleep, '3600']
        resources:
          requests: {cpu: 100m, memory: 128Mi}
          limits: {cpu: '1', memory: 512Mi}
---
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxWarmPool
metadata:
  name: pool
  namespace: $namespace
spec:
  replicas: 1
  sandboxTemplateRef: {name: pool-template}
EOF
k wait -n "$namespace" sandboxwarmpool/pool --for=jsonpath='{.status.readyReplicas}'=1 --timeout=120s
warm_name=$(k get sandbox -n "$namespace" -o json | jq -r '.items[] | select(.metadata.ownerReferences[]?.kind=="SandboxWarmPool") | .metadata.name')
warm_uid=$(k get pod "$warm_name" -n "$namespace" -o jsonpath='{.metadata.uid}')
cat <<EOF | k apply -f -
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata:
  name: claim
  namespace: $namespace
spec:
  warmPoolRef: {name: pool}
EOF
k wait -n "$namespace" sandboxclaim/claim --for=condition=Ready --timeout=120s
assigned=$(k get sandboxclaim claim -n "$namespace" -o jsonpath='{.status.sandbox.name}')
test "$assigned" = "$warm_name"
test "$(k get pod "$assigned" -n "$namespace" -o jsonpath='{.metadata.uid}')" = "$warm_uid"
test "$(k get sandbox "$assigned" -n "$namespace" -o json | jq -r '.metadata.ownerReferences[0].kind')" = SandboxClaim
echo 'PASS claim adopts prewarmed sandbox and preserves running Pod UID'
pool_uid=$(k get sandboxwarmpool pool -n "$namespace" -o jsonpath='{.metadata.uid}')
claim_uid=$(k get sandboxclaim claim -n "$namespace" -o jsonpath='{.metadata.uid}')
replenished=false
for _ in {1..60}; do
  k get sandbox -n "$namespace" -o json >evidence/replenishment.json
  if jq --arg pool "$pool_uid" --arg claim "$claim_uid" -e '
    (.items|length)==2 and
    ([.items[]|select(any(.metadata.ownerReferences[]?; .uid==$claim))]|length)==1 and
    ([.items[]|select(any(.metadata.ownerReferences[]?; .uid==$pool))|
      select(any(.status.conditions[]?; .type=="Ready" and .status=="True"))]|length)==1
  ' evidence/replenishment.json >/dev/null; then
    replenished=true
    break
  fi
  sleep 2
done
test "$replenished" = true
replacement=$(jq --arg pool "$pool_uid" -r '.items[]|select(any(.metadata.ownerReferences[]?; .uid==$pool))|.metadata.name' evidence/replenishment.json)
test "$(k get pod "$replacement" -n "$namespace" -o jsonpath='{.metadata.uid}')" != "$warm_uid"
echo 'PASS pool replenishes claimed capacity'
k get sandboxclaim claim -n "$namespace" -o json >evidence/claim.json
k delete sandboxclaim claim -n "$namespace" --wait=true
k wait -n "$namespace" "sandbox/$assigned" --for=delete --timeout=60s
k wait -n "$namespace" "pod/$assigned" --for=delete --timeout=60s
echo 'PASS claim deletion removes assigned sandbox and Pod'
k delete sandboxwarmpool pool -n "$namespace" --wait=true
k delete sandboxtemplate pool-template -n "$namespace"
k wait -n "$namespace" sandbox --all --for=delete --timeout=60s
echo 'PASS warm pool cleanup'
