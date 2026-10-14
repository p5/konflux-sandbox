#!/usr/bin/env bash
set -euo pipefail

task_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$task_dir/../.." && pwd)"
state_dir="$repo_dir/.prototype-state/dispatch"
result_dir="$repo_dir/.prototype-results/dispatch"
mkdir -p "$state_dir" "$result_dir"
: "${KUBECONFIG:?Set the dedicated prototype kubeconfig}"
: "${KUBE_CONTEXT:?Set the dedicated prototype context}"
if [[ "$KUBE_CONTEXT" != kind-konflux-sandbox-prototype ]]; then
  printf '%s\n' 'This prototype only accepts kind-konflux-sandbox-prototype.' >&2
  exit 1
fi
kubectl_cmd=(kubectl --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT")
expected_server=$(kind get kubeconfig --name konflux-sandbox-prototype | kubectl --kubeconfig /dev/stdin config view --minify -o jsonpath='{.clusters[0].cluster.server}')
actual_server=$("${kubectl_cmd[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
if [[ -z "$expected_server" || "$actual_server" != "$expected_server" ]]; then
  printf 'Refusing API endpoint outside dedicated Kind cluster: %s\n' "$actual_server" >&2
  exit 1
fi
"${kubectl_cmd[@]}" get node konflux-sandbox-prototype-control-plane > "$result_dir/node.txt"

CGO_ENABLED=0 go -C "$repo_dir/prototypes" build -o "$state_dir/executor" ./dispatch
docker build -t konflux-sandbox-dispatch-prototype:local -f "$task_dir/Dockerfile" "$state_dir" > "$result_dir/image-build.log" 2>&1
kind load docker-image konflux-sandbox-dispatch-prototype:local --name konflux-sandbox-prototype > "$result_dir/image-load.log" 2>&1

cat > "$state_dir/resources.yaml" <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: dispatch-prototype
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dispatch-prototype
  namespace: dispatch-prototype
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: executor
  namespace: dispatch-prototype
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dispatch-prototype-executor
  template:
    metadata:
      labels:
        app: dispatch-prototype-executor
    spec:
      serviceAccountName: dispatch-prototype
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: executor
        image: konflux-sandbox-dispatch-prototype:local
        imagePullPolicy: Never
        ports:
        - containerPort: 8080
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: [ALL]
        resources:
          requests:
            cpu: 50m
            memory: 32Mi
          limits:
            cpu: 500m
            memory: 128Mi
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: executor
  namespace: dispatch-prototype
spec:
  selector:
    app: dispatch-prototype-executor
  ports:
  - port: 8080
    targetPort: 8080
EOF
"${kubectl_cmd[@]}" apply -f "$state_dir/resources.yaml" > "$result_dir/install.log"
"${kubectl_cmd[@]}" rollout restart deployment/executor -n dispatch-prototype >> "$result_dir/install.log"
"${kubectl_cmd[@]}" rollout status deployment/executor -n dispatch-prototype --timeout=90s >> "$result_dir/install.log"

"${kubectl_cmd[@]}" port-forward -n dispatch-prototype service/executor 0:8080 > "$result_dir/port-forward.log" 2>&1 &
forward_pid=$!
trap 'kill "$forward_pid" 2>/dev/null || true' EXIT
forward_port=''
for _ in {1..80}; do
  forward_port="$(awk '/Forwarding from 127.0.0.1:/{split($3,a,":"); print a[2]; exit}' "$result_dir/port-forward.log")"
  if [[ -n "$forward_port" ]]; then break; fi
  sleep 0.1
done
if [[ -z "$forward_port" ]]; then
  printf '%s\n' 'Port-forward did not become ready.' >&2
  exit 1
fi
go -C "$repo_dir/prototypes" run ./dispatch -url "http://127.0.0.1:$forward_port" > "$result_dir/client.jsonl"

cat > "$state_dir/pipeline.yaml" <<'EOF'
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: remote-dispatch-
  namespace: dispatch-prototype
  labels:
    sandbox.konflux-ci.dev/prototype: remote-dispatch
spec:
  params:
  - name: mode
    value: pass
  timeouts:
    pipeline: 2m
  taskRunTemplate:
    serviceAccountName: dispatch-prototype
    podTemplate:
      automountServiceAccountToken: false
  pipelineSpec:
    params:
    - name: mode
      default: pass
    results:
    - name: execution-result
      value: $(tasks.dispatch.results.execution-result)
    tasks:
    - name: dispatch
      params:
      - name: mode
        value: $(params.mode)
      taskSpec:
        params:
        - name: mode
        results:
        - name: execution-result
        steps:
        - name: dispatch-and-wait
          image: konflux-sandbox-dispatch-prototype:local
          imagePullPolicy: Never
          env:
          - name: PROTOTYPE_MODE
            value: $(params.mode)
          script: |
            #!/bin/sh
            set -eu
            endpoint=http://executor.dispatch-prototype.svc.cluster.local:8080
            identity='Authorization: Bearer PROTOTYPE-DISPATCH-IDENTITY'
            id="tekton-$(context.taskRun.name)"
            script='printf remote-command-output'
            deadline=5
            if [ "$PROTOTYPE_MODE" = cancel ]; then
              script='sleep 30'
              deadline=10
            fi
            digest="sha256:$(printf '%s' "$script" | sha256sum | cut -d' ' -f1)"
            printf '{"script":"%s","digest":"%s","deadlineSeconds":%s}' "$script" "$digest" "$deadline" > /tmp/request.json
            wget -qO /tmp/submission.json --header "$identity" --post-file=/tmp/request.json "$endpoint/executions/$id"
            trap '/usr/local/bin/executor -url "$endpoint" -cancel "$id" || true' EXIT
            trap 'exit 143' INT TERM
            printf 'Remote execution submitted: %s\n' "$id"
            for attempt in $(seq 1 200); do
              wget -qO /tmp/result.json --header "$identity" "$endpoint/executions/$id"
              if grep -q '"cleanupComplete":true' /tmp/result.json; then
                cat /tmp/result.json > "$(results.execution-result.path)"
                cat /tmp/result.json
                grep -q '"outcome":"Passed"' /tmp/result.json
                exit
              fi
              sleep 0.1
            done
            exit 1
EOF
pipeline_name="$("${kubectl_cmd[@]}" create -f "$state_dir/pipeline.yaml" -o jsonpath='{.metadata.name}')"
"${kubectl_cmd[@]}" wait --for=condition=Succeeded=True "pipelinerun/$pipeline_name" -n dispatch-prototype --timeout=120s > "$result_dir/pipeline-wait.log"
"${kubectl_cmd[@]}" get "pipelinerun/$pipeline_name" -n dispatch-prototype -o json > "$result_dir/pipeline-result.json"

sed 's/value: pass/value: cancel/' "$state_dir/pipeline.yaml" > "$state_dir/cancel-pipeline.yaml"
cancel_pipeline="$("${kubectl_cmd[@]}" create -f "$state_dir/cancel-pipeline.yaml" -o jsonpath='{.metadata.name}')"
cancel_id=''
for _ in {1..300}; do
  child="$("${kubectl_cmd[@]}" get "pipelinerun/$cancel_pipeline" -n dispatch-prototype -o jsonpath='{.status.childReferences[0].name}')"
  if [[ -n "$child" ]]; then
    cancel_id="tekton-$child"
    if curl -fsS --header 'Authorization: Bearer PROTOTYPE-DISPATCH-IDENTITY' "http://127.0.0.1:$forward_port/executions/$cancel_id" > "$result_dir/cancel-execution-before.json" 2>/dev/null; then break; fi
  fi
  sleep 0.1
done
if [[ -z "$cancel_id" ]] || ! grep -q '"outcome":"Running"' "$result_dir/cancel-execution-before.json"; then
  printf '%s\n' 'Remote cancellation fixture did not start.' >&2
  exit 1
fi
"${kubectl_cmd[@]}" patch "pipelinerun/$cancel_pipeline" -n dispatch-prototype --type=merge -p '{"spec":{"status":"Cancelled"}}' > "$result_dir/cancel-request.log"
cancel_observed=0
for _ in {1..100}; do
  curl -fsS --header 'Authorization: Bearer PROTOTYPE-DISPATCH-IDENTITY' "http://127.0.0.1:$forward_port/executions/$cancel_id" > "$result_dir/cancel-execution-after.json"
  if grep -q '"outcome":"Cancelled"' "$result_dir/cancel-execution-after.json" && grep -q '"cleanupComplete":true' "$result_dir/cancel-execution-after.json"; then
    cancel_observed=1
    break
  fi
  sleep 0.1
done
"${kubectl_cmd[@]}" get "pipelinerun/$cancel_pipeline" -n dispatch-prototype -o json > "$result_dir/cancel-pipeline-result.json"
if [[ "$cancel_observed" != 1 ]]; then
  printf '%s\n' 'PipelineRun cancellation did not propagate before the remote deadline.' >&2
  exit 1
fi
"${kubectl_cmd[@]}" logs -n dispatch-prototype deployment/executor > "$result_dir/executor.log"
printf 'PASS remote dispatch: %s; cancellation: %s\nEvidence: %s\n' "$pipeline_name" "$cancel_pipeline" "$result_dir"
