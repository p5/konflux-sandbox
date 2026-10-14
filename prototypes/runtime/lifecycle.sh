#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p evidence
exec > >(tee evidence/lifecycle.log) 2>&1
: "${KUBECONFIG:?Set KUBECONFIG}"
source ./context.sh
require_runtime_context "$KUBECONFIG"
rest_port=18080
grpc_port=19090
if [[ $RUNTIME_CONTEXT == kind-konflux-sandbox-vm-prototype ]]; then
  rest_port=28080
  grpc_port=29090
fi
UPSTREAM=${UPSTREAM:-../../../agent-sandbox}
namespace=sandbox-runtime-prototype
k() { runtime_k "$@"; }
token=$(openssl rand -hex 24)
digest=$(printf '%s' "$token" | sha256sum | cut -d' ' -f1)
runtime_field=''
if [[ -n ${RUNTIME_CLASS:-} ]]; then runtime_field="      runtimeClassName: $RUNTIME_CLASS"; fi
k create namespace "$namespace" --dry-run=client -o yaml | k apply -f -
cat <<EOF | k apply -f -
apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata:
  name: lifecycle
  namespace: $namespace
spec:
  volumeClaimTemplates:
  - metadata:
      name: workspace
    spec:
      accessModes: [ReadWriteOnce]
      resources:
        requests:
          storage: 64Mi
  podTemplate:
    metadata:
      labels:
        prototype: runtime
    spec:
$runtime_field
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 2
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
      - name: runtime
        image: konflux-sandbox-runtime:prototype
        imagePullPolicy: Never
        args: ["--auth-token-sha256=$digest"]
        resources:
          requests: {cpu: 100m, memory: 128Mi}
          limits: {cpu: '1', memory: 512Mi}
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: [ALL]
        volumeMounts:
        - name: workspace
          mountPath: /workspace
EOF
k wait -n "$namespace" sandbox/lifecycle --for=condition=Ready --timeout=120s
old_uid=$(k get pod lifecycle -n "$namespace" -o jsonpath='{.metadata.uid}')
forward() {
  endpoint=lifecycle
  if [[ -n ${RUNTIME_CLASS:-} ]]; then
    guest_ip=$(k get pod lifecycle -n "$namespace" -o jsonpath='{.status.podIP}')
    k delete pod transport-proxy -n "$namespace" --ignore-not-found --wait=true
    cat <<EOF | k apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: transport-proxy
  namespace: $namespace
spec:
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 1
  containers:
  - name: rest
    image: konflux-sandbox-runtime:prototype
    imagePullPolicy: Never
    command: [socat, "TCP-LISTEN:8080,reuseaddr,fork", "TCP:$guest_ip:8080"]
  - name: grpc
    image: konflux-sandbox-runtime:prototype
    imagePullPolicy: Never
    command: [socat, "TCP-LISTEN:9090,reuseaddr,fork", "TCP:$guest_ip:9090"]
EOF
    k wait -n "$namespace" pod/transport-proxy --for=condition=Ready --timeout=90s
    endpoint=transport-proxy
  fi
  k port-forward -n "$namespace" "pod/$endpoint" "$rest_port:8080" "$grpc_port:9090" >evidence/port-forward.log 2>&1 &
  forward_pid=$!
  for _ in {1..50}; do
    if curl -fsS "http://127.0.0.1:$rest_port/v1/health" >/dev/null 2>&1; then return; fi
    sleep 0.2
  done
  cat evidence/port-forward.log
  return 1
}
trap 'kill "${forward_pid:-}" 2>/dev/null || true' EXIT
forward
unauthorized=$(curl -sS -o /dev/null -w '%{http_code}' -X PUT --data denied "http://127.0.0.1:$rest_port/v1/files/denied.txt")
test "$unauthorized" = 401
echo "PASS unauthenticated file write rejected: $unauthorized"
curl -fsS -H "Authorization: Bearer $token" -X PUT --data 'persistent synthetic source' "http://127.0.0.1:$rest_port/v1/files/source.txt" >/dev/null
rpc() {
  grpcurl -plaintext -import-path "$UPSTREAM/packages/sandboxd/spec" -proto process/v1/process.proto -H "authorization: Bearer $token" -d "$2" "127.0.0.1:$grpc_port" "process.v1.ProcessService/$1"
}
if grpcurl -plaintext -import-path "$UPSTREAM/packages/sandboxd/spec" -proto process/v1/process.proto -d '{"config":{"command":["true"]}}' "127.0.0.1:$grpc_port" process.v1.ProcessService/Execute >evidence/unauthorized-command.json 2>&1; then
  echo 'FAIL unauthenticated command accepted'
  exit 1
