#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build evidence
cat <<'EOF' >.build/rejected-context.yaml
apiVersion: v1
kind: Config
current-context: remote
contexts:
- name: remote
  context:
    cluster: remote
clusters:
- name: remote
  cluster:
    server: https://127.0.0.1:9
EOF
if bash kctl.sh .build/rejected-context.yaml get namespace >evidence/rejected-context.log 2>&1; then
  echo 'FAIL remote context accepted'
  exit 1
fi
grep -q 'Refusing non-prototype context' evidence/rejected-context.log
cp .build/rejected-context.yaml .build/rejected-endpoint.yaml
prototype_context=''
for cluster in konflux-sandbox-prototype konflux-sandbox-vm-prototype; do
  if kind get clusters | grep -qx "$cluster"; then
    prototype_context=kind-$cluster
    break
  fi
done
test -n "$prototype_context"
kubectl --kubeconfig .build/rejected-endpoint.yaml config rename-context remote "$prototype_context" >/dev/null
if bash kctl.sh .build/rejected-endpoint.yaml get namespace >evidence/rejected-endpoint.log 2>&1; then
  echo 'FAIL unexpected API endpoint accepted'
  exit 1
fi
grep -q 'Refusing API endpoint outside dedicated Kind cluster' evidence/rejected-endpoint.log
echo 'PASS remote contexts and unexpected API endpoints rejected before cluster mutations'
