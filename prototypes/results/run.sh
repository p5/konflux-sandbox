#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
state="$root/.prototype-state/results"
results="$root/.prototype-results/results"
: "${KUBECONFIG:?Set the dedicated prototype kubeconfig}"
: "${KUBE_CONTEXT:?Set the dedicated prototype context}"
[[ "$KUBE_CONTEXT" == kind-konflux-sandbox-prototype ]]
k=(kubectl --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" --request-timeout=20s)
expected_server=$(kind get kubeconfig --name konflux-sandbox-prototype | kubectl --kubeconfig /dev/stdin config view --minify -o jsonpath='{.clusters[0].cluster.server}')
actual_server=$("${k[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
if [[ -z "$expected_server" || "$actual_server" != "$expected_server" ]]; then
  echo 'Refusing Results API operations outside the dedicated Kind cluster' >&2
  exit 1
fi
"${k[@]}" get node konflux-sandbox-prototype-control-plane >/dev/null
mkdir -p "$state/bin" "$state/diagnostics" "$results"
cleanup() {
  if [[ -n ${forward_pid:-} ]]; then kill "$forward_pid" 2>/dev/null || true; fi
  rm -f "$state/authorization-header"
}
trap cleanup EXIT
"${k[@]}" create namespace results-prototype --dry-run=client -o yaml | "${k[@]}" apply -f - > "$results/namespace.log"
cat <<'EOF' | "${k[@]}" apply -f - > "$results/rbac.log"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: results-execution
  namespace: results-prototype
automountServiceAccountToken: false
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: results-reader
  namespace: results-prototype
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: results-reader
  namespace: results-prototype
rules:
- apiGroups: [results.tekton.dev]
  resources: [results, records, logs]
  verbs: [get, list]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: results-reader
  namespace: results-prototype
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: results-reader
subjects:
- kind: ServiceAccount
  name: results-reader
  namespace: results-prototype
EOF
name=$("${k[@]}" create -f "$here/fixture.yaml" -o jsonpath='{.metadata.name}')
"${k[@]}" wait "pipelinerun/$name" -n results-prototype --for=jsonpath='{.status.completionTime}' --timeout=120s > "$results/pipeline-wait.log"
deadline=$((SECONDS+120))
until "${k[@]}" get "pipelinerun/$name" -n results-prototype -o json > "$results/live-pipeline.json" && jq -e '.metadata.annotations["results.tekton.dev/stored"]=="true" and .status.completionTime!=null' "$results/live-pipeline.json" >/dev/null; do
  (( SECONDS<deadline )) || { echo 'PipelineRun archival annotation missing' >&2; exit 1; }; sleep 2
done
jq -e 'any(.status.conditions[];.type=="Succeeded" and .status=="False")' "$results/live-pipeline.json" >/dev/null
"${k[@]}" get taskruns -n results-prototype -l "tekton.dev/pipelineRun=$name" -o json > "$results/live-taskruns.json"
jq -e '.items|length==2' "$results/live-taskruns.json" >/dev/null
"${k[@]}" logs -n results-prototype -l "tekton.dev/pipelineRun=$name" --all-containers=true --prefix > "$results/live-kubernetes-logs.txt"
rg -q 'RESULTS_DIAGNOSTIC_MARKER' "$results/live-kubernetes-logs.txt"

"${k[@]}" get secret tekton-results-tls -n tekton-pipelines -o jsonpath='{.data.tls\.crt}' | base64 -d > "$state/results-public-certificate.pem"
"${k[@]}" port-forward -n tekton-pipelines service/tekton-results-api-service 0:8080 > "$results/port-forward.log" 2>&1 &
forward_pid=$!
port=''
for _ in {1..60}; do
  port=$(awk '/Forwarding from 127.0.0.1:/{split($3,a,":");print a[2];exit}' "$results/port-forward.log")
  [[ -z "$port" ]] || break
  sleep 0.1
done
[[ -n "$port" ]]
host=tekton-results-api-service.tekton-pipelines.svc.cluster.local
base="https://$host:$port/apis/results.tekton.dev/v1alpha2/parents"
curl_args=(--noproxy '*' --silent --show-error --max-time 15 --cacert "$state/results-public-certificate.pem" --resolve "$host:$port:127.0.0.1")
{
  printf 'Authorization: Bearer '
  "${k[@]}" create token results-reader -n results-prototype --duration=10m | tr -d '\n'
  printf '\n'
} > "$state/authorization-header"
query() { curl "${curl_args[@]}" --header "@$state/authorization-header" --output "$2" --write-out '%{http_code}' "$base/$1"; }
unauthenticated=$(curl "${curl_args[@]}" --output "$results/unauthenticated.json" --write-out '%{http_code}' "$base/results-prototype/results")
[[ "$unauthenticated" == 401 ]]
allowed=$(query results-prototype/results "$results/result-list.json")
[[ "$allowed" == 200 ]]
denied=$(query konflux-lifecycle-prototype/results "$results/namespace-denied.json")
[[ "$denied" == 401 ]]

record_name=$(jq -r '.metadata.annotations["results.tekton.dev/record"]' "$results/live-pipeline.json")
result_name=$(jq -r '.metadata.annotations["results.tekton.dev/result"]' "$results/live-pipeline.json")
[[ "$record_name" == results-prototype/results/*/records/* ]]
[[ $(query "$result_name" "$results/result.json") == 200 ]]
[[ $(query "$record_name" "$results/pipeline-record.json") == 200 ]]
jq -r '.data.value' "$results/pipeline-record.json" | base64 -d > "$results/archived-pipeline.json"
for task in $(jq -r '.items[].metadata.name' "$results/live-taskruns.json"); do
  deadline=$((SECONDS+120))
  until "${k[@]}" get taskrun "$task" -n results-prototype -o json > "$results/live-$task.json" && jq -e '.metadata.annotations["results.tekton.dev/stored"]=="true"' "$results/live-$task.json" >/dev/null; do
    (( SECONDS<deadline )) || { echo 'TaskRun archival annotation missing' >&2; exit 1; }; sleep 2
  done
  task_record=$(jq -r '.metadata.annotations["results.tekton.dev/record"]' "$results/live-$task.json")
  [[ $(query "$task_record" "$results/record-$task.json") == 200 ]]
  jq -r '.data.value' "$results/record-$task.json" | base64 -d > "$results/archived-$task.json"
done
node "$here/compare.mjs" "$results" "$name"
logs_list=$(query "$result_name/logs" "$results/log-list.json")
failed_record=$(jq -r '.items[]|select(.metadata.labels["tekton.dev/pipelineTask"]=="check")|.metadata.annotations["results.tekton.dev/record"]' "$results/live-taskruns.json")
[[ "$failed_record" == results-prototype/results/*/records/* ]]
log_name=${failed_record/\/records\//\/logs\/}
logs_get=$(query "$log_name" "$results/log-get.json")
"${k[@]}" get configmap tekton-results-api-config -n tekton-pipelines -o json | jq -r '.data.config|split("\n")|map(select(startswith("LOGS_API=") or startswith("LOGS_TYPE=") or startswith("AUTH_DISABLE=")))|.[]' > "$results/results-capabilities.txt"
rg -q '^LOGS_API=false$' "$results/results-capabilities.txt"
[[ "$logs_list" == 404 && "$logs_get" == 404 ]]

printf '#!/bin/sh\necho "Prototype denies uncached KubeArchive calls" >&2\nexit 99\n' > "$state/bin/oc"
chmod 700 "$state/bin/oc"
jq '{apiVersion:"v1",kind:"List",items:[.]}' "$results/archived-pipeline.json" > "$state/diagnostics/collected-pipelinerun-$name.yaml"
for task in $(jq -r '.items[].metadata.name' "$results/live-taskruns.json"); do
  jq '{apiVersion:"v1",kind:"List",items:[.]}' "$results/archived-$task.json" > "$state/diagnostics/collected-taskrun-$task.yaml"
done
PATH="$state/bin:$PATH" TERM=dumb PLR_CACHE_DIR="$state/diagnostics" bash "$root/../agent-plugins/skills/investigating-failed-plrs/check-plr-errors.sh" results-prototype "$name" > "$results/upstream-diagnostics.txt"
rg -q 'Step failed: check \(exit code: 23' "$results/upstream-diagnostics.txt"

"${k[@]}" delete "pipelinerun/$name" -n results-prototype --wait=true > "$results/live-delete.log"
if "${k[@]}" get "pipelinerun/$name" -n results-prototype >/dev/null 2>&1; then echo 'Live PipelineRun still exists' >&2; exit 1; fi
after_delete=$(query "$record_name" "$results/pipeline-record-after-delete.json")
[[ "$after_delete" == 200 ]]
jq -r '.data.value' "$results/pipeline-record-after-delete.json" | base64 -d > "$results/archived-pipeline-after-delete.json"
jq -e --arg uid "$(jq -r .metadata.uid "$results/live-pipeline.json")" '.metadata.uid==$uid' "$results/archived-pipeline-after-delete.json" >/dev/null
git -C "$root/../tekton-results" rev-parse v0.20.0 > "$results/results-release-commit.txt"
git -C "$root/../agent-plugins" rev-parse HEAD > "$results/diagnostics-commit.txt"
jq -n --arg name "$name" --arg record "$record_name" --argjson unauthenticated "$unauthenticated" --argjson allowed "$allowed" --argjson denied "$denied" --argjson logsList "$logs_list" --argjson logsGet "$logs_get" '{pipelineRun:$name,record:$record,unauthenticated_status:$unauthenticated,own_namespace_status:$allowed,other_namespace_status:$denied,archived_identity_and_results_match:true,archived_record_available_after_live_deletion:true,logs_list_status:$logsList,logs_get_status:$logsGet,logs_source:"live Kubernetes API only; Results logs availability recorded separately",upstream_diagnostics_source:"actual check-plr-errors.sh with Results-derived local cache; no KubeArchive calls",credentials:"short-lived TokenRequest; header file removed on exit"}' | tee "$results/summary.json"
