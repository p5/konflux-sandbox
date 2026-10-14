#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${KUBECONFIG:?Set KUBECONFIG}"
source ./context.sh
require_runtime_context "$KUBECONFIG" kind-konflux-sandbox-vm-prototype
mkdir -p evidence
exec > >(tee evidence/tekton-vm.log) 2>&1
k() { runtime_k "$@"; }
namespace=sandbox-runtime-prototype
k delete taskrun vm-check -n "$namespace" --ignore-not-found --wait=true
cat <<'EOF' | k apply -f -
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: vm-check
  namespace: sandbox-runtime-prototype
spec:
  podTemplate:
    runtimeClassName: kata-prototype
    automountServiceAccountToken: false
  taskSpec:
    results:
    - name: kernel
    - name: boot-id
    steps:
    - name: record-guest
      image: konflux-sandbox-runtime:prototype
      imagePullPolicy: Never
      script: |
        #!/bin/sh
        set -eu
        uname -r > $(results.kernel.path)
        cat /proc/sys/kernel/random/boot_id > $(results.boot-id.path)
        test ! -e /var/run/secrets/kubernetes.io/serviceaccount/token
    - name: verify-shared-guest
      image: konflux-sandbox-runtime:prototype
      imagePullPolicy: Never
      script: |
        #!/bin/sh
        set -eu
        test "$(cat /proc/sys/kernel/random/boot_id)" = "$(cat /tekton/results/boot-id)"
        echo 'PASS both Tekton steps use the same guest kernel boot'
EOF
k wait taskrun vm-check -n "$namespace" --for=condition=Succeeded --timeout=180s
k get taskrun vm-check -n "$namespace" -o json >evidence/tekton-vm.json
kernel=$(jq -r '.status.results[] | select(.name=="kernel") | .value' evidence/tekton-vm.json)
host_kernel=$(docker exec konflux-sandbox-vm-prototype-control-plane uname -r)
test "$kernel" != "$host_kernel"
echo "PASS Tekton guest kernel $kernel differs from node kernel $host_kernel"
pod=$(jq -r '.status.podName' evidence/tekton-vm.json)
k get pod "$pod" -n "$namespace" -o json >evidence/tekton-vm-pod.json
test "$(jq -r '.spec.runtimeClassName' evidence/tekton-vm-pod.json)" = kata-prototype
k logs "$pod" -n "$namespace" -c step-verify-shared-guest
k delete taskrun vm-check -n "$namespace" --wait=true
echo 'PASS direct Tekton VM execution and cleanup'
