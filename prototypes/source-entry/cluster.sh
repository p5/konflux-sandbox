#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
results="$root/.prototype-results/source-entry"
: "${KUBECONFIG:?Set the dedicated prototype kubeconfig}"
: "${KUBE_CONTEXT:?Set the dedicated prototype context}"
[[ "$KUBE_CONTEXT" == kind-konflux-sandbox-prototype ]]
k=(kubectl --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT")
expected_server=$(kind get kubeconfig --name konflux-sandbox-prototype | kubectl --kubeconfig /dev/stdin config view --minify -o jsonpath='{.clusters[0].cluster.server}')
actual_server=$("${k[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
if [[ -z "$expected_server" || "$actual_server" != "$expected_server" ]]; then
  echo 'Refusing source-entry operations outside the dedicated Kind cluster' >&2
  exit 1
fi
"${k[@]}" get node konflux-sandbox-prototype-control-plane >/dev/null
"${k[@]}" create namespace source-entry-prototype --dry-run=client -o yaml | "${k[@]}" apply -f - > "$results/namespace.log"
cat <<'EOF' | "${k[@]}" apply -f - > "$results/serviceaccount.log"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: source-entry-prototype
  namespace: source-entry-prototype
automountServiceAccountToken: false
EOF
"${k[@]}" create --dry-run=client -f "$results/resolved.yaml" -o json | jq 'del(.metadata.name,.status) | .metadata.generateName="source-entry-" | .metadata.namespace="source-entry-prototype" | .metadata.labels["sandbox.konflux-ci.dev/prototype"]="source-entry" | .spec.taskRunTemplate={serviceAccountName:"source-entry-prototype",podTemplate:{automountServiceAccountToken:false}}' > "$results/resolved-execution.json"
name=$("${k[@]}" create -f "$results/resolved-execution.json" -o jsonpath='{.metadata.name}')
"${k[@]}" wait --for=condition=Succeeded=True "pipelinerun/$name" -n source-entry-prototype --timeout=90s > "$results/pipeline-wait.log"
"${k[@]}" get "pipelinerun/$name" -n source-entry-prototype -o json > "$results/pipeline.json"
"${k[@]}" logs -n source-entry-prototype -l "tekton.dev/pipelineRun=$name" --all-containers > "$results/pipeline.log"
rg -q 'local source-entry fixture' "$results/pipeline.log"
jq -e '.status.conditions | any(.[];.type=="Succeeded" and .status=="True")' "$results/pipeline.json" > /dev/null
"${k[@]}" get pods -n source-entry-prototype -l "tekton.dev/pipelineRun=$name" -o json > "$results/pods.json"
jq -e '.items|length==1 and all(.[];.spec.serviceAccountName=="source-entry-prototype" and .spec.automountServiceAccountToken==false and all(.spec.volumes[]?;.projected.sources[]?.serviceAccountToken==null))' "$results/pods.json" >/dev/null
jq -n --arg pipelineRun "$name" '{pipelineRun:$pipelineRun,namespace:"source-entry-prototype",actual_pac_resolution:true,actual_tekton_execution:true,service_account_token_automount:false,git_checkout_performed:false,provider_authorization_performed:false}' | tee "$results/cluster.json"