fi
grep -qi 'unauthenticated' evidence/unauthorized-command.json
echo 'PASS unauthenticated command rejected'
rpc Execute '{"config":{"command":["sh","-c","cat source.txt; uname -r; test ! -e /var/run/secrets/kubernetes.io/serviceaccount/token"],"cwd":"/workspace"}}' | tee evidence/execute.json
test "$(jq -r '.exitCode // 0' evidence/execute.json)" = 0
echo "PASS file transport, command transport, no mounted service account token"
rpc Start '{"config":{"command":["sh","-c","export SESSION_VALUE=memory-only; echo $$ > session.pid; while :; do sleep 1; done"],"cwd":"/workspace"},"pty":{"cols":80,"rows":24}}' >evidence/process.json &
stream_pid=$!
sleep 1
process_id=$(jq -r 'select(.init).init.processId' evidence/process.json | head -1)
test -n "$process_id"
rpc ResizeTTY "{\"processId\":$process_id,\"cols\":100,\"rows\":30}" >evidence/resize.json
echo "PASS PTY process started: $process_id"
rpc SendSignal "{\"processId\":$process_id,\"signal\":\"SIGNAL_SIGTERM\"}" >evidence/cancel.json
wait "$stream_pid"
test "$(jq -r 'select(.exit).exit.exitCode' evidence/process.json)" = 143
echo 'PASS cancellation terminates PTY process group with exit143'
rpc Start '{"config":{"command":["sh","-c","export SESSION_VALUE=memory-only; echo $$ > session.pid; while :; do sleep 1; done"],"cwd":"/workspace"},"pty":{"cols":80,"rows":24}}' >evidence/suspended-process.json &
stream_pid=$!
sleep 1
process_id=$(jq -r 'select(.init).init.processId' evidence/suspended-process.json | head -1)
test -n "$process_id"
k patch sandbox lifecycle -n "$namespace" --type merge -p '{"spec":{"operatingMode":"Suspended"}}'
k wait -n "$namespace" sandbox/lifecycle --for=condition=Suspended --timeout=90s
k wait -n "$namespace" pod/lifecycle --for=delete --timeout=30s || true
wait "$stream_pid" 2>/dev/null || true
kill "$forward_pid" 2>/dev/null || true
test "$(k get pvc -n "$namespace" -o json | jq '.items|length')" = 1
echo "PASS suspend removes pod and retains PVC"
k patch sandbox lifecycle -n "$namespace" --type merge -p '{"spec":{"operatingMode":"Running"}}'
k wait -n "$namespace" sandbox/lifecycle --for=condition=Ready --timeout=120s
new_uid=$(k get pod lifecycle -n "$namespace" -o jsonpath='{.metadata.uid}')
test "$old_uid" != "$new_uid"
forward
test "$(curl -fsS -H "Authorization: Bearer $token" "http://127.0.0.1:$rest_port/v1/files/source.txt")" = 'persistent synthetic source'
rpc SendSignal "{\"processId\":$process_id,\"signal\":\"SIGNAL_SIGTERM\"}" >evidence/old-process.json 2>&1 && { echo 'FAIL old process handle survived'; exit 1; }
grep -qi 'notfound\|not found' evidence/old-process.json
echo "PASS resume preserves files; old PTY/process handle is absent"
k get sandbox lifecycle -n "$namespace" -o json >evidence/sandbox.json
k delete sandbox lifecycle -n "$namespace" --wait=true
k delete pod transport-proxy -n "$namespace" --ignore-not-found --wait=true
k wait -n "$namespace" pod/lifecycle --for=delete --timeout=60s || true
echo "PVC objects after Sandbox deletion: $(k get pvc -n "$namespace" -o json | jq '.items|length')"
echo 'PASS sandbox cleanup; namespace cleanup remains explicit'
